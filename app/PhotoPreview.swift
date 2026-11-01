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

struct CubeLibraryEntry: Identifiable {
    let url: URL
    let relativePath: String
    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
    var isPF3: Bool { url.pathExtension.lowercased() == "pf3" }
    var format: String { isPF3 ? "PF3" : "CUBE" }
}

struct CubeComparisonItem: Identifiable {
    let url: URL
    var image: CGImage?
    var error: String?
    var isRendering = false
    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

enum CubeFolderScanner {
    static func entries(in directory: URL, cancellation: PhotoPreviewCancellation) throws -> [CubeLibraryEntry] {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let manager = FileManager.default
        let values = try root.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true, manager.isReadableFile(atPath: root.path) else {
            throw PhotoPreviewError.message("无法读取这个文件夹，请重新选择可访问的文件夹。")
        }
        var firstError: Error?
        guard let enumerator = manager.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in
                firstError = error
                return false
            }) else { throw PhotoPreviewError.message("无法浏览这个文件夹。") }
        var result: [CubeLibraryEntry] = []
        var seen: Set<URL> = []
        for case let url as URL in enumerator {
            try cancellation.check()
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { continue }
            guard values.isRegularFile == true,
                  ["cube", "pf3"].contains(url.pathExtension.lowercased()) else { continue }
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
            guard canonical.path.hasPrefix(prefix) else { throw PhotoPreviewError.message("文件夹路径发生变化，请重新导入。") }
            guard seen.insert(canonical).inserted else { continue }
            let relative = String(canonical.path.dropFirst(prefix.count))
            result.append(CubeLibraryEntry(url: canonical, relativePath: relative))
        }
        try cancellation.check()
        if let error = firstError {
            throw PhotoPreviewError.message("文件夹内有无法读取的目录：\(error.localizedDescription)")
        }
        return result.sorted {
            let order = $0.relativePath.localizedStandardCompare($1.relativePath)
            return order == .orderedSame ? $0.relativePath < $1.relativePath : order == .orderedAscending
        }
    }
}

struct PF3PreviewOutput {
    let before: CGImage
    let after: CGImage
    let isRaw: Bool
    let mode: String
    let label: String
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
    @Published private(set) var folderURL: URL?
    @Published private(set) var folderEntries: [CubeLibraryEntry] = []
    @Published var folderSearch = ""
    @Published private(set) var isScanningFolder = false
    @Published private(set) var folderError: String?
    @Published var folderUsesSRGB = true {
        didSet {
            let hasFolderResult = comparisonMode == "compare" && selectedCubeURLs.contains { url in folderEntries.contains { $0.url == url } }
            if oldValue != folderUsesSRGB, !changingSelection, usesFolderLook || hasFolderResult {
                updateProfileDescription(); render()
            }
        }
    }
    @Published private(set) var selectedCubeURLs: [URL] = []
    @Published private(set) var selectedPF3URLs: [URL] = []
    var selectedLookURLs: [URL] { selectedPF3URLs.isEmpty ? selectedCubeURLs : selectedPF3URLs }
    @Published private(set) var comparisonItems: [CubeComparisonItem] = []
    static let maximumComparisons = 8
    var filteredFolderEntries: [CubeLibraryEntry] {
        let query = folderSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? folderEntries : folderEntries.filter { $0.relativePath.localizedStandardContains(query) }
    }
    private var usesFolderLook: Bool {
        guard pf3URL == nil, let cube = cubeURL else { return false }
        return folderEntries.contains { $0.url == cube }
    }
    var usesFolderSRGB: Bool { folderUsesSRGB && usesFolderLook }
    @Published var comparisonMode = "compare" {
        didSet {
            guard oldValue != comparisonMode, !changingSelection else { return }
            render()
        }
    }
    @Published var splitPosition = 0.5
    // The viewer shares these values across every look and keeps them when
    // only the preset changes. The centre uses image coordinates with its
    // origin at the top-left, independently of the AppKit view's orientation.
    @Published private(set) var previewZoomPercent = 0
    @Published private(set) var previewZoomCenter = CGPoint(x: 0.5, y: 0.5)
    private var rememberedPreviewZoomPercent = 200
    private var configuration = ["none","cinema-gamut","gamma24"]
    private var decoded: PreviewDecodedPhoto?
    private var token = PhotoPreviewCancellation()
    private var folderToken = PhotoPreviewCancellation()
    private var changingSelection = false
    private var lookupCache: [String: PreviewLookup] = [:]
    private var resultCache: [String: CGImage] = [:]
    private var cacheOrder: [String] = []
    private var pf3Cache: [String: PF3PreviewOutput] = [:]
    private var pf3CacheOrder: [String] = []
    private var pf3ReferenceMode: String?
    private let resourcesURL: URL?
    private let helperURL: URL?
    private let pf3PreviewRenderer: ((URL, URL, PhotoPreviewCancellation) throws -> PF3PreviewOutput)?
    private let queue = DispatchQueue(label: "dev.canonlut.photo-preview", qos: .userInitiated)
    private let folderQueue = DispatchQueue(label: "dev.canonlut.cube-folder", qos: .userInitiated)
    init(resourcesURL: URL? = Bundle.main.resourceURL, helperURL: URL? = nil,
         pf3PreviewRenderer: ((URL, URL, PhotoPreviewCancellation) throws -> PF3PreviewOutput)? = nil) {
        self.resourcesURL = resourcesURL
        self.helperURL = helperURL ?? resourcesURL?.deletingLastPathComponent().appendingPathComponent("MacOS/native_pf3_preview")
        self.pf3PreviewRenderer = pf3PreviewRenderer
    }
    deinit { token.cancel(); folderToken.cancel() }

