import AppKit
import SwiftUI
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

enum PhotoPreviewError: LocalizedError {
    case message(String)
    case cancelled
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .cancelled: return "预览已取消。"
        }
    }
}

/// Cancellation is shared by native rendering and the short-lived LUT subprocess.
final class PhotoPreviewCancellation {
    private let lock = NSLock()
    private var stopped = false
    private var process: Process?
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func check() throws { if isCancelled { throw PhotoPreviewError.cancelled } }
    func attach(_ value: Process) {
        lock.lock(); process = value; let stop = stopped; lock.unlock()
        if stop && value.isRunning { value.terminate() }
    }
    func cancel() {
        lock.lock(); stopped = true; let child = process; lock.unlock()
        if let child = child, child.isRunning { child.terminate() }
    }
}

struct PreviewDecodedPhoto {
    let width: Int
    let height: Int
    let pixels: [UInt8]
    let image: CGImage
    let isRaw: Bool
}

/// Both the pixels and the lookup are sRGB display CODE values. No implicit
/// Core Image working-space transform is applied during LUT interpolation.
struct PreviewLookup {
    let size: Int
    let rgba: [Float]
    init(directory: URL) throws {
        let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("lookup.json"))) as? [String: Any]
        guard let size = metadata?["size"] as? Int, [17,33,65].contains(size),
              metadata?["schema"] as? String == "r6lut-srgb-preview-v1",
              metadata?["storage"] as? String == "float32-le-rgba-red-fastest" else {
            throw PhotoPreviewError.message("预览色表格式无效，请重新选择 LUT。")
        }
        let data = try Data(contentsOf: directory.appendingPathComponent("lookup.rgba32f"))
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard data.count == size * size * size * 16, metadata?["sha256"] as? String == hash else {
            throw PhotoPreviewError.message("预览色表校验未通过。")
        }
        self.size = size
        self.rgba = data.withUnsafeBytes { raw in
            (0..<(data.count/4)).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0*4, as: UInt32.self))) }
        }
        guard rgba.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else {
            throw PhotoPreviewError.message("预览色表包含无效颜色。")
        }
    }
}

enum PhotoPreviewRenderer {
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let rawExtensions: Set<String> = ["cr3","cr2","crw","dng","nef","nrw","arw","srf","sr2","raf","rw2","rwl","orf","pef","ptx","srw","raw","3fr","fff","iiq","kdc","mos","mrw","x3f"]

