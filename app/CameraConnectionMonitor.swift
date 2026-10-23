import AppKit
import Combine
import Foundation
import IOKit
import Darwin

/// Correct USB property matching plus a cheap registry watchdog trigger bounded SDK discovery.
/// The monitor never opens a camera session or writes a camera property.
enum CameraConnectionState: String {
    case disconnected, detecting, discovered, otherModel, multipleCameras
    case usbOnly, sdkMissing, utilityRunning, paused, failed
}

final class CameraConnectionMonitor: ObservableObject {
    @Published private(set) var state: CameraConnectionState = .disconnected
    @Published private(set) var title = "未连接佳能相机"
    @Published private(set) var detail = "USB 连接并打开相机后，这里会自动识别。"
    @Published private(set) var modelName: String?
    @Published private(set) var isProbing = false
    @Published private(set) var usbDeviceCount = 0
    @Published private(set) var lastChecked: Date?

    /// Discovery does not prove that a session can be opened; the existing
    /// backup and installer perform that check when the user starts a write.
    var canAttemptWrite: Bool { state == .discovered }

    private let helper: URL
    private let sdkCandidates: [String]
    private let usbProvider: () -> [(id: UInt64, name: String)]
    private let utilityRunning: () -> Bool
    private let watchdogInterval: TimeInterval
    private let retryDelays: [TimeInterval]
    let diagnosticsURL: URL
    private var retryWork: DispatchWorkItem?
    private var retriesScheduled = 0
    private var notificationPort: IONotificationPortRef?
    private var arrivalIterator: io_iterator_t = 0
    private var removalIterator: io_iterator_t = 0
    private var observers: [NSObjectProtocol] = []
    private var fallbackTimer: Timer?
    private var process: Process?
    private var retiringProcesses: [Process] = []
    private var debounce: DispatchWorkItem?
    private var started = false
    private var operationBusy = false
    private var generation = 0
    private var deviceSignature = ""

    init(helper: URL, sdkCandidates: [String],
         usbProvider: (() -> [(id: UInt64, name: String)])? = nil,
         utilityRunning: (() -> Bool)? = nil,
         watchdogInterval: TimeInterval = 2,
         retryDelays: [TimeInterval] = [2, 4, 8],
         diagnosticsDirectory: URL? = nil) {
        self.helper = helper
        self.sdkCandidates = sdkCandidates
        self.usbProvider = usbProvider ?? Self.canonUSBDevices
        self.utilityRunning = utilityRunning ?? { Self.eosUtilityIsRunning }
        self.watchdogInterval = watchdogInterval
        self.retryDelays = retryDelays
        let directory = diagnosticsDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Canon LUT 工具/连接诊断", isDirectory: true)
        self.diagnosticsURL = directory.appendingPathComponent("camera-detection.jsonl")
    }

    deinit { stop() }