    private func effectiveConfiguration(for cube: URL) -> [String] {
        if folderUsesSRGB, folderEntries.contains(where: { $0.url == cube }) { return ["none", "bt709", "srgb"] }
        return configuration
    }

    private func updateProfileDescription() {
        guard pf3URL == nil else { return }
        let config = cubeURL.map { effectiveConfiguration(for: $0) } ?? configuration
        let adaptation = config[0], logGamut = config[1], lutOutput = config[2]
        profileDescription = usesFolderSRGB ? "CUBE · sRGB 直接套用 · 无 Log 适配" : adaptation == "none" ? "CUBE · 普通 LUT 直接应用" : "CUBE · C-Log \(adaptation == "clog2" ? "2" : "3") 照片适配 · \(logGamut == "cinema-gamut" ? "Cinema Gamut" : logGamut.uppercased()) · \(lutOutput == "same-log" ? "Log 输出" : lutOutput == "gamma24" ? "Gamma 2.4 输出" : "sRGB 输出")"
    }

    func chooseCubeFolder() {
        let panel = NSOpenPanel()
        panel.title = "导入 CUBE / PF3 文件夹（包括子文件夹）"
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { loadCubeFolder(url) }
    }

    func refreshCubeFolder() { if let url = folderURL { loadCubeFolder(url, refreshing: true) } }

    func loadCubeFolder(_ url: URL) { loadCubeFolder(url, refreshing: false) }

    private func loadCubeFolder(_ url: URL, refreshing: Bool) {
        folderToken.cancel(); folderToken = PhotoPreviewCancellation()
        let current = folderToken, directory = url.standardizedFileURL.resolvingSymlinksInPath()
        folderError = nil; isScanningFolder = true
        folderQueue.async {
            do {
                let entries = try CubeFolderScanner.entries(in: directory, cancellation: current)
                DispatchQueue.main.async {
                    guard self.folderToken === current else { return }
                    self.changingSelection = true
                    self.folderURL = directory
                    if !refreshing { self.folderSearch = ""; self.folderUsesSRGB = true }
                    self.folderEntries = entries; self.isScanningFolder = false
                    let available = Set(entries.map(\.url))
                    self.selectedCubeURLs = self.selectedCubeURLs.filter { available.contains($0) && $0.pathExtension.lowercased() == "cube" }
                    self.selectedPF3URLs = self.selectedPF3URLs.filter { available.contains($0) && $0.pathExtension.lowercased() == "pf3" }
                    if !refreshing {
                        let first = entries.first
                        self.pf3URL = first?.isPF3 == true ? first?.url : nil
                        self.cubeURL = first?.isPF3 == false ? first?.url : nil
                        self.selectedCubeURLs = self.cubeURL.map { [$0] } ?? []
                        self.selectedPF3URLs = self.pf3URL.map { [$0] } ?? []
                        self.decoded = nil; self.before = nil; self.after = nil
                    } else if self.lookURL.map({ !available.contains($0) }) == true {
                        if self.pf3URL != nil { self.pf3URL = self.selectedPF3URLs.first }
                        else { self.cubeURL = self.selectedCubeURLs.first }
                        self.before = nil; self.after = nil
                    }
                    if self.pf3URL != nil { self.setPendingPF3Labels() }
                    else { self.previewMethod = "cube"; self.previewMethodSummary = "CUBE · 照片近似" }
                    self.changingSelection = false
                    self.updateProfileDescription()
                    self.render()
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.folderToken === current, !current.isCancelled else { return }
                    self.isScanningFolder = false; self.folderError = error.localizedDescription
                }
            }
        }
    }

