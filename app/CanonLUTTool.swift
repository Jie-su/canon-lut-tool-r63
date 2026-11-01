import AppKit
import SwiftUI
import UniformTypeIdentifiers
import CryptoKit

private let appTitle = "Canon LUT 工具"

private func savedProfileLabel(_ row: [String: Any]) -> String {
    if let label = row["profileLabel"] as? String, !label.isEmpty { return label }
    if let adaptation = row["adaptation"] as? [String: Any] {
        if let label = adaptation["profileLabel"] as? String, !label.isEmpty { return label }
        if let mode = adaptation["mode"] as? String, mode != "none" { return "照片近似适配：\(mode.uppercased())" }
    }
    return "直接转换 · 无 C-Log 输入适配"
}

struct GeneratedFile: Identifiable {
    var id: String { pf3.path }
    let name: String
    let title: String
    let pf3: URL
    let carrier: URL
    let manifest: URL
    let profileLabel: String
    var slot: Int = 0

    static func fromEvent(_ row: [String: Any]) -> GeneratedFile? {
        guard let pf3 = row["pf3"] as? String,
              let carrier = row["full33"] as? String,
              let manifest = row["manifest"] as? String,
              let title = row["title"] as? String else { return nil }
        return GeneratedFile(name: row["displayName"] as? String ?? URL(fileURLWithPath: pf3).deletingPathExtension().lastPathComponent,
                             title: title, pf3: URL(fileURLWithPath: pf3), carrier: URL(fileURLWithPath: carrier),
                             manifest: URL(fileURLWithPath: manifest), profileLabel: savedProfileLabel(row))
    }
}

enum ToolError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

private func sha256(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}

private func timestamp() -> String {
    let format = DateFormatter()
    format.locale = Locale(identifier: "en_US_POSIX")
    format.dateFormat = "yyyyMMdd-HHmmss"
    return format.string(from: Date())
}