    static func decode(_ url: URL, maxDimension: Int = 1600, cancellation: PhotoPreviewCancellation = PhotoPreviewCancellation()) throws -> PreviewDecodedPhoto {
        try cancellation.check()
        let type = UTType(filenameExtension: url.pathExtension)
        let isRaw = rawExtensions.contains(url.pathExtension.lowercased()) || type?.conforms(to: .rawImage) == true
        var image: CIImage
        if isRaw {
            // Never fall back to the embedded JPEG for an unsupported camera.
            guard let raw = CIRAWFilter(imageURL: url) else {
                throw PhotoPreviewError.message("macOS 暂不支持这张 RAW／CR3 的显影。请先用佳能 DPP 或其他显影软件导出 JPEG／TIFF，再导入预览。")
            }
            let dimension = max(raw.nativeSize.width, raw.nativeSize.height)
            guard dimension.isFinite && dimension > 0 else { throw PhotoPreviewError.message("RAW 图像尺寸无效。") }
            raw.scaleFactor = Float(min(1, CGFloat(maxDimension)/dimension))
            raw.isDraftModeEnabled = true
            guard let output = raw.outputImage else {
                throw PhotoPreviewError.message("这张 RAW 无法由当前 macOS 显影。请先导出 JPEG／TIFF 后再预览。")
            }
            image = output
        } else {
            guard let decoded = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
                throw PhotoPreviewError.message("无法读取照片，请选择 JPEG、PNG、HEIC、TIFF 或受支持的 RAW。")
            }
            image = decoded
        }
        try cancellation.check()
        let extent = image.extent
        guard !extent.isInfinite, !extent.isNull, extent.width.isFinite, extent.height.isFinite,
              extent.width > 0, extent.height > 0 else { throw PhotoPreviewError.message("照片尺寸无效，无法生成预览。") }
        image = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let scale = min(1, CGFloat(maxDimension)/max(extent.width, extent.height))
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let width = max(1, Int(floor(extent.width*scale)))
        let height = max(1, Int(floor(extent.height*scale)))
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        image = image.composited(over: CIImage(color: .white).cropped(to: bounds)).cropped(to: bounds)
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .outputPremultiplied: false])
        // createCGImage returns nil on decoder/render errors, unlike the void
        // bitmap render API. Explicit sRGB output retains source ICC handling.
        guard let cg = context.createCGImage(image, from: bounds, format: .RGBA8, colorSpace: colorSpace) else {
            throw PhotoPreviewError.message(isRaw ? "RAW 显影未能完成，请先导出 JPEG／TIFF 后预览。" : "照片无法生成预览。")
        }
        try cancellation.check()
        var pixels = [UInt8](repeating: 0, count: width*height*4)
        guard let bitmap = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width*4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw PhotoPreviewError.message("无法分配照片预览内存。")
        }
        bitmap.draw(cg, in: bounds)
        return PreviewDecodedPhoto(width: width, height: height, pixels: pixels,
            image: try cgImage(pixels: pixels, width: width, height: height), isRaw: isRaw)
    }

    static func apply(_ lookup: PreviewLookup, to input: PreviewDecodedPhoto,
                      cancellation: PhotoPreviewCancellation = PhotoPreviewCancellation()) throws -> CGImage {
        var result = input.pixels
        let n = lookup.size
        let scale = Float(n-1)/255
        try lookup.rgba.withUnsafeBufferPointer { table in
            for y in 0..<input.height {
                if y % 16 == 0 { try cancellation.check() }
                for x in 0..<input.width {
                    let i = (y*input.width+x)*4
                    let rf = Float(input.pixels[i])*scale
                    let gf = Float(input.pixels[i+1])*scale
                    let bf = Float(input.pixels[i+2])*scale
                    let r0 = Int(rf), g0 = Int(gf), b0 = Int(bf)
                    let r1 = min(n-1,r0+1), g1 = min(n-1,g0+1), b1 = min(n-1,b0+1)
                    let tr = rf-Float(r0), tg = gf-Float(g0), tb = bf-Float(b0)
                    let p000 = ((b0*n+g0)*n+r0)*4, p100 = ((b0*n+g0)*n+r1)*4
                    let p010 = ((b0*n+g1)*n+r0)*4, p110 = ((b0*n+g1)*n+r1)*4
                    let p001 = ((b1*n+g0)*n+r0)*4, p101 = ((b1*n+g0)*n+r1)*4
                    let p011 = ((b1*n+g1)*n+r0)*4, p111 = ((b1*n+g1)*n+r1)*4
                    for c in 0..<3 {
                        let a = table[p000+c] + (table[p100+c]-table[p000+c])*tr
                        let b = table[p010+c] + (table[p110+c]-table[p010+c])*tr
                        let d = table[p001+c] + (table[p101+c]-table[p001+c])*tr
                        let e = table[p011+c] + (table[p111+c]-table[p011+c])*tr
                        let near = a+(b-a)*tg, far = d+(e-d)*tg
                        let value = near+(far-near)*tb
                        result[i+c] = UInt8(max(0,min(255,Int((value*255).rounded()))))
                    }
                    result[i+3] = 255
                }
            }
        }
        return try cgImage(pixels: result, width: input.width, height: input.height)
    }

    static func cgImage(pixels: [UInt8], width: Int, height: Int) throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width*4, space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue).union(.byteOrder32Big),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw PhotoPreviewError.message("无法生成预览图片。")
        }
        return image
    }
}