    func showFolderCube(_ url: URL) {
        guard let entry = folderEntries.first(where: { $0.url == url }) else { return }
        if entry.isPF3 {
            if selectedPF3URLs.count > 1 {
                if selectedPF3URLs.contains(url) { focusComparisonLook(url) }
                else { toggleComparisonLook(url); focusComparisonLook(url) }
            } else { folderError = nil; configurePF3(url: url) }
            return
        }
        if selectedCubeURLs.count > 1 {
            if !selectedCubeURLs.contains(url) {
                guard selectedCubeURLs.count < Self.maximumComparisons else {
                    folderError = "最多同时对比 8 个 CUBE，加上原图共 9 张，请先取消一个选择。"; return
                }
                selectedCubeURLs.append(url)
                changingSelection = true; comparisonMode = "compare"; changingSelection = false
                cubeURL = url; pf3URL = nil; selectedPF3URLs = []; folderError = nil
                updateProfileDescription(); render()
            } else { focusComparisonCube(url) }
        } else {
            selectedCubeURLs = [url]
            configure(cubeURL: url, adaptation: configuration[0], logGamut: configuration[1], lutOutput: configuration[2])
        }
    }

    func toggleComparisonLook(_ url: URL) {
        if url.pathExtension.lowercased() != "pf3" { toggleComparisonCube(url); return }
        guard selectedPF3URLs.contains(url) || folderEntries.contains(where: { $0.url == url && $0.isPF3 }) else { return }
        let switchedFamily = !selectedCubeURLs.isEmpty || cubeURL != nil
        if selectedPF3URLs.contains(url) { selectedPF3URLs.removeAll { $0 == url } }
        else {
            guard selectedPF3URLs.count < Self.maximumComparisons else {
                folderError = "最多同时对比 8 个 PF3，加上原图共 9 张，请先取消一个选择。"; return
            }
            selectedPF3URLs.append(url)
        }
        changingSelection = true; comparisonMode = "compare"; changingSelection = false
        selectedCubeURLs = []; cubeURL = nil
        if pf3URL == nil || !selectedPF3URLs.contains(pf3URL!) { pf3URL = selectedPF3URLs.last }
        if switchedFamily { decoded = nil; before = nil }
        if pf3URL != nil { setPendingPF3Labels() }
        else {
            pf3ReferenceMode = nil; previewMethod = "cube"; previewMethodSummary = "CUBE · 照片近似"
            before = nil; updateProfileDescription()
        }
        folderError = nil; render()
    }

    func toggleComparisonCube(_ url: URL) {
        guard url.pathExtension.lowercased() == "cube" else { return }
        guard selectedCubeURLs.contains(url) || folderEntries.contains(where: { $0.url == url }) else { return }
        if selectedCubeURLs.contains(url) { selectedCubeURLs.removeAll { $0 == url } }
        else {
            guard selectedCubeURLs.count < Self.maximumComparisons else {
                folderError = "最多同时对比 8 个 CUBE，加上原图共 9 张，请先取消一个选择。"; return
            }
            selectedCubeURLs.append(url)
        }
        changingSelection = true; comparisonMode = "compare"; changingSelection = false
        let changedKind = pf3URL != nil
        pf3URL = nil; selectedPF3URLs = []; previewMethod = "cube"; previewMethodSummary = "CUBE · 照片近似"
        if changedKind { decoded = nil; before = nil }
        if cubeURL == nil || !selectedCubeURLs.contains(cubeURL!) { cubeURL = selectedCubeURLs.last }
        folderError = nil; updateProfileDescription(); render()
    }

    func clearComparisonSelection() {
        selectedCubeURLs = []; selectedPF3URLs = []; comparisonItems = []
        cubeURL = nil; pf3URL = nil; after = nil
        pf3ReferenceMode = nil; previewMethod = "cube"; previewMethodSummary = "CUBE · 照片近似"
        updateProfileDescription()
        folderError = nil; render()
    }