private func cameraFailureSummary(_ detail: String, _ exitCode: Int32) -> String {
    let events = detail.split(separator: "\n").compactMap { line -> [String: Any]? in
        guard let data = String(line).data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    if let event = events.first(where: { $0["event"] as? String == "slot_not_initialized" }) {
        return "用户槽 \(event["slot"] as? Int ?? 0) 尚未初始化。请先用官方 EOS Utility 向该槽注册普通照片风格，退出 EOS Utility 后重试。"
    }
    if let event = events.last(where: { $0["event"] as? String == "discovery" }), event["count"] as? Int == 0 {
        return "未发现相机。请检查数据线、打开并唤醒相机，退出 EOS Utility 后重试。"
    }
    if detail.contains("Pinned SDK hash differs") {
        return "本机 EOS Utility 的 SDK 版本与已验证版本不同，请查看说明与诊断记录。"
    }
    // A successful private fallback supersedes its rejected public attempt.
    var lastWrites: [String: (Int, [String: Any])] = [:]
    for (index, event) in events.enumerated() {
        let kind = event["event"] as? String ?? ""
        if kind.hasPrefix("set_full33") || kind.hasPrefix("set_slot_settings") {
            let phase = kind.hasPrefix("set_full33") ? "full33" : "settings"
            lastWrites["\(event["slot"] as? Int ?? 0)-\(phase)"] = (index, event)
        }
    }
    if let failed = lastWrites.values.sorted(by: { $0.0 < $1.0 }).first(where: { ($0.1["rc"] as? Int ?? 0) != 0 })?.1 {
        return "相机拒绝写入用户槽 \(failed["slot"] as? Int ?? 0)（错误码 \(failed["rc"] as? Int ?? 0)），操作已停止。备份和详细记录已保存。"
    }
    if events.contains(where: { $0["event"] as? String == "snapshot_changed" }) {
        return "相机设置在备份后发生变化，操作已停止。请保持相机设置不变后重试；详细记录已保存。"
    }
    if events.contains(where: { $0["event"] as? String == "offline_preflight_failed" }) {
        return "写入文件或相机备份校验未通过，操作已停止。请重新转换 CUBE，并查看详细记录。"
    }
    if let failed = events.first(where: { $0["event"] as? String == "slot_complete" && $0["freshVerified"] as? Bool == false }) {
        return "用户槽 \(failed["slot"] as? Int ?? 0) 的回读验证未通过。操作已停止，请查看备份和详细记录确认槽位状态。"
    }
    if let failed = events.first(where: { $0["event"] as? String == "open_session" && ($0["rc"] as? Int ?? 0) != 0 }) {
        return "无法连接相机（错误码 \(failed["rc"] as? Int ?? 0)）。请退出 EOS Utility、唤醒相机后重试。"
    }
    return "相机操作未完成（退出码 \(exitCode)）。请查看备份和详细记录。"
}

/// Executes argument arrays directly, without a shell. Output is read off the main thread.
private func runTool(_ executable: URL, _ arguments: [String], environment: [String: String]? = nil,
                     failureSummary: ((String, Int32) -> String)? = nil,
                     onLine: @escaping (String) -> Void) throws -> String {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    if let environment = environment { process.environment = environment }
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    var pending = Data()
    var complete = Data()
    while true {
        let data = pipe.fileHandleForReading.availableData
        if data.isEmpty { break }
        complete.append(data)
        pending.append(data)
        while let newline = pending.firstIndex(of: 10) {
            let line = String(decoding: pending[..<newline], as: UTF8.self)
            pending.removeSubrange(...newline)
            onLine(line)
        }
    }
    if !pending.isEmpty { onLine(String(decoding: pending, as: UTF8.self)) }
    process.waitUntilExit()
    let output = String(decoding: complete, as: UTF8.self)
    guard process.terminationStatus == 0 else {
        if let summary = failureSummary { throw ToolError.message(summary(output, process.terminationStatus)) }
        let tail = output.split(separator: "\n").suffix(12).joined(separator: "\n")
        throw ToolError.message(tail.isEmpty ? "工具运行失败（\(process.terminationStatus)）。" : tail)
    }
    return output
}

final class AppModel: ObservableObject {
    let camera: CameraConnectionMonitor

    init() {
        camera = CameraConnectionMonitor(
            helper: Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("eds_r6_tool"),
            sdkCandidates: [
                "/Applications/Canon Utilities/EOS Utility/EU3/EOS Utility 3.app/Contents/Frameworks/EDSDK.framework/Versions/A/EDSDK",
                "/Applications/Canon Utilities/EOS Utility/EOS Utility 3.app/Contents/Frameworks/EDSDK.framework/Versions/A/EDSDK"
            ])
        if let saved = UserDefaults.standard.string(forKey: "r6lut.public.contextPath") {
            contextURL = URL(fileURLWithPath: saved)
        }
    }

    @Published var contextURL: URL?
    var contextReady: Bool {
        guard let url = contextURL else { return false }
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("context.json").path)
    }
    @Published var source: URL?
    @Published var outputParent: URL?
    @Published var output: URL?
    @Published var backup: URL?
    @Published var files: [GeneratedFile] = []
    @Published var busy = false {
        didSet { camera.setOperationBusy(busy) }
    }
    @Published var status = "导入一个 CUBE 文件，或选择包含 CUBE 的文件夹。"
    @Published var error: String?
    @Published var log = ""
    @Published var completed = 0
    @Published var total = 0
    @Published var isTargeted = false
    @Published var showLog = false
    @Published var adaptLogInput = false
    @Published var logCurve = "clog3"
    @Published var logGamut = "cinema-gamut"
    @Published var lutOutput = "gamma24"
    @Published var advancedColorSettings = false

    private var resources: URL { Bundle.main.resourceURL! }
    private var helper: URL { Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("eds_r6_tool") }
    private var python: URL { resources.appendingPathComponent("python/bin/python3.13") }
    private let sdkCandidates = [
        "/Applications/Canon Utilities/EOS Utility/EU3/EOS Utility 3.app/Contents/Frameworks/EDSDK.framework/Versions/A/EDSDK",
        "/Applications/Canon Utilities/EOS Utility/EOS Utility 3.app/Contents/Frameworks/EDSDK.framework/Versions/A/EDSDK"
    ]
    var selectedCount: Int { files.filter { $0.slot > 0 }.count }

    private func appendLog(_ line: String) {
        log += line + "\n"
        if log.count > 48000 { log = String(log.suffix(40000)) }
    }

    /// Only reads the camera. User-owned calibration stays outside the app/repository.
    func setupContext() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.title = "选择自己用 PSE 导出的 Standard 基础 PF3"
        panel.message = "请先用官方 EOS Utility 将同一份 Standard 基底注册到用户定义 1，再退出 EOS Utility。配置只读取相机，不写入槽位。"
        panel.allowedContentTypes = [UTType(filenameExtension: "pf3") ?? .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let base = panel.url else { return }
        let alert = NSAlert()
        alert.messageText = "获取本机配置"
        alert.informativeText = "使用已初始化的 R6 Mark III 1.1.2。可以只读获取连接相机的快照，或选择本工具已有的完整快照文件夹。基底和快照仅保存在本机，不包含在开源仓库或 App 中。"
        alert.addButton(withTitle: "读取已连接相机（只读）")
        alert.addButton(withTitle: "导入已有快照")
        alert.addButton(withTitle: "取消")
        let choice = alert.runModal()
        guard choice == .alertFirstButtonReturn || choice == .alertSecondButtonReturn else { return }
        var imported: URL?
        if choice == .alertSecondButtonReturn {
            let folders = NSOpenPanel()
            folders.title = "选择含 manifest.json 的相机快照文件夹"
            folders.canChooseFiles = false; folders.canChooseDirectories = true
            guard folders.runModal() == .OK, let folder = folders.url else { return }
            imported = folder
        }
        let sdk = sdkCandidates.first(where: { FileManager.default.fileExists(atPath: $0) })
        if imported == nil && sdk == nil { error = "请先安装官方 EOS Utility 3，再读取相机配置。"; return }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Canon LUT Tool R63", isDirectory: true)
        let unique = "\(timestamp())-\(UUID().uuidString.prefix(6))"
        let target = support.appendingPathComponent("profiles/" + unique, isDirectory: true)
        let session = support.appendingPathComponent("setup/" + unique, isDirectory: true)
        let snapshot = imported ?? session.appendingPathComponent("snapshot", isDirectory: true)
        let helper = helper, executable = python
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONHOME"] = resources.appendingPathComponent("python").path
        environment["PYTHONPATH"] = resources.appendingPathComponent("backend").path
        environment["PYTHONNOUSERSITE"] = "1"; environment["PYTHONDONTWRITEBYTECODE"] = "1"
        busy = true; error = nil; status = "正在验证本机配置…"
        camera.prepareForExclusiveCameraAccess {
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if imported == nil {
                        _ = try runTool(helper, ["snapshot", sdk!, snapshot.path], failureSummary: cameraFailureSummary) { _ in }
                    }
                    let result = try runTool(executable, ["-B", "-m", "r6lut", "setup-context", "--base", base.path,
                        "--camera-data", snapshot.path, "--output", target.path], environment: environment) { _ in }
                    try result.write(to: session.appendingPathComponent("setup.log"), atomically: true, encoding: .utf8)
                    DispatchQueue.main.async {
                        self.contextURL = target
                        UserDefaults.standard.set(target.path, forKey: "r6lut.public.contextPath")
                        self.busy = false; self.status = "本机配置已建立，可转换 CUBE。配置文件只保存在这台 Mac。"
                    }
                } catch {
                    DispatchQueue.main.async { self.busy = false; self.error = error.localizedDescription; self.status = "配置未完成；原有配置保持可用。" }
                }
            }
        }
    }

    func chooseInput(folder: Bool) {
        let panel = NSOpenPanel()
        panel.title = folder ? "选择包含 CUBE 的文件夹" : "导入 CUBE"
        panel.canChooseDirectories = folder
        panel.canChooseFiles = !folder
        panel.allowsMultipleSelection = false
        if !folder { panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data] }
        if panel.runModal() == .OK, let url = panel.url { convert(url) }
    }

    func chooseOutputParent() {
        let panel = NSOpenPanel()
        panel.title = "选择输出文件夹的保存位置"
        panel.prompt = "选择保存位置"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = outputParent ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        if panel.runModal() == .OK, let chosen = panel.url {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: chosen.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                error = "输出位置必须是文件夹，请重新选择保存位置。"; return
            }
            outputParent = chosen
            error = nil
        }
    }

    func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !busy, let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
            if let url = url { DispatchQueue.main.async { self.convert(url) } }
        }
        return true
    }

    func convert(_ input: URL) {
        guard !busy else { return }
        guard contextReady, let context = contextURL else { error = "请先点击「建立本机配置」，导入自己的 Standard 基底和相机快照。照片对比无需此配置。"; return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: input.path, isDirectory: &isDirectory),
              isDirectory.boolValue || input.pathExtension.lowercased() == "cube" else {
            error = "请选择 .cube 文件或包含 CUBE 的文件夹。"; return
        }
        guard FileManager.default.isExecutableFile(atPath: python.path) else { error = "应用中的转换运行环境不完整，请重新构建应用。"; return }
        let parent = outputParent ?? (isDirectory.boolValue ? input : input.deletingLastPathComponent())
        var target = parent.appendingPathComponent("PF3 输出-\(timestamp())", isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = parent.appendingPathComponent("PF3 输出-\(timestamp())-\(suffix)", isDirectory: true); suffix += 1
        }
        source = input; output = target; files = []; error = nil; backup = nil
        busy = true; completed = 0; total = 0; log = ""; status = "正在读取 CUBE…"
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONHOME"] = resources.appendingPathComponent("python").path
        environment["PYTHONPATH"] = resources.appendingPathComponent("backend").path
        environment["PYTHONNOUSERSITE"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PYTHONUNBUFFERED"] = "1"
        let executable = python
        // Capture the selected profile once; each output retains its own saved profile.
        let adaptation = adaptLogInput ? logCurve : "none"
        let arguments = ["-B", "-m", "r6lut", "convert", "--input", input.path, "--output", target.path,
                         "--context", context.path,
                         "--adaptation", adaptation, "--log-gamut", logGamut, "--lut-output", lutOutput]
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try runTool(executable, arguments, environment: environment) { line in
                    DispatchQueue.main.async { self.receive(line) }
                }
                DispatchQueue.main.async {
                    self.busy = false
                    self.status = "已生成 \(self.files.count) 个 PF3。选择槽位后，可写入相机。"
                    for index in self.files.indices { self.files[index].slot = index < 3 ? index + 1 : 0 }
                }
            } catch {
                DispatchQueue.main.async { self.busy = false; self.error = error.localizedDescription; self.status = "转换未完成，请查看详情。" }
            }
        }
    }

    private func receive(_ line: String) {
        guard let data = line.data(using: .utf8), let row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let event = row["event"] as? String else { appendLog(line); return }
        if event == "progress" {
            let index = row["index"] as? Int ?? 0
            total = row["total"] as? Int ?? total
            let name = row["displayName"] as? String ?? ""
            status = "\(row["phase"] as? String == "compile" ? "正在生成 PF3" : "正在转换 LUT")：\(name)（\(index)/\(total)）"
        } else if event == "converted", let file = GeneratedFile.fromEvent(row) {
            if !files.contains(where: { $0.id == file.id }) { files.append(file) }
            completed = files.count
        } else if event == "batch_summary", let rows = row["files"] as? [[String: Any]] {
            files = rows.compactMap { GeneratedFile.fromEvent($0) }
            completed = files.count; total = files.count
        }
        appendLog(line)
    }

    func assign(_ slot: Int, to id: String) {
        for index in files.indices {
            if files[index].id == id { files[index].slot = slot }
            else if slot > 0 && files[index].slot == slot { files[index].slot = 0 }
        }
    }

    func openGenerated() {
        let panel = NSOpenPanel()
        panel.title = "打开本工具生成的 PF3（配套文件须保存在一起）"
        panel.allowedContentTypes = [UTType(filenameExtension: "pf3") ?? .data]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        busy = true; error = nil; status = "正在载入 PF3 和配套清单…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let loaded = try urls.map { pf3 -> GeneratedFile in
                    let manifest = pf3.deletingPathExtension().appendingPathExtension("manifest.json")
                    let data = try Data(contentsOf: manifest)
                    guard let row = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          row["schema"] as? String == "r6lut-candidate-v1", let title = row["title"] as? String,
                          let payload = row["full33"] as? [String: Any], let payloadPath = payload["file"] as? String else {
                        throw ToolError.message("\(pf3.lastPathComponent) 的配套清单无效。请重新从 CUBE 转换。")
                    }
                    let carrierName = URL(fileURLWithPath: payloadPath).lastPathComponent
                    let carrier = pf3.deletingLastPathComponent().appendingPathComponent(carrierName)
                    guard FileManager.default.fileExists(atPath: carrier.path) else {
                        throw ToolError.message("找不到 \(carrierName)。请将 PF3、.full33.bin 与 .manifest.json 放在同一文件夹。")
                    }
                    return GeneratedFile(name: pf3.deletingPathExtension().lastPathComponent, title: title, pf3: pf3, carrier: carrier, manifest: manifest,
                                         profileLabel: savedProfileLabel(row))
                }
                DispatchQueue.main.async {
                    self.files = loaded
                    for index in self.files.indices { self.files[index].slot = index < 3 ? index + 1 : 0 }
                    self.output = urls.first?.deletingLastPathComponent(); self.source = nil
                    self.completed = self.files.count; self.total = self.files.count; self.busy = false
                    self.status = "已载入 \(self.files.count) 个 PF3。选择槽位后，可写入相机。"
                }
            } catch {
                DispatchQueue.main.async { self.busy = false; self.error = error.localizedDescription; self.status = "载入未完成，请检查配套文件。" }
            }
        }
    }

    func install() {
        let selected = files.filter { $0.slot > 0 }.sorted { $0.slot < $1.slot }
        guard !busy, !selected.isEmpty else { return }
        guard contextReady else { error = "写入前请先建立并验证本机配置。"; return }
        guard camera.canAttemptWrite else {
            error = "请先连接并唤醒 R6 Mark III，等待上方检测到相机；如 EOS Utility 正在运行，请先退出它。"; return
        }
        guard let sdk = sdkCandidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            error = "未找到 Canon EOS Utility 3。请先安装官方 EOS Utility，再使用本工具。"; return
        }
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { error = "应用中的相机写入组件不完整，请重新构建应用。"; return }
        let alert = NSAlert()
        alert.messageText = "写入 EOS R6 Mark III"
        alert.informativeText = selected.map { "用户槽 \($0.slot)：\($0.pf3.lastPathComponent)\n\($0.profileLabel)" }.joined(separator: "\n\n")
            + "\n\n将先备份相机当前设置，再替换以上槽位。请连接并唤醒相机，退出 EOS Utility；写入期间保持 USB 连接。"
        alert.addButton(withTitle: "开始写入")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Canon LUT Tool R63/相机备份", isDirectory: true)
        let session = base.appendingPathComponent("\(timestamp())-\(UUID().uuidString.prefix(6))", isDirectory: true)
        busy = true; error = nil; backup = session; status = "正在备份相机当前设置…"
        appendLog("备份与写入记录：\(session.path)")
        let helper = helper
        camera.prepareForExclusiveCameraAccess {
            DispatchQueue.global(qos: .userInitiated).async {
                var sessionLog = ""
                let lineHandler: (String) -> Void = { line in
                    sessionLog += line + "\n"
                    DispatchQueue.main.async { self.appendLog(line) }
                }
                do {
                    try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
                    let before = session.appendingPathComponent("before", isDirectory: true)
                    _ = try runTool(helper, ["snapshot", sdk, before.path], failureSummary: cameraFailureSummary, onLine: lineHandler)
                    let entries: [[String: Any]] = try selected.map { file in
                        ["slot": file.slot, "carrierFile": file.carrier.path, "carrierSha256": try sha256(file.carrier),
                         "sourcePf3File": file.pf3.path, "sourcePf3Sha256": try sha256(file.pf3), "title": file.title,
                         "compilerManifestFile": file.manifest.path, "compilerManifestSha256": try sha256(file.manifest)]
                    }
                    let plan: [String: Any] = ["schema": "r6m3-full33-install-v1", "slots": entries]
                    let planURL = session.appendingPathComponent("install-plan.json")
                    try JSONSerialization.data(withJSONObject: plan, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: planURL, options: .atomic)
                    DispatchQueue.main.async { self.status = "备份完成，正在写入 \(selected.count) 个槽位并回读验证…" }
                    _ = try runTool(helper, ["install", sdk, before.path, planURL.path,
                                             session.appendingPathComponent("installation", isDirectory: true).path, "--validated-full33"], failureSummary: cameraFailureSummary, onLine: lineHandler)
                    try sessionLog.write(to: session.appendingPathComponent("session.log"), atomically: true, encoding: .utf8)
                    DispatchQueue.main.async { self.busy = false; self.status = "已完成 \(selected.count) 个槽位的写入与回读验证。备份和报告已保存。" }
                } catch {
                    try? (sessionLog + "\n" + error.localizedDescription).write(to: session.appendingPathComponent("session.log"), atomically: true, encoding: .utf8)
                    DispatchQueue.main.async {
                        self.busy = false; self.error = error.localizedDescription
                        self.status = "写入未完成，已保留备份及诊断记录。"
                    }
                }
            }
        }
    }
}