    func start() {
        guard !started else { return }
        started = true
        if let port = IONotificationPortCreate(kIOMainPortDefault) {
            notificationPort = port
            IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
            let context = Unmanaged.passUnretained(self).toOpaque()
            let callback: IOServiceMatchingCallback = { context, iterator in
                while case let item = IOIteratorNext(iterator), item != 0 { IOObjectRelease(item) }
                guard let context = context else { return }
                let monitor = Unmanaged<CameraConnectionMonitor>.fromOpaque(context).takeUnretainedValue()
                monitor.scheduleRefresh(reason: "usb-notification")
            }
            let first = IOServiceAddMatchingNotification(port, kIOFirstMatchNotification,
                Self.usbMatching(), callback, context, &arrivalIterator)
            let second = IOServiceAddMatchingNotification(port, kIOTerminatedNotification,
                Self.usbMatching(), callback, context, &removalIterator)
            if first == KERN_SUCCESS { while case let item = IOIteratorNext(arrivalIterator), item != 0 { IOObjectRelease(item) } }
            if second == KERN_SUCCESS { while case let item = IOIteratorNext(removalIterator), item != 0 { IOObjectRelease(item) } }
            record("notification_registration", ["arrivalRc": first, "removalRc": second])
        } else { record("notification_port_unavailable") }
        // Registration success is not proof every device event is delivered.
        // The registry-only watchdog always runs and never periodically opens SDKs.
        startUSBFallback()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                // No SDK timer: app termination can release an occupied device.
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      Self.isEOSUtility(app) else { return }
                self?.scheduleRefresh(force: true, reason: "utility-change")
            })
        }
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleRefresh(force: true, reason: "system-wake")
        })
        record("monitor_started")
        refresh(reason: "startup", allowSDKWithoutUSB: true, resetRetries: true)
    }

    func stop() {
        started = false
        retryWork?.cancel(); retryWork = nil
        debounce?.cancel(); debounce = nil
        fallbackTimer?.invalidate(); fallbackTimer = nil
        cancelProbe()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        if arrivalIterator != 0 { IOObjectRelease(arrivalIterator); arrivalIterator = 0 }
        if removalIterator != 0 { IOObjectRelease(removalIterator); removalIterator = 0 }
        if let port = notificationPort {
            IONotificationPortSetDispatchQueue(port, nil)
            IONotificationPortDestroy(port); notificationPort = nil
        }
        record("monitor_stopped")
    }

    func setOperationBusy(_ busy: Bool) {
        guard operationBusy != busy else { return }
        operationBusy = busy
        if busy {
            debounce?.cancel(); debounce = nil
            retryWork?.cancel(); retryWork = nil
            cancelProbe()
            set(.paused, "相机检测已暂停", "正在处理任务，完成后自动恢复检测。")
        } else if started { refresh(reason: "task-finished", allowSDKWithoutUSB: false, resetRetries: true) }
    }

    /// Call this before launching snapshot/install. It waits off the UI thread
    /// until the enumeration process has actually exited, avoiding SDK overlap.
    func prepareForExclusiveCameraAccess(completion: @escaping () -> Void) {
        setOperationBusy(true)
        cancelProbe()
        let pending = retiringProcesses
        retiringProcesses.removeAll()
        DispatchQueue.global(qos: .userInitiated).async {
            for process in pending {
                if process.isRunning {
                    // SIGTERM is sent by cancelProbe. A bounded fallback also
                    // covers an unresponsive SDK without hanging the app.
                    for _ in 0..<20 {
                        if !process.isRunning { break }
                        usleep(25000)
                    }
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
                process.waitUntilExit()
            }
            DispatchQueue.main.async {
                self.record("exclusive_access_ready")
                completion()
            }
        }
    }

    func refresh() {
        refresh(reason: "manual", allowSDKWithoutUSB: true, resetRetries: true)
    }

    private func refresh(reason: String, allowSDKWithoutUSB: Bool, resetRetries: Bool) {
        guard started, !operationBusy else { return }
        debounce?.cancel(); debounce = nil
        retryWork?.cancel(); retryWork = nil
        if resetRetries { retriesScheduled = 0 }
        cancelProbe()
        if !retiringProcesses.isEmpty {
            // A manual refresh or a second USB event may arrive while the
            // previous bounded enumeration is exiting. Never overlap SDKs.
            let pending = retiringProcesses
            let token = generation
            DispatchQueue.global(qos: .utility).async { [weak self] in
                for task in pending { task.waitUntilExit() }
                DispatchQueue.main.async {
                    guard let self = self, self.started, !self.operationBusy, self.generation == token else { return }
                    self.retiringProcesses.removeAll(where: { !$0.isRunning })
                    self.refresh(reason: reason, allowSDKWithoutUSB: allowSDKWithoutUSB, resetRetries: false)
                }
            }
            return
        }
        let devices = usbProvider()
        usbDeviceCount = devices.count
        deviceSignature = devices.map { "\($0.id):\($0.name)" }.sorted().joined(separator: "|")
        lastChecked = Date()
        record("usb_scan", ["reason": reason, "canonUSBCount": devices.count,
                            "signature": deviceSignature, "sdkCrossCheckWithoutUSB": allowSDKWithoutUSB])
        guard !devices.isEmpty || allowSDKWithoutUSB else {
            modelName = nil
            set(.disconnected, "Mac USB 尚未发现佳能相机", "请检查数据线并唤醒相机；接入后会自动识别，也可点“重新检测”交叉检查 SDK。")
            return
        }
        modelName = devices.first?.name
        guard let sdk = sdkCandidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            set(.sdkMissing, devices.isEmpty ? "缺少 Canon 相机 SDK" : "已发现 Canon USB 设备 · 缺少 SDK", "请安装官方 EOS Utility 3，再点击“重新检测”。")
            return
        }
        guard !utilityRunning() else {
            set(.utilityRunning, "EOS Utility 正在运行", "请退出 EOS Utility 释放相机，退出后会自动重新识别。")
            return
        }
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            set(.failed, "相机检测组件缺失", "应用中的 eds_r6_tool 不完整，请重新构建应用。")
            return
        }
        set(.detecting, devices.isEmpty ? "正在交叉检查佳能 SDK…" : "USB 已连接 · 正在识别 Canon 相机…",
            devices.isEmpty ? "USB 暂未发现 Canon；正在独立检查 SDK，不打开相机会话。" : "Mac 已发现 Canon USB，正在等待佳能 SDK 就绪，不打开相机会话。")
        isProbing = true
        let task = Process(), pipe = Pipe()
        task.executableURL = helper
        task.arguments = ["probe", sdk]
        task.standardOutput = pipe; task.standardError = pipe
        generation += 1; let token = generation
        process = task
        record("probe_started", ["reason": reason, "canonUSBCount": usbDeviceCount, "retry": retriesScheduled])
        do { try task.run() }
        catch {
            process = nil; isProbing = false
            set(.failed, "相机检测未完成", error.localizedDescription)
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            DispatchQueue.main.async {
                guard let self = self, self.generation == token, self.started, !self.operationBusy else { return }
                self.process = nil; self.isProbing = false
                self.acceptProbe(String(decoding: data, as: UTF8.self), exitCode: task.terminationStatus)
            }
        }
        // Independent deadline: a broken SDK must not leave detection spinning.
        DispatchQueue.main.asyncAfter(deadline: .now() + 18) { [weak self, weak task] in
            guard let self = self, self.generation == token, task?.isRunning == true else { return }
            self.cancelProbe()
            self.unresolved("佳能 SDK 检测超时")
        }
    }

    private func acceptProbe(_ text: String, exitCode: Int32) {
        lastChecked = Date()
        if text.contains("Pinned SDK hash differs") {
            set(.failed, "SDK 版本与已验证版本不同", "USB 设备已接入。请查看应用说明中的 SDK 兼容性要求。")
            return
        }
        let events = text.split(separator: "\n").compactMap { line -> [String: Any]? in
            guard let bytes = String(line).data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
        }
        guard exitCode == 0, let result = events.last(where: { $0["event"] as? String == "probe_complete" }) else {
            record("probe_failed", ["exitCode": exitCode])
            unresolved("佳能 SDK 检测未完成")
            return
        }
        let cameras = result["cameras"] as? [[String: Any]] ?? []
        let count = result["cameraCount"] as? Int ?? 0
        record("probe_result", ["cameraCount": count, "canonUSBCount": usbDeviceCount,
                                 "modelNames": cameras.compactMap { $0["name"] as? String }])
        guard count > 0 else {
            unresolved("佳能 SDK 暂未识别相机")
            return
        }
        guard count == 1, let camera = cameras.first else {
            modelName = cameras.compactMap { $0["name"] as? String }.joined(separator: "、")
            set(.multipleCameras, "检测到多台佳能相机", "写入时请只连接一台 EOS R6 Mark III。")
            return
        }
        guard camera["deviceInfoRc"] as? Int == 0, let name = camera["name"] as? String else {
            set(.usbOnly, "USB 已连接 · 无法读取型号", "请唤醒相机，再点击“重新检测”。")
            return
        }
        modelName = name
        let normalized = name.uppercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
        if normalized.contains("R6MARKIII") || normalized.contains("R6MARK3") {
            set(.discovered, "已发现 \(name)", usbDeviceCount > 0
                ? "USB 与佳能 SDK 均已识别。写入时将验证连接并备份；检测不会改动相机。"
                : "佳能 SDK 已识别，USB 侦测结果待核对。写入时将验证连接并备份。")
        } else {
            set(.otherModel, "已发现 \(name)", "当前写入功能仅验证过 EOS R6 Mark III，其他型号不能写入。")
        }
    }

    private func unresolved(_ message: String) {
        guard usbDeviceCount > 0 else {
            modelName = nil
            set(.disconnected, "Mac USB 与佳能 SDK 均未发现相机", "请检查数据线、开机并唤醒相机；当前没有可写入的连接。")
            return
        }
        if retriesScheduled < retryDelays.count {
            let delay = retryDelays[retriesScheduled]
            retriesScheduled += 1
            set(.usbOnly, "USB 已连接 · SDK 等待就绪",
                "\(message)，\(Int(ceil(delay))) 秒后自动重试（\(retriesScheduled)/\(retryDelays.count)）；也可半按快门唤醒。")
            let expected = deviceSignature, token = generation
            let work = DispatchWorkItem { [weak self] in
                guard let self = self, self.started, !self.operationBusy, !self.isProbing,
                      self.generation == token, self.deviceSignature == expected else { return }
                self.refresh(reason: "sdk-retry-\(self.retriesScheduled)", allowSDKWithoutUSB: false, resetRetries: false)
            }
            retryWork = work
            record("probe_retry_scheduled", ["retry": retriesScheduled, "delaySeconds": delay])
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        } else {
            set(.usbOnly, "USB 已连接 · SDK 尚未识别", "Mac 已看到 Canon USB，自动重试仍未成功。请唤醒相机、选择“照片导入/遥控”，再点“重新检测”。")
        }
    }

    private func set(_ state: CameraConnectionState, _ title: String, _ detail: String) {
        if self.state != state || self.title != title || self.detail != detail {
            record("state_changed", ["state": state.rawValue, "title": title, "detail": detail])
        }
        self.state = state; self.title = title; self.detail = detail
    }

    private func record(_ event: String, _ fields: [String: Any] = [:]) {
        var row = fields
        row["event"] = event
        row["time"] = ISO8601DateFormatter().string(from: Date())
        guard var data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        data.append(10)
        do {
            try FileManager.default.createDirectory(at: diagnosticsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = try? diagnosticsURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 512 * 1024 {
                let previous = diagnosticsURL.deletingPathExtension().appendingPathExtension("previous.jsonl")
                try? FileManager.default.removeItem(at: previous)
                try? FileManager.default.moveItem(at: diagnosticsURL, to: previous)
            }
            let fd = open(diagnosticsURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
            if fd >= 0 {
                data.withUnsafeBytes { bytes in _ = write(fd, bytes.baseAddress, bytes.count) }
                close(fd)
            }
        } catch { /* Connection detection must remain usable if diagnostics cannot be saved. */ }
    }

    private func cancelProbe() {
        generation += 1
        if let task = process {
            if task.isRunning { task.terminate() }
            retiringProcesses.append(task)
            // Reap outside the UI thread; never retain completed children forever.
            DispatchQueue.global(qos: .utility).async {
                if task.isRunning {
                    for _ in 0..<20 { if !task.isRunning { break }; usleep(25000) }
                    if task.isRunning { kill(task.processIdentifier, SIGKILL) }
                }
                task.waitUntilExit()
            }
        }
        retiringProcesses.removeAll(where: { !$0.isRunning })
        process = nil; isProbing = false
    }

    private func scheduleRefresh(force: Bool = false, reason: String = "usb-watchdog") {
        guard started, !operationBusy else { return }
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let signature = self.usbProvider().map { "\($0.id):\($0.name)" }.sorted().joined(separator: "|")
            if force || signature != self.deviceSignature {
                self.refresh(reason: reason, allowSDKWithoutUSB: false, resetRetries: true)
            }
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    private func startUSBFallback() {
        fallbackTimer?.invalidate()
        let timer = Timer(timeInterval: watchdogInterval, repeats: true) { [weak self] _ in
            // Cheap registry enumeration runs even if a notification was missed;
            // unchanged USB signatures never trigger a periodic SDK process.
            self?.scheduleRefresh()
        }
        fallbackTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private static func usbMatching() -> CFMutableDictionary? {
        guard let matching = IOServiceMatching("IOUSBHostDevice") else { return nil }
        let dictionary = matching as NSMutableDictionary
        // IOUSBHostDevice does not match arbitrary top-level property keys.
        // Top-level idVendor falsely returned zero for a live R6 III on macOS 27.
        dictionary[kIOPropertyMatchKey] = ["idVendor": NSNumber(value: 0x04a9)]
        return matching
    }

    private static func canonUSBDevices() -> [(id: UInt64, name: String)] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, usbMatching(), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var devices: [(UInt64, String)] = []
        while case let device = IOIteratorNext(iterator), device != 0 {
            defer { IOObjectRelease(device) }
            let vendor = IORegistryEntryCreateCFProperty(device, "idVendor" as CFString,
                kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber
            guard vendor?.intValue == 0x04a9 else { continue }
            var identifier: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(device, &identifier)
            let name = IORegistryEntryCreateCFProperty(device, "USB Product Name" as CFString,
                kCFAllocatorDefault, 0)?.takeRetainedValue() as? String ?? "Canon USB 设备"
            devices.append((identifier, name))
        }
        return devices
    }

    private static var eosUtilityIsRunning: Bool {
        NSWorkspace.shared.runningApplications.contains(where: isEOSUtility)
    }

    private static func isEOSUtility(_ app: NSRunningApplication) -> Bool {
        let name = app.localizedName?.lowercased() ?? ""
        let path = app.bundleURL?.path.lowercased() ?? ""
        // EOS Utility Launcher alone is not proof that it owns the camera.
        return name == "eos utility 3" || path.hasSuffix("/eos utility 3.app")
    }
}