final class PhotoPreviewModel: ObservableObject {
    @Published private(set) var photoURL: URL?
    @Published private(set) var cubeURL: URL?
    @Published private(set) var pf3URL: URL?
    var lookURL: URL? { pf3URL ?? cubeURL }
    var lookKind: String { pf3URL == nil ? "CUBE" : "PF3" }
    var isPF3Preview: Bool { pf3URL != nil }
    @Published private(set) var before: CGImage?
    @Published private(set) var after: CGImage?
    @Published private(set) var isRendering = false
    @Published private(set) var error: String?
    @Published private(set) var status = "导入照片和 CUBE / PF3，查看套用前后的区别。"
    @Published private(set) var profileDescription = "普通 LUT · 直接应用"
    @Published private(set) var previewMethod = "cube"
    @Published private(set) var previewMethodSummary = "CUBE · 照片近似"
    var previewExplanation: String {
        switch previewMethod {
        case "native": return "套用前以 Canon Neutral 显影；前后曝光与拍摄白平衡相同。PF3 为佳能离线显影预览，非机内实拍。"
        case "embedded-lut": return "读取 PF3 内嵌色表；RAW 先由 macOS 显影，展示照片近似效果。PF3 已含适配，不额外应用 C-Log。"
        case "pending-pf3": return "正在识别 PF3 的原生照片风格或内嵌色表；不会额外应用 C-Log。"
        default: return "RAW 先由 macOS 显影；此处展示 LUT 近似效果，与机内 PF3 成像可能不同。"
        }
    }
    @Published var comparisonMode = "side"
    @Published var splitPosition = 0.5
    private var configuration = ["none","cinema-gamut","gamma24"]
    private var decoded: PreviewDecodedPhoto?
    private var lookup: PreviewLookup?
    private var lookupKey: String?
    private var token = PhotoPreviewCancellation()
    private let queue = DispatchQueue(label: "dev.canonlut.photo-preview", qos: .userInitiated)
    deinit { token.cancel() }

    func configure(cubeURL: URL?, adaptation: String, logGamut: String, lutOutput: String) {
        let newConfiguration = [adaptation,logGamut,lutOutput]
        // The host may update its C-Log switches while a native PF3 is selected.
        // Save those choices for the next CUBE, without applying them to PF3.
        if pf3URL != nil, cubeURL == nil {
            configuration = newConfiguration
            return
        }
        let changedKind = pf3URL != nil
        guard changedKind || newConfiguration != configuration || cubeURL != self.cubeURL else { return }
        pf3URL = nil
        previewMethod = "cube"; previewMethodSummary = "CUBE · 照片近似"
        self.cubeURL = cubeURL
        configuration = newConfiguration
        profileDescription = adaptation == "none" ? "CUBE · 普通 LUT 直接应用" : "CUBE · C-Log \(adaptation == "clog2" ? "2" : "3") 照片适配 · \(logGamut == "cinema-gamut" ? "Cinema Gamut" : logGamut.uppercased()) · \(lutOutput == "same-log" ? "Log 输出" : lutOutput == "gamma24" ? "Gamma 2.4 输出" : "sRGB 输出")"
        lookup = nil; lookupKey = nil
        if changedKind { decoded = nil; before = nil; after = nil }
        render()
    }

    func configurePF3(url: URL) {
        pf3URL = url; cubeURL = nil
        profileDescription = "PF3 · 文件内保存的颜色设置"
        previewMethod = "pending-pf3"; previewMethodSummary = "PF3 · 等待识别"
        decoded = nil; lookup = nil; lookupKey = nil
        before = nil; after = nil
        render()
    }

    func choosePhoto() {
        let panel = NSOpenPanel()
        panel.title = "选择照片（RAW 将先显影）"
        panel.allowedContentTypes = [.image,.rawImage]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { loadPhoto(url) }
    }

    func loadPhoto(_ url: URL) {
        photoURL = url; decoded = nil; before = nil; after = nil
        render()
    }