struct CameraConnectionCard: View {
    @ObservedObject var camera: CameraConnectionMonitor
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "camera.fill").font(.title2)
                .foregroundStyle(camera.canAttemptWrite ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(camera.title).font(.callout.weight(.semibold))
                Text(camera.detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if camera.isProbing { ProgressView().controlSize(.small) }
            Button("连接诊断") { NSWorkspace.shared.open(camera.diagnosticsURL.deletingLastPathComponent()) }
            Button("重新检测") { camera.refresh() }.disabled(camera.isProbing)
        }.padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct ConversionView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var camera: CameraConnectionMonitor
    let onPreview: (GeneratedFile) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: model.contextReady ? "checkmark.seal.fill" : "folder.badge.gearshape")
                    .font(.title2).foregroundStyle(model.contextReady ? Color.green : Color.blue)
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.contextReady ? "本机配置已就绪" : "首次使用：建立本机配置").font(.headline)
                    Text("转换和写入使用你自己的 PSE Standard 基底与相机快照。照片对比可直接使用。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.contextReady ? "更换本机配置…" : "建立本机配置…", action: model.setupContext).disabled(model.busy)
            }.padding(14).background(Color.blue.opacity(0.065), in: RoundedRectangle(cornerRadius: 10))
            VStack(spacing: 12) {
                Image(systemName: "square.and.arrow.down").font(.system(size: 25)).foregroundStyle(.blue)
                Text(model.source?.lastPathComponent ?? "将 CUBE 文件或文件夹拖到这里").font(.headline).lineLimit(2)
                HStack {
                    Button("导入 CUBE") { model.chooseInput(folder: false) }.disabled(!model.contextReady)
                    Button("转换文件夹") { model.chooseInput(folder: true) }.disabled(!model.contextReady)
                    Button("打开已生成 PF3") { model.openGenerated() }
                }.disabled(model.busy)
            }
            .frame(maxWidth: .infinity).padding(20)
            .background(RoundedRectangle(cornerRadius: 14).fill(model.isTargeted ? Color.blue.opacity(0.12) : Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(model.isTargeted ? Color.blue : Color.secondary.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [6])))
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $model.isTargeted, perform: model.acceptDrop)
            HStack {
                Text("输出位置：\(model.outputParent?.path ?? "原文件旁的新文件夹")").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("更改…") { model.chooseOutputParent() }.disabled(model.busy)
                if let output = model.output { Button("打开输出文件夹") { NSWorkspace.shared.open(output) } }
            }
            if model.total > 0 && model.busy { ProgressView(value: Double(model.completed), total: Double(model.total)) }
            Text(model.status).font(.callout).textSelection(.enabled)
            if let error = model.error {
                ScrollView { Text(error).font(.callout).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                    .frame(maxHeight: 90).padding(10).background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            }
            if !model.files.isEmpty {
                HStack { Text("已生成 \(model.files.count) 个 PF3").font(.headline); Spacer(); Text("写入槽位").font(.caption).foregroundStyle(.secondary) }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.files) { file in
                            HStack {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(file.pf3.lastPathComponent).font(.body).lineLimit(1)
                                    Text(file.profileLabel).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    Text("相机名称：\(file.title)").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("照片预览") { onPreview(file) }.disabled(model.busy)
                                Picker("槽位", selection: Binding(get: { model.files.first(where: { $0.id == file.id })?.slot ?? 0 }, set: { model.assign($0, to: file.id) })) {
                                    Text("不写入").tag(0)
                                    ForEach(1...3, id: \.self) { Text("用户 \($0)").tag($0) }
                                }.labelsHidden().frame(width: 108).disabled(model.busy)
                            }.padding(.vertical, 10).padding(.horizontal, 12)
                            Divider()
                        }
                    }
                }.frame(height: min(320, max(110, CGFloat(model.files.count) * 88))).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            } else { Spacer(minLength: 0) }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text("PF3 与配套载荷会一起保存。保留 LUT 效果请用本工具写入；普通 EOS Utility 导入会重新生成色彩表。当前支持已验证的 R6 Mark III 1.1.2。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(model.showLog ? "隐藏详情" : "显示详情") { model.showLog.toggle() }.buttonStyle(.link)
                if let backup = model.backup { Button("查看备份与报告") { NSWorkspace.shared.open(backup) }.buttonStyle(.link) }
                Spacer()
                Button("写入相机（\(model.selectedCount) 个槽位）") { model.install() }
                    .buttonStyle(.borderedProminent).disabled(model.busy || !model.contextReady || model.selectedCount == 0 || !camera.canAttemptWrite)
            }
            if model.showLog {
                ScrollView { Text(model.log.isEmpty ? "尚无运行记录。" : model.log).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(height: 120).padding(10).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

final class ToolNavigation: ObservableObject {
    @Published var page = "convert"
    @Published var previewFailure: String?
    @Published var loadingPreview = false
}

private struct StudioCameraStatus: View {
    @ObservedObject var camera: CameraConnectionMonitor
    var body: some View {
        Menu {
            Text(camera.title)
            Text(camera.detail)
            Divider()
            Button("重新检测") { camera.refresh() }.disabled(camera.isProbing)
            Button("连接诊断") { NSWorkspace.shared.open(camera.diagnosticsURL.deletingLastPathComponent()) }
        } label: {
            HStack(spacing: 8) {
                Circle().fill(camera.canAttemptWrite ? Color.green : Color.gray).frame(width: 6, height: 6)
                Image(systemName: "camera").font(.system(size: 13))
                Text(camera.title.replacingOccurrences(of: "已发现 ", with: ""))
                    .font(.system(size: 11)).lineLimit(1)
                if camera.isProbing { ProgressView().controlSize(.mini) }
            }.padding(.horizontal, 10).padding(.vertical, 7)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
        }.menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 250).help(camera.title + "\n" + camera.detail)
    }
}

struct ContentView: View {
    @StateObject private var model = AppModel()
    @StateObject private var preview = PhotoPreviewModel()
    @StateObject private var navigation = ToolNavigation()
    private var camera: CameraConnectionMonitor { model.camera }

    private func updatePreview() {
        preview.configure(cubeURL: preview.cubeURL,
                          adaptation: model.adaptLogInput ? model.logCurve : "none",
                          logGamut: model.logGamut, lutOutput: model.lutOutput)
    }

    private func previewGenerated(_ file: GeneratedFile) {
        navigation.previewFailure = nil
        preview.configurePF3(url: file.pf3)
        navigation.page = "preview"
    }

    private var colorSettings: some View {
            VStack(alignment: .leading, spacing: 9) {
                Toggle("C-Log 输入适配（照片近似）", isOn: $model.adaptLogInput).toggleStyle(.checkbox)
                if model.adaptLogInput {
                    HStack {
                        Picker("输入曲线", selection: $model.logCurve) {
                            Text("C-Log 3").tag("clog3")
                            Text("C-Log 2").tag("clog2")
                        }.frame(width: 220)
                        Text("照片直出近似适配，效果需实拍确认。")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                    DisclosureGroup("高级色彩设置", isExpanded: $model.advancedColorSettings) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 20) {
                                Picker("LUT 色域", selection: $model.logGamut) {
                                    Text("Cinema Gamut").tag("cinema-gamut")
                                    Text("BT.709").tag("bt709")
                                    Text("BT.2020").tag("bt2020")
                                }
                                Picker("LUT 输出", selection: $model.lutOutput) {
                                    Text("Rec.709 Gamma 2.4").tag("gamma24")
                                    Text("sRGB").tag("srgb")
                                    Text("与输入相同的 C-Log / 色域").tag("same-log")
                                }
                            }
                            Text("以 sRGB 近似基础色表；色域和 LUT 输出按原说明选择。CUBE 不含输入标记。")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 8)
                    }
                } else {
                    Text("关闭时按原始数值直接转换。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.disabled(model.busy)
    }

    private var studioHeader: some View {
        HStack(spacing: 18) {
            HStack(spacing: 10) {
                if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
                   let icon = NSImage(contentsOf: url) {
                    Image(nsImage: icon).resizable().frame(width: 34, height: 34)
                } else {
                    Image(systemName: "cube.transparent.fill").font(.system(size: 25)).foregroundStyle(.blue)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(appTitle).font(.system(size: 15, weight: .semibold))
                    Text("COLOR WORKSPACE  ·  \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版")")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .tracking(0.7).foregroundStyle(.secondary)
                }
            }
            Divider().frame(height: 28)
            Picker("功能", selection: $navigation.page) {
                Text("转换与写入").tag("convert")
                Text("照片对比").tag("preview")
            }.pickerStyle(.segmented).labelsHidden().frame(width: 238)
            Spacer(minLength: 10)
            if model.busy || navigation.loadingPreview { ProgressView().controlSize(.small) }
            StudioCameraStatus(camera: camera)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(Color(red: 0.115, green: 0.125, blue: 0.14))
    }

    private func sidebarSection<Content: View>(_ title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            VStack(alignment: .leading, spacing: 5) {
                Text(subtitle).font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(1.6).foregroundStyle(Color.blue.opacity(0.9))
                Text(title).font(.system(size: 14, weight: .semibold))
            }
            content()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
    }

    private var cubeFolderBrowser: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button(action: preview.chooseCubeFolder) {
                    Label("导入预设文件夹…", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                Button(action: preview.refreshCubeFolder) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(preview.folderURL == nil || preview.isScanningFolder)
                .help("重新扫描当前文件夹及子文件夹")
                .accessibilityLabel("刷新 CUBE / PF3 文件夹")
            }
            if let folderError = preview.folderError {
                Label(folderError, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if let folder = preview.folderURL {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill").foregroundStyle(.blue)
                    Text(folder.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    if preview.isScanningFolder { ProgressView().controlSize(.mini) }
                    else {
                        Text("\(preview.folderEntries.count) 个")
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .font(.system(size: 11, weight: .medium)).help(folder.path)
                Toggle("sRGB LUT · 直接套用", isOn: $preview.folderUsesSRGB)
                    .toggleStyle(.switch).font(.system(size: 11))
                    .disabled(!preview.folderEntries.contains { !$0.isPF3 })
                    .help("仅作用于 CUBE：开启时不使用 C-Log 适配。PF3 始终使用预设内置设置。")
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索 CUBE / PF3…", text: $preview.folderSearch)
                        .textFieldStyle(.plain).font(.system(size: 11))
                    if !preview.folderSearch.isEmpty {
                        Button { preview.folderSearch = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }.buttonStyle(.plain).accessibilityLabel("清除搜索")
                    }
                }
                .padding(8).background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 5))
                if preview.filteredFolderEntries.isEmpty {
                    Text(preview.isScanningFolder ? "正在查找 CUBE / PF3…" : preview.folderEntries.isEmpty ? "文件夹及子文件夹内没有 CUBE 或 PF3 文件。" : "没有匹配的预设。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(preview.filteredFolderEntries) { entry in
                                cubeFolderRow(entry)
                            }
                        }.padding(4)
                    }
                    .frame(height: min(260, CGFloat(preview.filteredFolderEntries.count) * 44 + 8))
                    .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
                    .disabled(preview.isScanningFolder)
                }
                HStack {
                    Text("\(preview.lookURL == nil ? "多图对比" : preview.lookKind + " 对比") \(preview.selectedLookURLs.count) / \(PhotoPreviewModel.maximumComparisons)")
                        .font(.system(size: 10, weight: .medium)).monospacedDigit()
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("清空", action: preview.clearComparisonSelection)
                        .buttonStyle(.link).font(.system(size: 10))
                        .disabled(preview.selectedLookURLs.isEmpty)
                }
                Text("点击名称预览；最多勾选 \(PhotoPreviewModel.maximumComparisons) 个预设与原图比较。切换 CUBE／PF3 会新建比较组。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if preview.isScanningFolder {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在扫描 CUBE / PF3 文件夹…")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(.vertical, 6)
            } else {
                Text("导入文件夹即可浏览 CUBE 和 PF3，包含子文件夹。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func cubeFolderRow(_ entry: CubeLibraryEntry) -> some View {
        let selected = preview.selectedLookURLs.contains(entry.url)
        let active = preview.lookURL == entry.url
        let switchesGroup = !preview.selectedLookURLs.isEmpty && entry.isPF3 != preview.isPF3Preview
        let atLimit = !selected && !switchesGroup && preview.selectedLookURLs.count >= PhotoPreviewModel.maximumComparisons
        return HStack(spacing: 5) {
            Button { preview.showFolderCube(entry.url) } label: {
                HStack(spacing: 8) {
                    Image(systemName: entry.isPF3 ? "doc.badge.gearshape" : "cube.transparent")
                        .foregroundStyle(active ? Color.blue : Color.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.name).font(.system(size: 11, weight: active ? .semibold : .regular))
                            .lineLimit(1).truncationMode(.middle)
                        if entry.relativePath != entry.url.lastPathComponent {
                            Text(entry.relativePath).font(.system(size: 9)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 0)
                    Text(entry.format)
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundStyle(entry.isPF3 ? Color.purple.opacity(0.9) : Color.secondary)
                        .padding(.horizontal, 4).padding(.vertical, 3)
                        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 3))
                }.frame(maxWidth: .infinity, minHeight: 32, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(entry.url.path)
            .accessibilityLabel("预览 \(entry.name)")
            Button { preview.toggleComparisonLook(entry.url) } label: {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15)).foregroundStyle(selected ? Color.blue : Color.secondary)
                    .frame(width: 26, height: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(atLimit)
            .accessibilityLabel("\(selected ? "从对比中移除" : "加入多图对比") \(entry.name)")
            .help(selected ? "从对比中移除" : atLimit ? "最多同时对比 \(PhotoPreviewModel.maximumComparisons) 个预设" : switchesGroup ? "切换到 \(entry.format) 比较组，并选择此预设" : "加入多图对比")
        }
        .padding(.leading, 8).padding(.trailing, 3).padding(.vertical, 2)
        .background(active ? Color.blue.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
    }

    private var previewSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                sidebarSection("输入照片", subtitle: "01 / SOURCE") {
                    Button(action: preview.choosePhoto) {
                        Label("导入照片…", systemImage: "photo.badge.plus").frame(maxWidth: .infinity)
                    }.controlSize(.large)
                    Text(preview.photoURL?.lastPathComponent ?? "JPEG · PNG · HEIC · TIFF · RAW")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        .help(preview.photoURL?.path ?? "支持 macOS 能显影的 RAW／CR3")
                    if let image = preview.before {
                        Text("\(image.width) × \(image.height) · sRGB 预览")
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                Divider()
                sidebarSection("LUT / 照片风格", subtitle: "02 / LOOK") {
                    HStack(spacing: 10) {
                        Image(systemName: "cube.transparent").font(.title2).foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(preview.lookURL?.deletingPathExtension().lastPathComponent ?? "尚未选择风格")
                                .font(.system(size: 12, weight: .medium)).lineLimit(2)
                            Text(preview.lookURL == nil ? "支持 CUBE 与 PF3 预设" : "\(preview.lookKind) · 当前预览")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }.padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 7))
                        .help(preview.lookURL?.path ?? "")
                    Button(action: preview.chooseLook) {
                        Label("选择 CUBE / PF3…", systemImage: "folder").frame(maxWidth: .infinity)
                    }
                    Text(preview.profileDescription).font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider().padding(.vertical, 2)
                    cubeFolderBrowser
                }
                Divider()
                sidebarSection("输入适配", subtitle: "03 / COLOR") {
                    if preview.isPF3Preview {
                        Label("使用预设内置设置", systemImage: "checkmark.seal")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(.blue)
                        Text("PF3 已保存颜色设置，不额外应用 C-Log 适配。若要更改 LUT 输入适配，请选择原始 CUBE。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if preview.usesFolderSRGB {
                        Label("sRGB LUT · 直接套用", systemImage: "checkmark.seal")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(.blue)
                        Text("当前文件夹使用普通 sRGB 照片输入，不额外应用 C-Log。切换文件夹中的 CUBE 会保留此设置。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Toggle("C-Log 照片适配", isOn: $model.adaptLogInput).toggleStyle(.switch)
                            .font(.system(size: 12))
                        if model.adaptLogInput {
                            Picker("输入曲线", selection: $model.logCurve) {
                                Text("C-Log 3").tag("clog3")
                                Text("C-Log 2").tag("clog2")
                            }.pickerStyle(.segmented).labelsHidden()
                            DisclosureGroup("高级色彩设置", isExpanded: $model.advancedColorSettings) {
                                VStack(alignment: .leading, spacing: 9) {
                                    Text("LUT 色域").font(.caption).foregroundStyle(.secondary)
                                    Picker("LUT 色域", selection: $model.logGamut) {
                                        Text("Cinema Gamut").tag("cinema-gamut")
                                        Text("BT.709").tag("bt709")
                                        Text("BT.2020").tag("bt2020")
                                    }.labelsHidden()
                                    Text("LUT 输出").font(.caption).foregroundStyle(.secondary)
                                    Picker("LUT 输出", selection: $model.lutOutput) {
                                        Text("Rec.709 Gamma 2.4").tag("gamma24")
                                        Text("sRGB").tag("srgb")
                                        Text("与输入相同的 C-Log / 色域").tag("same-log")
                                    }.labelsHidden()
                                }.padding(.top, 9)
                            }.font(.caption)
                        }
                        Text(model.adaptLogInput ? "将普通照片近似转换为所选 C-Log 输入后应用 LUT。请按原 LUT 的说明选择色域与输出。" : "普通 LUT 直接应用于显影后的照片；针对 C-Log 的 LUT 可开启适配。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.disabled(model.busy)
                if !model.files.isEmpty {
                    Divider()
                    sidebarSection("已生成的风格", subtitle: "LIBRARY") {
                        ForEach(model.files) { file in
                            Button { previewGenerated(file) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "doc.badge.gearshape").foregroundStyle(.blue)
                                    Text(file.name).lineLimit(1)
                                    Spacer(minLength: 0)
                                    Image(systemName: "arrow.up.right").font(.system(size: 9))
                                }.font(.caption).padding(.vertical, 3)
                            }.buttonStyle(.plain).disabled(model.busy || navigation.loadingPreview)
                        }
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    Label("照片预览", systemImage: "info.circle").font(.caption.weight(.medium))
                    Text(preview.isPF3Preview ? "原生 PF3 使用佳能 RAW 显影；本工具生成的 PF3 使用内嵌色表做照片近似预览。" : "RAW 先由 macOS 显影，再应用 LUT。这里显示近似调色效果，机内 PF3 直出请以实拍为准。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(18)
            }
        }.frame(width: 288).background(Color(red: 0.095, green: 0.105, blue: 0.118))
    }

    var body: some View {
        VStack(spacing: 0) {
            studioHeader
            Divider()
            if navigation.page == "convert" {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        CameraConnectionCard(camera: camera)
                        colorSettings
                        Divider()
                        ConversionView(model: model, camera: camera, onPreview: previewGenerated)
                    }.padding(22).frame(maxWidth: 1180)
                        .frame(maxWidth: .infinity)
                }
            } else {
                HStack(spacing: 0) {
                    previewSidebar
                    Divider()
                    VStack(spacing: 0) {
                        if let failure = navigation.previewFailure {
                            HStack(alignment: .top) {
                                Text(failure).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                                Spacer()
                                Button("关闭") { navigation.previewFailure = nil }.buttonStyle(.link)
                            }.padding(12).background(Color.red.opacity(0.08))
                        }
                        PhotoPreviewPanel(model: preview)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }.background(Color(red: 0.075, green: 0.082, blue: 0.09))
        .frame(minWidth: 1060, idealWidth: 1440, minHeight: 680, idealHeight: 900)
        .onAppear { camera.start(); updatePreview() }
        .onDisappear { camera.stop() }
        .onChange(of: model.adaptLogInput) { _ in updatePreview() }
        .onChange(of: model.logCurve) { _ in updatePreview() }
        .onChange(of: model.logGamut) { _ in updatePreview() }
        .onChange(of: model.lutOutput) { _ in updatePreview() }
        .onChange(of: model.source) { source in
            if let source = source, source.pathExtension.lowercased() == "cube" {
                preview.configure(cubeURL: source, adaptation: model.adaptLogInput ? model.logCurve : "none",
                                  logGamut: model.logGamut, lutOutput: model.lutOutput)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap({ NSImage(contentsOf: $0) }) {
            NSApplication.shared.applicationIconImage = icon
        }
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main struct CanonLUTApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup(appTitle) { ContentView().preferredColorScheme(.dark).tint(Color(red: 0.36, green: 0.59, blue: 1)) }
            .defaultSize(width: 1440, height: 900)
            .commands {
                CommandGroup(replacing: .newItem) {}
                CommandGroup(replacing: .help) {
                    Button("使用说明") {
                        if let url = Bundle.main.url(forResource: "使用说明", withExtension: "txt") { NSWorkspace.shared.open(url) }
                    }
                }
            }
    }
}