    func focusComparisonLook(_ url: URL) {
        if url.pathExtension.lowercased() != "pf3" { focusComparisonCube(url); return }
        guard selectedPF3URLs.contains(url) else { return }
        pf3URL = url; cubeURL = nil; error = nil
        if comparisonMode == "split" { render() }
        else {
            after = comparisonItems.first { $0.url == url }?.image
            if let photo = photoURL,
               let output = pf3Cache[pf3CacheKey(pf3: url, photo: photo)], output.mode == pf3ReferenceMode, after != nil {
                setPF3Labels(output)
            }
            if !isRendering, after == nil { status = "所选 PF3 未完成预览，请查看对应视图中的提示。" }
        }
    }

    func focusComparisonCube(_ url: URL) {
        guard selectedCubeURLs.contains(url) else { return }
        cubeURL = url; updateProfileDescription()
        if comparisonMode == "split" { render() }
        else { after = comparisonItems.first { $0.url == url }?.image }
    }

    private func setPendingPF3Labels() {
        profileDescription = "PF3 · 文件内保存的颜色设置"
        previewMethod = "pending-pf3"; previewMethodSummary = "PF3 · 等待识别"
    }

    private func setPF3Labels(_ output: PF3PreviewOutput) {
        previewMethod = output.mode; previewMethodSummary = output.label
        profileDescription = output.label + " · 不额外应用 C-Log"
    }

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
        if cubeURL != self.cubeURL || changedKind {
            selectedCubeURLs = cubeURL.map { [$0] } ?? []
            comparisonItems = []
        }
        pf3URL = nil; selectedPF3URLs = []
        previewMethod = "cube"; previewMethodSummary = "CUBE · 照片近似"
        self.cubeURL = cubeURL
        configuration = newConfiguration
        updateProfileDescription()
        if changedKind { decoded = nil; before = nil; after = nil }
        render()
    }

    func configurePF3(url: URL) {
        selectedCubeURLs = []; selectedPF3URLs = [url]; comparisonItems = []
        pf3URL = url; cubeURL = nil
        setPendingPF3Labels()
        decoded = nil; before = nil; after = nil
        render()
    }

    func choosePhoto() {
        let panel = NSOpenPanel()
        panel.title = "选择照片（RAW 将先显影）"
        panel.allowedContentTypes = [.image,.rawImage]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { loadPhoto(url) }
    }

    func setPreviewZoomPercent(_ percent: Int) {
        guard [0, 100, 150, 200].contains(percent) else { return }
        if percent > 0 { rememberedPreviewZoomPercent = percent }
        previewZoomPercent = percent
    }

    func togglePreviewZoom(at point: CGPoint) {
        guard point.x.isFinite, point.y.isFinite else { return }
        if previewZoomPercent > 0 {
            previewZoomPercent = 0
        } else {
            previewZoomCenter = CGPoint(x: min(1, max(0, point.x)), y: min(1, max(0, point.y)))
            previewZoomPercent = rememberedPreviewZoomPercent
        }
    }

    func resetPreviewZoom() {
        previewZoomPercent = 0
        previewZoomCenter = CGPoint(x: 0.5, y: 0.5)
    }

    func loadPhoto(_ url: URL) {
        resetPreviewZoom()
        photoURL = url; decoded = nil; before = nil; after = nil
        resultCache = [:]; pf3Cache = [:]; pf3CacheOrder = []
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
        comparisonItems = comparisonItems.map { CubeComparisonItem(url: $0.url, image: $0.image, error: $0.error, isRendering: false) }
        isRendering = false; status = "预览已取消，可重新生成。"
    }

    private static func cacheKey(cube: URL, configuration: [String]) -> String {
        let values = try? cube.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        return cube.path + "|\(modified)|\(values?.fileSize ?? 0)|" + configuration.joined(separator: "|")
    }

    private func storeCached(_ table: PreviewLookup, image: CGImage, key: String) {
        lookupCache[key] = table; resultCache[key] = image
        cacheOrder.removeAll { $0 == key }; cacheOrder.append(key)
        // Eight selected looks plus a few recently inspected alternatives.
        while cacheOrder.count > 12 {
            let oldest = cacheOrder.removeFirst()
            lookupCache.removeValue(forKey: oldest); resultCache.removeValue(forKey: oldest)
        }
    }

    func render() {
        token.cancel(); token = PhotoPreviewCancellation()
        let current = token
        error = nil; after = nil
        guard let photo = photoURL else {
            comparisonItems = comparisonMode == "compare" ? selectedLookURLs.map { CubeComparisonItem(url: $0) } : []
            isRendering = false; status = "先导入一张照片，再选择 CUBE 或 PF3。"; return
        }
        if pf3URL != nil {
            renderPF3(photo: photo, cancellation: current)
            return
        }
        updateProfileDescription()
        let grid = comparisonMode == "compare"
        let cubes = grid ? selectedCubeURLs : cubeURL.map { [$0] } ?? []
        let tasks = cubes.map { cube -> (url: URL, config: [String], key: String) in
            let config = effectiveConfiguration(for: cube)
            return (cube, config, Self.cacheKey(cube: cube, configuration: config))
        }
        let cachedPhoto = decoded, cachedTables = lookupCache, cachedResults = resultCache
        comparisonItems = grid ? tasks.map {
            CubeComparisonItem(url: $0.url, image: cachedResults[$0.key], isRendering: cachedResults[$0.key] == nil)
        } : []
        if let active = tasks.first(where: { $0.url == cubeURL }) { after = cachedResults[active.key] }
        isRendering = true
        status = cachedPhoto == nil ? "正在读取照片…" : grid ? "正在生成多图对比…" : "正在生成套用后预览…"
        let resources = resourcesURL
        queue.async {
            do {
                let source = try cachedPhoto ?? PhotoPreviewRenderer.decode(photo, cancellation: current)
                try current.check()
                DispatchQueue.main.async {
                    guard self.token === current else { return }
                    self.decoded = source; self.before = source.image
                    self.status = cubes.isEmpty ? "照片已读取，请选择 CUBE 或 PF3。" : "正在应用 CUBE LUT…"
                }
                var completed = 0, failed = 0
                for task in tasks {
                    try current.check()
                    do {
                        let table: PreviewLookup
                        if let cached = cachedTables[task.key] { table = cached }
                        else {
                            guard let resources = resources else { throw PhotoPreviewError.message("预览运行环境缺失，请重新构建应用。") }
                            table = try Self.prepareLookup(cube: task.url, configuration: task.config,
                                                           resources: resources, cancellation: current)
                        }
                        let output = try cachedResults[task.key] ?? PhotoPreviewRenderer.apply(table, to: source, cancellation: current)
                        try current.check()
                        completed += 1
                        let count = completed + failed
                        DispatchQueue.main.async {
                            guard self.token === current else { return }
                            self.storeCached(table, image: output, key: task.key)
                            if let index = self.comparisonItems.firstIndex(where: { $0.url == task.url }) {
                                self.comparisonItems[index] = CubeComparisonItem(url: task.url, image: output)
                            }
                            if self.cubeURL == task.url { self.after = output }
                            self.status = grid ? "已完成 \(count)/\(tasks.count) 个 CUBE · \(task.url.lastPathComponent)" : "预览已生成"
                        }
                    } catch {
                        try current.check()
                        failed += 1
                        let message = error.localizedDescription
                        DispatchQueue.main.async {
                            guard self.token === current else { return }
                            if grid, let index = self.comparisonItems.firstIndex(where: { $0.url == task.url }) {
                                self.comparisonItems[index] = CubeComparisonItem(url: task.url, error: message)
                            } else { self.error = message }
                        }
                    }
                }
                try current.check()
                let succeeded = completed, failures = failed
                DispatchQueue.main.async {
                    guard self.token === current else { return }
                    self.isRendering = false
                    if tasks.isEmpty { self.status = grid ? "勾选文件夹中的 CUBE，最多 8 个 CUBE，加上 1 张原图。" : "照片已读取，请选择 CUBE 或 PF3。" }
                    else if grid { self.status = "\(succeeded)/\(tasks.count) 个效果已完成\(failures == 0 ? "" : " · \(failures) 个失败，可单独取消选择") · 点击结果选择导出 · 原文件保持不变" }
                    else { self.status = failures == 0 ? "\(source.isRaw ? "RAW 已显影" : "照片已读取") · \(source.width) × \(source.height) 预览 · 原文件保持不变" : "未能生成预览。" }
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.token === current else { return }
                    self.isRendering = false
                    if current.isCancelled { return }
                    self.comparisonItems = self.comparisonItems.map { CubeComparisonItem(url: $0.url, error: error.localizedDescription) }
                    self.error = error.localizedDescription; self.status = "未能读取照片。"
                }
            }
        }
    }

    private func pf3CacheKey(pf3: URL, photo: URL) -> String {
        "pf3-photo-v2|" + Self.cacheKey(cube: photo, configuration: []) + "|" +
            Self.cacheKey(cube: pf3, configuration: []) + "|" +
            (helperURL.map { Self.cacheKey(cube: $0, configuration: []) } ?? "injected-renderer")
    }

    private func storePF3Cached(_ output: PF3PreviewOutput, key: String) {
        pf3Cache[key] = output
        pf3CacheOrder.removeAll { $0 == key }; pf3CacheOrder.append(key)
        while pf3CacheOrder.count > 12 {
            pf3Cache.removeValue(forKey: pf3CacheOrder.removeFirst())
        }
    }

    private func renderPF3(photo: URL, cancellation current: PhotoPreviewCancellation) {
        let grid = comparisonMode == "compare"
        let urls = grid ? selectedPF3URLs : pf3URL.map { [$0] } ?? []
        let tasks = urls.map { (url: $0, key: pf3CacheKey(pf3: $0, photo: photo)) }
        let cached = pf3Cache, resources = resourcesURL, helper = helperURL, renderer = pf3PreviewRenderer
        pf3ReferenceMode = nil; isRendering = true; before = nil
        comparisonItems = grid ? urls.map { CubeComparisonItem(url: $0, isRendering: true) } : []
        status = grid && urls.count > 1 ? "正在逐项生成 PF3 多图预览…" : "正在读取 PF3 并生成预览…"
        queue.async {
            var reference: PF3PreviewOutput?, completed = 0, failed = 0
            for task in tasks {
                do {
                    try current.check()
                    let output: PF3PreviewOutput
                    if let value = cached[task.key] { output = value }
                    else if let renderer = renderer { output = try renderer(task.url, photo, current) }
                    else {
                        guard let resources = resources, let helper = helper else {
                            throw PhotoPreviewError.message("应用缺少 PF3 预览运行环境，请重新安装或构建当前版本。")
                        }
                        output = try Self.preparePF3(pf3: task.url, photo: photo, resources: resources,
                                                     helper: helper, cancellation: current)
                    }
                    try current.check()
                    DispatchQueue.main.async {
                        guard self.token === current else { return }
                        self.storePF3Cached(output, key: task.key)
                    }
                    if let reference = reference, reference.mode != output.mode {
                        throw PhotoPreviewError.message("显影基准不同，请单独查看。原生 PF3 与内嵌色表 PF3 不能共用同一张原图比较。")
                    }
                    if reference == nil { reference = output }
                    let currentReference = reference!
                    completed += 1
                    let count = completed + failed
                    DispatchQueue.main.async {
                        guard self.token === current else { return }
                        self.pf3ReferenceMode = currentReference.mode
                        self.before = currentReference.before
                        if let index = self.comparisonItems.firstIndex(where: { $0.url == task.url }) {
                            self.comparisonItems[index] = CubeComparisonItem(url: task.url, image: output.after)
                        }
                        if self.pf3URL == task.url { self.after = output.after }
                        self.setPF3Labels(currentReference)
                        self.status = grid ? "已完成 \(count)/\(tasks.count) 个 PF3 · \(task.url.lastPathComponent)" : "\(output.label) · \(output.before.width) × \(output.before.height) · \(output.isRaw ? "RAW" : "照片") · 非机内实拍"
                    }
                } catch {
                    if current.isCancelled { return }
                    failed += 1
                    let message = error.localizedDescription
                    DispatchQueue.main.async {
                        guard self.token === current else { return }
                        if let index = self.comparisonItems.firstIndex(where: { $0.url == task.url }) {
                            self.comparisonItems[index] = CubeComparisonItem(url: task.url, error: message)
                        } else { self.error = message }
                    }
                }
            }
            guard !current.isCancelled else { return }
            let successes = completed, failures = failed
            DispatchQueue.main.async {
                guard self.token === current else { return }
                self.isRendering = false
                if grid {
                    self.status = "\(successes)/\(tasks.count) 个 PF3 效果已完成\(failures == 0 ? "" : " · \(failures) 个失败，可单独查看") · 点击结果选择导出 · 非机内实拍"
                } else if failures > 0 { self.status = "未能生成 PF3 预览。" }
            }
        }
    }

    private static func preparePF3(pf3: URL, photo: URL, resources: URL, helper: URL,
                                   cancellation: PhotoPreviewCancellation) throws -> PF3PreviewOutput {
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
            return PF3PreviewOutput(before: decoded.image, after: after, isRaw: decoded.isRaw, mode: mode, label: "PF3 内嵌色表 · 照片近似")
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
        return PF3PreviewOutput(before: before, after: after, isRaw: isRaw, mode: mode, label: "Canon 原生 PF3 离线显影")
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