    func chooseLook() {
        let panel = NSOpenPanel()
        panel.title = "选择要预览的 CUBE 或 PF3"
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data,
                                     UTType(filenameExtension: "pf3") ?? .data]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            if url.pathExtension.lowercased() == "pf3" { configurePF3(url: url) }
            else { configure(cubeURL: url, adaptation: configuration[0], logGamut: configuration[1], lutOutput: configuration[2]) }
        }
    }

    // Kept for callers of the original CUBE-only UI.
    func chooseCube() { chooseLook() }

    func cancel() {
        token.cancel(); token = PhotoPreviewCancellation()
        isRendering = false; status = "预览已取消，可重新生成。"
    }

    func render() {
        token.cancel(); token = PhotoPreviewCancellation()
        let current = token
        error = nil; after = nil
        guard let photo = photoURL else { isRendering = false; status = "先导入一张照片，再选择 CUBE 或 PF3。"; return }
        if let pf3 = pf3URL {
            renderPF3(pf3, photo: photo, cancellation: current)
            return
        }
        let cube = cubeURL, config = configuration, cachedPhoto = decoded, cachedLookup = lookup
        let oldKey = lookupKey
        isRendering = true
        status = cachedPhoto == nil ? "正在读取照片…" : "正在生成套用后预览…"
        let resources = Bundle.main.resourceURL
        queue.async {
            do {
                let source = try cachedPhoto ?? PhotoPreviewRenderer.decode(photo, cancellation: current)
                try current.check()
                DispatchQueue.main.async {
                    guard self.token === current else { return }
                    self.decoded = source; self.before = source.image
                    self.status = cube == nil ? "照片已读取，请选择 CUBE 或 PF3。" : "正在应用 CUBE LUT…"
                }
                guard let cube = cube else {
                    DispatchQueue.main.async { if self.token === current { self.isRendering = false } }
                    return
                }
                let modified = (try? cube.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970) ?? 0
                let key = cube.path + "|\(modified)|" + config.joined(separator: "|")
                let table: PreviewLookup
                if oldKey == key, let cached = cachedLookup { table = cached }
                else {
                    guard let resources = resources else { throw PhotoPreviewError.message("预览运行环境缺失，请重新构建应用。") }
                    table = try Self.prepareLookup(cube: cube, configuration: config, resources: resources, cancellation: current)
                }
                let output = try PhotoPreviewRenderer.apply(table, to: source, cancellation: current)
                try current.check()
                DispatchQueue.main.async {
                    guard self.token === current else { return }
                    self.lookup = table; self.lookupKey = key; self.after = output; self.isRendering = false
                    self.status = "\(source.isRaw ? "RAW 已显影" : "照片已读取") · \(source.width) × \(source.height) 预览 · 原文件保持不变"
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.token === current else { return }
                    self.isRendering = false
                    if current.isCancelled { return }
                    self.error = error.localizedDescription; self.status = "未能生成预览。"
                }
            }
        }
    }

    private func renderPF3(_ pf3: URL, photo: URL, cancellation current: PhotoPreviewCancellation) {
        isRendering = true; before = nil
        status = "正在读取 PF3 并生成预览…"
        let resources = Bundle.main.resourceURL
        let helper = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("native_pf3_preview")
        queue.async {
            do {
                guard let resources = resources, let helper = helper else {
                    throw PhotoPreviewError.message("应用缺少 PF3 预览运行环境，请重新安装或构建当前版本。")
                }
                let output = try Self.preparePF3(pf3: pf3, photo: photo, resources: resources,
                                                 helper: helper, cancellation: current)
                try current.check()
                DispatchQueue.main.async {
                    guard self.token === current else { return }
                    self.before = output.before; self.after = output.after
                    self.isRendering = false
                    self.previewMethod = output.mode
                    self.previewMethodSummary = output.label
                    self.profileDescription = output.label + " · 不额外应用 C-Log"
                    self.status = "\(output.label) · \(output.before.width) × \(output.before.height) · \(output.isRaw ? "RAW" : "照片") · 非机内实拍"
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.token === current else { return }
                    self.isRendering = false
                    if current.isCancelled { return }
                    self.error = error.localizedDescription; self.status = "未能生成 PF3 预览。"
                }
            }
        }
    }

    private static func preparePF3(pf3: URL, photo: URL, resources: URL, helper: URL,
                                   cancellation: PhotoPreviewCancellation) throws -> (before: CGImage, after: CGImage, isRaw: Bool, mode: String, label: String) {
        try cancellation.check()
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("CanonPF3Preview-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let process = Process()
        process.executableURL = resources.appendingPathComponent("python/bin/python3.13")
        process.arguments = ["-B", "-m", "r6lut", "preview-pf3", "--input", pf3.path, "--photo", photo.path,
                             "--output", temporary.path, "--helper", helper.path]
        var environment = ProcessInfo.processInfo.environment
        if let context = UserDefaults.standard.string(forKey: "r6lut.public.contextPath") {
            environment["R6LUT_CONTEXT"] = context
        }
        environment["PYTHONHOME"] = resources.appendingPathComponent("python").path
        environment["PYTHONPATH"] = resources.appendingPathComponent("backend").path
        environment["PYTHONNOUSERSITE"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run(); cancellation.attach(process)
        let messages = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); try cancellation.check()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: messages, as: UTF8.self).split(separator: "\n").suffix(6).joined(separator: "\n")
            throw PhotoPreviewError.message("PF3 预览未完成。\n" + detail)
        }
        guard let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: temporary.appendingPathComponent("metadata.json"))) as? [String: Any],
              metadata["schema"] as? String == "r6lut-pf3-preview-v1" else {
            throw PhotoPreviewError.message("PF3 预览结果不完整，请重新生成。")
        }
        let pf3Hash = SHA256.hash(data: try Data(contentsOf: pf3)).map { String(format: "%02x", $0) }.joined()
        let photoHash = SHA256.hash(data: try Data(contentsOf: photo)).map { String(format: "%02x", $0) }.joined()
        guard metadata["pf3Sha256"] as? String == pf3Hash, metadata["photoSha256"] as? String == photoHash else {
            throw PhotoPreviewError.message("照片或 PF3 在生成期间发生变化，请重新预览。")
        }
        let mode = metadata["renderMode"] as? String ?? "native"
        if mode == "embedded-lut" {
            // The PF3 carrier stores the already adapted dense table. Reading
            // it directly must not reapply the current C-Log UI configuration.
            let table = try PreviewLookup(directory: temporary)
            let decoded = try PhotoPreviewRenderer.decode(photo, cancellation: cancellation)
            let after = try PhotoPreviewRenderer.apply(table, to: decoded, cancellation: cancellation)
            try cancellation.check()
            let currentPhotoHash = SHA256.hash(data: try Data(contentsOf: photo)).map { String(format: "%02x", $0) }.joined()
            let currentPF3Hash = SHA256.hash(data: try Data(contentsOf: pf3)).map { String(format: "%02x", $0) }.joined()
            guard currentPhotoHash == photoHash, currentPF3Hash == pf3Hash else {
                throw PhotoPreviewError.message("照片或 PF3 在生成期间发生变化，请重新预览。")
            }
            return (decoded.image, after, decoded.isRaw, mode, "PF3 内嵌色表 · 照片近似")
        }
        guard mode == "native", let width = metadata["width"] as? Int,
              let height = metadata["height"] as? Int, width > 0, height > 0,
              let isRaw = metadata["isRaw"] as? Bool else {
            throw PhotoPreviewError.message("PF3 预览方式或图像尺寸无效，请重新生成。")
        }
        func readPNG(_ name: String) throws -> CGImage {
            guard let source = CGImageSourceCreateWithURL(temporary.appendingPathComponent(name) as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                  image.width == width, image.height == height else {
                throw PhotoPreviewError.message("PF3 预览图无效，请重新生成。")
            }
            return image
        }
        let before = try readPNG("before.png"), after = try readPNG("after.png")
        try cancellation.check()
        return (before, after, isRaw, mode, "Canon 原生 PF3 离线显影")
    }

    private static func prepareLookup(cube: URL, configuration: [String], resources: URL,
                                      cancellation: PhotoPreviewCancellation) throws -> PreviewLookup {
        try cancellation.check()
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("CanonLUTPreview-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let process = Process()
        process.executableURL = resources.appendingPathComponent("python/bin/python3.13")
        process.arguments = ["-B","-m","r6lut","preview-lut","--input",cube.path,"--output",temporary.path,
            "--adaptation",configuration[0],"--log-gamut",configuration[1],"--lut-output",configuration[2],"--size","65"]
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONHOME"] = resources.appendingPathComponent("python").path
        environment["PYTHONPATH"] = resources.appendingPathComponent("backend").path
        environment["PYTHONNOUSERSITE"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run(); cancellation.attach(process)
        let messages = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); try cancellation.check()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: messages, as: UTF8.self).split(separator: "\n").suffix(4).joined(separator: "\n")
            throw PhotoPreviewError.message("无法读取这份 CUBE。\n" + detail)
        }
        return try PreviewLookup(directory: temporary)
    }

    func exportPreview() {
        guard let image = after else { return }
        let panel = NSSavePanel(); panel.title = "导出套用后的预览图"
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = (photoURL?.deletingPathExtension().lastPathComponent ?? "照片") + (isPF3Preview ? "-PF3预览.png" : "-LUT预览.png")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url != photoURL, url != lookURL else { error = "请选择其他文件名，保留原文件。"; return }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            error = "无法保存预览图片。"; return
        }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyProfileName: "sRGB"] as CFDictionary)
        if !CGImageDestinationFinalize(destination) { error = "预览图片保存失败。" }
        else { error = nil; status = "预览已导出：\(url.lastPathComponent) · 原文件保持不变" }
    }
}

// The preview is a fixed work area: controls stay visible while the canvas
// receives all remaining height. The host provides the import/settings sidebar.
private enum PreviewStudioColors {
    static let canvas = Color(red: 0.052, green: 0.060, blue: 0.067)
    static let panel = Color(red: 0.103, green: 0.115, blue: 0.126)
    static let raised = Color(red: 0.137, green: 0.152, blue: 0.167)
    static let line = Color.white.opacity(0.085)
    static let muted = Color.white.opacity(0.50)
}

struct PhotoPreviewPanel: View {
    @ObservedObject var model: PhotoPreviewModel
    // Retained for compatibility with earlier hosts. The studio canvas expands
    // with its parent rather than assigning a fixed image height.
    var imageHeight: CGFloat = 300

    var body: some View {
        VStack(spacing: 0) {
            workspaceToolbar
            rule
            comparisonCanvas
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.comparisonMode == "split", model.after != nil {
                splitControl
                rule
            }
            if let error = model.error {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                    Text(error).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
                .foregroundStyle(Color(red: 1, green: 0.56, blue: 0.52))
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Color.red.opacity(0.08))
                rule
            }
            filmstrip
            rule
            statusBar
        }
        .background(PreviewStudioColors.panel)
        .foregroundStyle(.white.opacity(0.88))
        .preferredColorScheme(.dark)
    }

    private var rule: some View {
        Rectangle().fill(PreviewStudioColors.line).frame(height: 1)
    }

    private var workspaceToolbar: some View {
        HStack(spacing: 10) {
            Picker("对比方式", selection: $model.comparisonMode) {
                Text("左右并排").tag("side")
                Text("滑动对比").tag("split")
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 190)
            Text("适合窗口")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(PreviewStudioColors.muted)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(PreviewStudioColors.raised, in: RoundedRectangle(cornerRadius: 5))
            Spacer(minLength: 4)
            if model.isRendering {
                ProgressView().controlSize(.small).scaleEffect(0.8)
                Button("取消", action: model.cancel)
                    .buttonStyle(.bordered).controlSize(.small)
            } else {
                Button(action: model.render) {
                    Label("重新预览", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(model.photoURL == nil)
            }
            Button(action: model.exportPreview) {
                Label("导出 PNG", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent).controlSize(.small)
            .disabled(model.after == nil || model.isRendering)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(PreviewStudioColors.panel)
    }

    @ViewBuilder private var comparisonCanvas: some View {
        if model.comparisonMode == "side" {
            HStack(spacing: 0) {
                imagePane(image: model.before, title: "套用前", subtitle: model.previewMethod == "native" ? "CANON NEUTRAL" : "ORIGINAL", isResult: false)
                Rectangle().fill(PreviewStudioColors.line).frame(width: 1)
                imagePane(image: model.after, title: "套用后", subtitle: model.isPF3Preview ? "PF3 PREVIEW" : "LUT PREVIEW", isResult: true)
            }
            .background(PreviewStudioColors.canvas)
        } else {
            VStack(spacing: 0) {
                HStack {
                    canvasLabel("套用前", subtitle: model.previewMethod == "native" ? "CANON NEUTRAL" : "ORIGINAL")
                    Spacer()
                    canvasLabel("套用后", subtitle: model.isPF3Preview ? "PF3 PREVIEW" : "LUT PREVIEW")
                }.padding(.horizontal, 16).frame(height: 37)
                GeometryReader { geometry in
                    ZStack {
                        PreviewStudioColors.canvas
                        if let before = model.before {
                            splitImage(before: before, available: geometry.size)
                        } else {
                            canvasPlaceholder(isResult: false)
                        }
                    }
                }
                if model.after == nil, model.before != nil {
                    HStack(spacing: 6) {
                        if model.isRendering { ProgressView().controlSize(.mini) }
                        Text(pendingResultText).font(.caption)
                    }
                    .foregroundStyle(PreviewStudioColors.muted)
                    .padding(.bottom, 10)
                }
            }.background(PreviewStudioColors.canvas)
        }
    }

    private func canvasLabel(_ title: String, subtitle: String) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 11, weight: .medium))
            Text(subtitle).font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.28))
        }
        .foregroundStyle(PreviewStudioColors.muted)
    }

    private func imagePane(image: CGImage?, title: String, subtitle: String, isResult: Bool) -> some View {
        VStack(spacing: 0) {
            HStack { canvasLabel(title, subtitle: subtitle); Spacer(minLength: 0) }
                .padding(.horizontal, 16).frame(height: 37)
            ZStack {
                PreviewStudioColors.canvas
                if let image = image {
                    Image(decorative: image, scale: 1).resizable().scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel(isResult ? "套用预设后的照片预览" : "套用预设前的照片预览")
                } else {
                    canvasPlaceholder(isResult: isResult)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var pendingResultText: String {
        if model.isRendering { return "正在生成套用后预览…" }
        if model.error != nil { return "预览未完成，请查看下方提示" }
        if model.photoURL == nil { return "导入照片后在这里查看效果" }
        if model.lookURL == nil { return "选择 CUBE 或 PF3 后生成预览" }
        return "点击“重新预览”生成效果"
    }

    private func canvasPlaceholder(isResult: Bool) -> some View {
        VStack(spacing: 12) {
            if model.isRendering {
                ProgressView().controlSize(.regular)
            } else {
                Image(systemName: isResult ? "slider.horizontal.3" : "photo.on.rectangle.angled")
                    .font(.system(size: 29, weight: .light))
                    .foregroundStyle(.white.opacity(0.25))
            }
            Text(isResult ? pendingResultText : model.isRendering ? "正在读取照片…" : "导入一张照片")
                .font(.system(size: 12, weight: .medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.60))
            if !isResult, model.photoURL == nil {
                Text("JPEG · PNG · HEIC · TIFF · RAW / CR3")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.30))
                Button("导入照片…", action: model.choosePhoto)
                    .buttonStyle(.bordered).controlSize(.small)
                    .padding(.top, 2)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func splitImage(before: CGImage, available: CGSize) -> some View {
        let ratio = CGFloat(before.width) / CGFloat(before.height)
        let width = min(max(1, available.width - 24), max(1, available.height - 20) * ratio)
        let height = width / ratio
        let position = CGFloat(model.splitPosition)
        return ZStack(alignment: .leading) {
            Image(decorative: before, scale: 1).resizable().frame(width: width, height: height)
            if let after = model.after {
                Image(decorative: after, scale: 1).resizable().frame(width: width, height: height)
                    .mask(alignment: .trailing) { Rectangle().frame(width: width * (1 - position)) }
                Rectangle().fill(Color.white.opacity(0.95)).frame(width: 1.5, height: height)
                    .offset(x: width * position - 0.75)
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 29, height: 29)
                    .background(.black.opacity(0.80), in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.70), lineWidth: 1))
                    .offset(x: width * position - 14.5)
            }
        }
        .frame(width: width, height: height)
        .clipped()
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            guard model.after != nil else { return }
            model.splitPosition = min(1, max(0, value.location.x / width))
        })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("照片滑动对比，左侧套用前，右侧套用后")
    }

    private var splitControl: some View {
        HStack(spacing: 12) {
            Text("套用前")
            Slider(value: $model.splitPosition, in: 0...1)
                .accessibilityLabel("照片对比分割位置")
                .accessibilityValue("套用前占 \(Int(model.splitPosition * 100))%")
                .help("拖动画面分割线，或用此滑块调整对比位置。")
            Text("套用后")
        }
        .font(.system(size: 10)).foregroundStyle(PreviewStudioColors.muted)
        .padding(.horizontal, 18).padding(.vertical, 8)
        .background(PreviewStudioColors.panel)
    }

    private var filmstrip: some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(PreviewStudioColors.canvas)
                if let before = model.before {
                    Image(decorative: before, scale: 1).resizable().scaledToFit().padding(4)
                } else {
                    Image(systemName: "photo").foregroundStyle(.white.opacity(0.2))
                }
            }
            .frame(width: 78, height: 57)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(model.before == nil ? PreviewStudioColors.line : Color.accentColor.opacity(0.7), lineWidth: 1))
            VStack(alignment: .leading, spacing: 5) {
                Text(model.photoURL?.lastPathComponent ?? "尚未导入照片")
                    .font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    .help(model.photoURL?.path ?? "")
                HStack(spacing: 5) {
                    Image(systemName: model.isPF3Preview ? "slider.horizontal.3" : "cube.transparent")
                    Text(model.lookURL?.lastPathComponent ?? "尚未选择 CUBE / PF3")
                        .lineLimit(1).truncationMode(.middle)
                }
                .font(.system(size: 10)).foregroundStyle(PreviewStudioColors.muted)
                .help(model.lookURL?.path ?? "")
            }
            Spacer(minLength: 10)
            VStack(alignment: .trailing, spacing: 5) {
                if let before = model.before {
                    Text("\(before.width) × \(before.height)")
                        .font(.system(size: 10, design: .monospaced))
                }
                Text("sRGB 预览")
                    .font(.system(size: 10)).foregroundStyle(PreviewStudioColors.muted)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(PreviewStudioColors.panel)
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle().fill(model.error != nil ? Color.red : model.after != nil ? Color.green : Color.white.opacity(0.30))
                    .frame(width: 5, height: 5)
                Text(model.status).font(.system(size: 10)).lineLimit(1).truncationMode(.middle)
                    .help(model.status)
                Spacer(minLength: 0)
            }
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: "info.circle")
                Text(model.previewExplanation)
                    .fixedSize(horizontal: false, vertical: true)
            }.font(.system(size: 10)).foregroundStyle(.white.opacity(0.32))
        }
        .foregroundStyle(PreviewStudioColors.muted)
        .padding(.horizontal, 16).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PreviewStudioColors.panel)
    }
}
