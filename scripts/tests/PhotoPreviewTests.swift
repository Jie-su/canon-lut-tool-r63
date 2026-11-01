import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

@main struct PhotoPreviewTests {
    private static var checks = 0
    private static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw TestFailure(description: message) }
        checks += 1
    }
    private static func wait(_ message: String, until condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(90)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        try expect(condition(), "Timed out: " + message)
    }
    private static func cube(_ url: URL, transform: (Double, Double, Double) -> [Double]) throws {
        var lines = ["LUT_3D_SIZE 2", "DOMAIN_MIN 0 0 0", "DOMAIN_MAX 1 1 1"]
        for b in 0...1 { for g in 0...1 { for r in 0...1 {
            lines.append(transform(Double(r), Double(g), Double(b)).map { String($0) }.joined(separator: " "))
        } } }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
    private static func photo(_ url: URL, rgb: [UInt8]) throws {
        let image = try PhotoPreviewRenderer.cgImage(pixels: Array(repeating: rgb + [255], count: 64).flatMap { $0 }, width: 8, height: 8)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw TestFailure(description: "Could not create test PNG")
        }
        CGImageDestinationAddImage(destination, image, nil)
        try expect(CGImageDestinationFinalize(destination), "PNG finalization")
    }
    private static func pixel(_ image: CGImage?) throws -> [UInt8] {
        guard let image = image else { throw TestFailure(description: "Missing rendered image") }
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let bitmap = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: PhotoPreviewRenderer.colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw TestFailure(description: "Could not inspect rendered pixels")
        }
        bitmap.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(bytes.prefix(3))
    }

    private static func testPreviewZoomState() throws {
        let model = PhotoPreviewModel(resourcesURL: nil)
        let centre = CGPoint(x: 0.5, y: 0.5)
        let inspection = CGPoint(x: 0.8, y: 0.2)
        try expect(model.previewZoomPercent == 0 && model.previewZoomCenter == centre,
                   "Preview zoom initially fits the whole photo")
        model.togglePreviewZoom(at: inspection)
        try expect(model.previewZoomPercent == 200 && model.previewZoomCenter == inspection,
                   "Clicking an image initially uses 200 percent at the requested image point")
        model.togglePreviewZoom(at: CGPoint(x: 0.1, y: 0.9))
        try expect(model.previewZoomPercent == 0 && model.previewZoomCenter == inspection,
                   "Clicking a magnified photo returns to fit without losing the inspection point")
        for percent in [100, 150, 200, 0] {
            model.setPreviewZoomPercent(percent)
            try expect(model.previewZoomPercent == percent && model.previewZoomCenter == inspection,
                       "Changing the magnification must preserve the shared inspection point")
        }
        model.setPreviewZoomPercent(150)
        model.setPreviewZoomPercent(0)
        let secondPoint = CGPoint(x: 0.3, y: 0.75)
        model.togglePreviewZoom(at: secondPoint)
        try expect(model.previewZoomPercent == 150 && model.previewZoomCenter == secondPoint,
                   "The next image click reuses the selected manual magnification")
        for percent in [-1, 1, 99, 125, 201, Int.max] { model.setPreviewZoomPercent(percent) }
        model.togglePreviewZoom(at: CGPoint(x: CGFloat.nan, y: 0.2))
        model.togglePreviewZoom(at: CGPoint(x: 0.2, y: CGFloat.infinity))
        try expect(model.previewZoomPercent == 150 && model.previewZoomCenter == secondPoint,
                   "Invalid magnifications or non-finite image points cannot corrupt the shared view")
        model.setPreviewZoomPercent(0)
        model.togglePreviewZoom(at: CGPoint(x: -0.25, y: 1.25))
        try expect(model.previewZoomCenter == CGPoint(x: 0, y: 1) && model.previewZoomPercent == 150,
                   "Normalized image points remain within the image extent")
        model.resetPreviewZoom()
        try expect(model.previewZoomPercent == 0 && model.previewZoomCenter == centre,
                   "Reset restores the centred complete-photo view")
        model.togglePreviewZoom(at: inspection)
        try expect(model.previewZoomPercent == 150 && model.previewZoomCenter == inspection,
                   "Reset keeps the user's chosen manual magnification for the next click")
    }

    // An injected renderer exercises asynchronous selection/cache orchestration
    // without redistributing a real PF3 or requiring Canon software in CI.
    private static func testPF3Comparisons(in temporary: URL) throws {
        let manager = FileManager.default
        let folder = temporary.appendingPathComponent("PF3-batch")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let urls = (1...10).map { folder.appendingPathComponent("native\($0).pf3").standardizedFileURL }
        for url in urls { try "synthetic renderer fixture".write(to: url, atomically: true, encoding: .utf8) }
        let firstPhoto = temporary.appendingPathComponent("pf3-first.png")
        let secondPhoto = temporary.appendingPathComponent("pf3-second.png")
        try photo(firstPhoto, rgb: [30, 70, 110]); try photo(secondPhoto, rgb: [140, 160, 180])
        let lock = NSLock()
        var invocations: [URL: Int] = [:]
        func calls() -> Int { lock.lock(); defer { lock.unlock() }; return invocations.values.reduce(0, +) }
        let model = PhotoPreviewModel(resourcesURL: nil, pf3PreviewRenderer: { pf3, photo, cancellation in
            lock.lock(); invocations[pf3, default: 0] += 1; lock.unlock()
            try cancellation.check()
            if pf3.lastPathComponent == "broken.pf3" { throw PhotoPreviewError.message("synthetic PF3 failure") }
            if pf3.lastPathComponent == "slow.pf3" {
                for _ in 0..<20 { Thread.sleep(forTimeInterval: 0.005); try cancellation.check() }
            }
            let source = try PhotoPreviewRenderer.decode(photo, cancellation: cancellation)
            let n = Int(pf3.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "native", with: "")) ?? 7
            let color: [UInt8] = [UInt8(n * 15), 25, source.pixels[2]]
            let image = try PhotoPreviewRenderer.cgImage(pixels: Array(repeating: color + [255], count: 64).flatMap { $0 }, width: 8, height: 8)
            let mode = pf3.lastPathComponent == "embedded.pf3" ? "embedded-lut" : "native"
            return PF3PreviewOutput(before: source.image, after: image, isRaw: false, mode: mode, label: "PF3 test " + mode)
        })
        model.loadCubeFolder(folder)
        try wait("PF3 batch folder") { !model.isScanningFolder }
        try expect(model.selectedPF3URLs == [urls[0]] && model.selectedLookURLs == [urls[0]], "PF3 folder selects a comparable first item")
        for url in urls[1..<8] { model.toggleComparisonLook(url) }
        try expect(model.selectedPF3URLs == Array(urls.prefix(8)) && model.comparisonItems.count == 8, "PF3 checkboxes select eight effects plus original before importing a photo")
        model.toggleComparisonLook(urls[8])
        try expect(model.selectedPF3URLs.count == 8 && model.folderError != nil, "Reject ninth PF3 without changing selection")
        model.loadPhoto(firstPhoto)
        try wait("eight synthetic PF3 renders") { !model.isRendering }
        try expect(model.comparisonItems.count == 8 && model.comparisonItems.allSatisfy { $0.image != nil && $0.error == nil && !$0.isRendering }, "All eight PF3 items render independently")
        try expect(pixel(model.before) == [30, 70, 110] && model.previewMethod == "native", "PF3 batch keeps the first successful common original and method")
        let renderedCalls = calls(), firstBefore = model.before
        let inspectionPoint = CGPoint(x: 0.78, y: 0.23)
        model.togglePreviewZoom(at: inspectionPoint)
        model.setPreviewZoomPercent(150)
        try expect(!model.isRendering && calls() == renderedCalls,
                   "Inspecting the photo changes only view state and does not render any PF3 again")
        model.focusComparisonLook(urls[3])
        try expect(model.pf3URL == urls[3] && pixel(model.after) == [60, 25, 110] && model.before === firstBefore && calls() == renderedCalls,
                   "Focusing a cached PF3 changes export target without rendering or changing the shared original")
        model.toggleComparisonLook(urls[7])
        try wait("remove PF3") { !model.isRendering }
        try expect(model.comparisonItems.count == 7 && calls() == renderedCalls, "Removing a PF3 reuses completed pairs")
        model.comparisonMode = "split"
        try wait("PF3 slide") { !model.isRendering }
        try expect(model.selectedPF3URLs.count == 7 && pixel(model.after) == [60, 25, 110], "PF3 slide preserves all selections and displays the active effect")
        model.comparisonMode = "compare"
        try wait("PF3 grid restore") { !model.isRendering }
        try expect(model.comparisonItems.count == 7 && calls() == renderedCalls, "PF3 grid restore uses cached pairs")
        try expect(model.previewZoomPercent == 150 && model.previewZoomCenter == inspectionPoint,
                   "Focusing, removing PF3s and switching comparison modes preserve shared zoom and image position")
        let embedded = folder.appendingPathComponent("embedded.pf3").standardizedFileURL
        let broken = folder.appendingPathComponent("broken.pf3").standardizedFileURL
        let slow = folder.appendingPathComponent("slow.pf3").standardizedFileURL
        for url in [embedded, broken, slow] { try "synthetic renderer fixture".write(to: url, atomically: true, encoding: .utf8) }
        model.refreshCubeFolder()
        try wait("PF3 refresh preserves selections") { !model.isScanningFolder && !model.isRendering }
        try expect(model.selectedPF3URLs.count == 7 && model.pf3URL == urls[3], "Folder refresh preserves PF3 multi-selection and active export target")
        try expect(model.previewZoomPercent == 150 && model.previewZoomCenter == inspectionPoint,
                   "Refreshing the PF3 folder must not reset photo inspection")
        model.toggleComparisonLook(embedded)
        try wait("mixed PF3 references") { !model.isRendering }
        try expect(model.comparisonItems.filter { $0.image != nil }.count == 7 && model.comparisonItems.first { $0.url == embedded }?.error?.contains("显影基准不同") == true,
                   "A PF3 using another development reference is isolated instead of showing against the wrong original")
        model.focusComparisonLook(embedded)
        try expect(model.after == nil && model.before === firstBefore && model.previewMethod == "native", "Focusing an incompatible cached PF3 must not enable export or replace the batch reference")
        model.comparisonMode = "split"
        try wait("incompatible PF3 alone in slide") { !model.isRendering }
        try expect(model.after != nil && model.previewMethod == "embedded-lut" && model.selectedPF3URLs.count == 8, "Slide can inspect active PF3 with its own accurate reference")
        model.comparisonMode = "compare"
        try wait("mixed PF3 reference revalidation") { !model.isRendering }
        try expect(model.after == nil && model.previewMethod == "native" && model.comparisonItems.first { $0.url == embedded }?.image == nil,
                   "Returning to comparison revalidates cached references before exposing results")
        model.configurePF3(url: embedded)
        try wait("PF3 view alone") { !model.isRendering }
        try expect(model.selectedPF3URLs == [embedded] && model.comparisonItems.count == 1 && model.after != nil && model.previewMethod == "embedded-lut", "View alone starts a correct independent one-item group")
        try expect(model.previewZoomPercent == 150 && model.previewZoomCenter == inspectionPoint,
                   "Switching to another PF3 preserves the selected photo location and magnification")
        model.configurePF3(url: broken)
        model.toggleComparisonLook(urls[1])
        try wait("broken first PF3") { !model.isRendering }
        try expect(model.comparisonItems.first?.error != nil && model.comparisonItems.last?.image != nil && model.previewMethod == "native", "First successful PF3 establishes reference even if the first selected file fails")
        model.focusComparisonLook(urls[1])
        try expect(pixel(model.after) == [30, 25, 110], "A valid PF3 remains available after a neighboring failure")
        model.configurePF3(url: urls[0])
        try wait("PF3 before edit") { !model.isRendering }
        let beforeEdit = calls()
        try "edited synthetic renderer fixture with different size".write(to: urls[0], atomically: true, encoding: .utf8)
        model.render()
        try wait("PF3 edited cache invalidation") { !model.isRendering }
        try expect(calls() == beforeEdit + 1, "PF3 content identity change invalidates its rendered pair")
        model.loadPhoto(secondPhoto)
        try wait("PF3 new source") { !model.isRendering }
        try expect(pixel(model.before) == [140, 160, 180] && pixel(model.after) == [15, 25, 180], "New photos invalidate PF3 result and original caches")
        try expect(model.previewZoomPercent == 0 && model.previewZoomCenter == CGPoint(x: 0.5, y: 0.5),
                   "A new photo restores the whole-photo view rather than keeping the previous crop")
        model.togglePreviewZoom(at: inspectionPoint)
        model.setPreviewZoomPercent(200)
        model.loadPhoto(secondPhoto)
        try wait("PF3 same source reimport") { !model.isRendering }
        try expect(model.previewZoomPercent == 0 && model.previewZoomCenter == CGPoint(x: 0.5, y: 0.5),
                   "Explicitly reimporting the same photo also resets shared inspection")
        model.configurePF3(url: slow)
        model.cancel()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        try expect(!model.isRendering && model.comparisonItems.allSatisfy { !$0.isRendering } && model.after == nil, "Cancelled PF3 work cannot publish stale results")
        model.configurePF3(url: urls[0])
        model.loadPhoto(firstPhoto); model.loadPhoto(secondPhoto)
        try wait("PF3 rapid photo replacement") { !model.isRendering }
        try expect(pixel(model.before) == [140, 160, 180] && pixel(model.after) == [15, 25, 180], "Late PF3 work cannot overwrite a newer photo")
        model.clearComparisonSelection()
        try wait("PF3 clear original") { !model.isRendering }
        try expect(model.selectedLookURLs.isEmpty && model.pf3URL == nil && model.comparisonItems.isEmpty && model.after == nil && model.previewMethod == "cube", "Clear removes the PF3 group and export target and resets the original label")
        model.configurePF3(url: urls[0])
        try wait("PF3 before removal refresh") { !model.isRendering }
        model.toggleComparisonLook(urls[1])
        try wait("PF3 before active removal") { !model.isRendering }
        try manager.removeItem(at: urls[0])
        model.refreshCubeFolder()
        try wait("PF3 active removed refresh") { !model.isScanningFolder && !model.isRendering }
        try expect(model.selectedPF3URLs == [urls[1]] && model.pf3URL == urls[1] && pixel(model.after) == [30, 25, 180], "Refresh removes a deleted active PF3 and retains a valid selected result")
        let cubeURL = folder.appendingPathComponent("new.cube").standardizedFileURL
        try cube(cubeURL) { [$0, $1, $2] }
        model.refreshCubeFolder()
        try wait("mixed folder for family switch") { !model.isScanningFolder && !model.isRendering }
        model.togglePreviewZoom(at: inspectionPoint)
        model.setPreviewZoomPercent(100)
        model.toggleComparisonLook(cubeURL)
        try wait("switch PF3 group to CUBE") { !model.isRendering }
        try expect(model.selectedPF3URLs.isEmpty && model.selectedCubeURLs == [cubeURL] && model.lookKind == "CUBE", "CUBE selection starts its own group")
        model.toggleComparisonLook(urls[1])
        try wait("switch CUBE group to PF3") { !model.isRendering }
        try expect(model.selectedCubeURLs.isEmpty && model.selectedPF3URLs == [urls[1]] && model.lookKind == "PF3", "PF3 selection starts its own group")
        try expect(model.previewZoomPercent == 100 && model.previewZoomCenter == inspectionPoint,
                   "Changing between CUBE and PF3 groups retains inspection of the same photo")
        model.clearComparisonSelection()
        try wait("clear while inspecting") { !model.isRendering }
        try expect(model.previewZoomPercent == 100 && model.previewZoomCenter == inspectionPoint,
                   "Clearing only the preset group preserves the photo view")
    }

    static func main() throws {
        try testPreviewZoomState()
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appendingPathComponent("CanonPreviewTests-" + UUID().uuidString)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: temporary) }
        let folder = temporary.resolvingSymlinksInPath().appendingPathComponent("Library")
        try manager.createDirectory(at: folder.appendingPathComponent("nested"), withIntermediateDirectories: true)
        let hidden = folder.appendingPathComponent(".private")
        try manager.createDirectory(at: hidden, withIntermediateDirectories: true)
        try cube(hidden.appendingPathComponent("hidden.cube")) { [$0, $1, $2] }
        for i in 1...10 {
            let name = i == 2 ? "look2.CUBE" : "look\(i).cube"
            try cube(folder.appendingPathComponent(name)) { [$0, $1, $2] }
        }
        let swap = folder.appendingPathComponent("nested/swap.cube").standardizedFileURL
        try cube(swap) { [$2, $1, $0] }
        try "ignored".write(to: folder.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try manager.createDirectory(at: folder.appendingPathComponent("directory.cube"), withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: folder.appendingPathComponent("linked.cube"), withDestinationURL: swap)
        try manager.createSymbolicLink(at: folder.appendingPathComponent("linked-directory"), withDestinationURL: hidden)
        let entries = try CubeFolderScanner.entries(in: folder, cancellation: PhotoPreviewCancellation())
        try expect(entries.count == 11, "Scan must include 11 regular CUBEs only; got \(entries.map(\.relativePath))")
        try expect(entries.prefix(3).map(\.name) == ["look1", "look2", "look3"], "Natural order and uppercase CUBE")
        try expect(entries.last?.relativePath == "nested/swap.cube", "Relative nested path: \(entries.map(\.relativePath))")
        let nativePF3 = folder.appendingPathComponent("native.PF3").standardizedFileURL
        let nestedPF3 = folder.appendingPathComponent("nested/portrait.pf3").standardizedFileURL
        try "folder-only test fixture".write(to: nativePF3, atomically: true, encoding: .utf8)
        try "folder-only test fixture".write(to: nestedPF3, atomically: true, encoding: .utf8)
        try manager.createSymbolicLink(at: folder.appendingPathComponent("linked.pf3"), withDestinationURL: nativePF3)
        try manager.createDirectory(at: folder.appendingPathComponent("directory.pf3"), withIntermediateDirectories: true)
        let libraryEntries = try CubeFolderScanner.entries(in: folder, cancellation: PhotoPreviewCancellation())
        try expect(libraryEntries.count == 13 && Set(libraryEntries.map(\.url)).count == 13, "Mixed folder includes each regular CUBE/PF3 exactly once")
        try expect(libraryEntries.filter(\.isPF3).map(\.format) == ["PF3", "PF3"], "PF3 detection includes uppercase extension")
        try expect(libraryEntries.filter { !$0.isPF3 }.allSatisfy { $0.format == "CUBE" }, "CUBE format badges remain distinct")
        let stopped = PhotoPreviewCancellation(); stopped.cancel()
        do {
            _ = try CubeFolderScanner.entries(in: folder, cancellation: stopped)
            throw TestFailure(description: "Cancelled scan unexpectedly succeeded")
        } catch PhotoPreviewError.cancelled { checks += 1 }
        let resources = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1]) : nil
        let model = PhotoPreviewModel(resourcesURL: resources)
        model.loadCubeFolder(folder)
        try wait("folder scan") { !model.isScanningFolder }
        try expect(model.folderEntries.count == 13 && model.cubeURL == entries[0].url, "Mixed import selects first natural-order preset")
        model.folderSearch = "SWAP"
        try expect(model.filteredFolderEntries.count == 1, "Case-insensitive relative-path search")
        model.folderSearch = "nested/"
        try expect(model.filteredFolderEntries.count == 2, "Subdirectory search includes CUBE and PF3")
        model.folderSearch = ".PF3"
        try expect(model.filteredFolderEntries.count == 2 && model.filteredFolderEntries.allSatisfy(\.isPF3), "Search can filter PF3 by extension")
        model.folderSearch = ""
        model.configure(cubeURL: model.cubeURL, adaptation: "clog3", logGamut: "cinema-gamut", lutOutput: "gamma24")
        try expect(model.usesFolderSRGB && model.profileDescription.contains("sRGB 直接套用"), "Folder defaults must override prior Log choice")
        model.folderUsesSRGB = false
        try expect(!model.usesFolderSRGB && model.profileDescription.contains("C-Log 3"), "Folder can explicitly opt back into Log settings")
        model.folderUsesSRGB = true
        model.comparisonMode = "compare"
        for entry in entries[1..<8] { model.toggleComparisonCube(entry.url) }
        try expect(model.selectedCubeURLs.count == 8 && Set(model.selectedCubeURLs).count == 8, "Select eight unique CUBEs plus the original")
        model.showFolderCube(entries[8].url)
        try expect(model.selectedCubeURLs.count == 8 && !model.selectedCubeURLs.contains(entries[8].url) && model.folderError != nil, "Reject ninth LUT result without replacing selection")
        model.toggleComparisonCube(entries[8].url)
        try expect(model.selectedCubeURLs.count == 8 && model.folderError != nil, "Checkbox also rejects ninth LUT result")
        model.toggleComparisonCube(entries[7].url)
        model.toggleComparisonCube(entries[8].url)
        try expect(model.selectedCubeURLs.count == 8 && model.selectedCubeURLs.last == entries[8].url, "Remove frees exactly one slot")
        model.focusComparisonCube(entries[0].url)
        try expect(model.cubeURL == entries[0].url, "Focus selected export target")
        model.clearComparisonSelection()
        try expect(model.selectedCubeURLs.isEmpty && model.comparisonItems.isEmpty && model.after == nil, "Clear removes all results")
        model.showFolderCube(swap)
        try expect(model.selectedCubeURLs == [swap], "Click in empty comparison adds result")
        model.comparisonMode = "compare"
        model.showFolderCube(entries[0].url)
        try expect(model.selectedCubeURLs == [entries[0].url] && model.cubeURL == entries[0].url, "Click with one selected LUT replaces the current look")
        model.configurePF3(url: temporary.appendingPathComponent("test.pf3"))
        model.comparisonMode = "compare"
        try expect(model.comparisonMode == "compare" && model.selectedCubeURLs.isEmpty, "PF3 remains one preset plus its original in adaptive compare")
        model.showFolderCube(entries[0].url)
        try expect(!model.isPF3Preview && model.usesFolderSRGB, "Folder click returns from PF3 to sRGB CUBE")
        model.configurePF3(url: temporary.appendingPathComponent("test.pf3"))
        model.toggleComparisonCube(entries[0].url)
        try expect(!model.isPF3Preview && model.previewMethod == "cube" && model.previewMethodSummary.contains("CUBE"), "PF3 checkbox transition must reset route labels")
        model.showFolderCube(nativePF3)
        try expect(model.pf3URL == nativePF3 && model.cubeURL == nil && model.selectedCubeURLs.isEmpty, "Folder PF3 click uses independent PF3 renderer and clears CUBE grid")
        try expect(model.previewMethod == "pending-pf3" && model.profileDescription.contains("PF3"), "Folder PF3 route uses PF3 labels")
        model.configure(cubeURL: nil, adaptation: "clog2", logGamut: "cinema-gamut", lutOutput: "gamma24")
        model.folderUsesSRGB = false
        try expect(model.pf3URL == nativePF3 && !model.usesFolderSRGB && !model.profileDescription.contains("C-Log 2"), "Folder color switches must not apply Log to PF3")
        model.toggleComparisonCube(nativePF3)
        try expect(model.pf3URL == nativePF3 && model.selectedCubeURLs.isEmpty, "PF3 cannot enter a CUBE grid with a different original reference")
        model.refreshCubeFolder()
        try wait("refresh active PF3") { !model.isScanningFolder }
        try expect(model.pf3URL == nativePF3 && model.cubeURL == nil, "Refresh preserves existing active PF3")
        model.folderUsesSRGB = true
        model.showFolderCube(entries[0].url)
        try expect(!model.isPF3Preview && model.cubeURL == entries[0].url && model.usesFolderSRGB, "Clicking CUBE after folder PF3 restores sRGB CUBE preview")
        let pf3Only = temporary.appendingPathComponent("PF3-only")
        try manager.createDirectory(at: pf3Only, withIntermediateDirectories: true)
        let onlyPF3 = pf3Only.appendingPathComponent("first.PF3").standardizedFileURL
        try "folder-only test fixture".write(to: onlyPF3, atomically: true, encoding: .utf8)
        let pf3Model = PhotoPreviewModel(resourcesURL: resources)
        pf3Model.loadCubeFolder(pf3Only)
        try wait("PF3-only folder") { !pf3Model.isScanningFolder }
        try expect(pf3Model.folderEntries.count == 1 && pf3Model.pf3URL == onlyPF3 && pf3Model.cubeURL == nil, "PF3-only folder automatically selects its first preset")
        try manager.removeItem(at: onlyPF3)
        pf3Model.refreshCubeFolder()
        try wait("removed PF3 refresh") { !pf3Model.isScanningFolder }
        try expect(pf3Model.folderEntries.isEmpty && pf3Model.lookURL == nil && pf3Model.after == nil && pf3Model.error == nil, "Removing active PF3 clears the selection and stale image on refresh")
        let external = temporary.appendingPathComponent("external.cube")
        try cube(external) { [$0, $1, $2] }
        model.configure(cubeURL: external, adaptation: "clog3", logGamut: "cinema-gamut", lutOutput: "gamma24")
        model.comparisonMode = "compare"
        model.toggleComparisonCube(external)
        try expect(model.selectedCubeURLs.isEmpty, "Standalone CUBE must be removable from grid")
        model.loadCubeFolder(temporary.appendingPathComponent("missing-folder"))
        try wait("failed folder import") { !model.isScanningFolder }
        try expect(model.folderURL?.path == folder.path && model.folderEntries.count == 13 && model.folderError != nil, "Failed scan must retain matching folder title and old library")
        model.comparisonMode = "compare"
        model.showFolderCube(entries[0].url)
        if resources != nil {
            let firstPhoto = temporary.appendingPathComponent("first.png")
            let secondPhoto = temporary.appendingPathComponent("second.png")
            try photo(firstPhoto, rgb: [40, 90, 210]); try photo(secondPhoto, rgb: [180, 60, 20])
            model.loadPhoto(firstPhoto)
            try wait("single sRGB render") { !model.isRendering }
            try expect(model.error == nil && pixel(model.after) == [40, 90, 210], "sRGB identity must preserve display code values despite saved Log configuration")
            model.comparisonMode = "compare"
            for entry in entries[1..<7] { model.toggleComparisonCube(entry.url) }
            model.toggleComparisonCube(swap)
            try wait("eight real renders plus original") { !model.isRendering }
            try expect(model.comparisonItems.count == 8 && model.comparisonItems.allSatisfy { $0.image != nil && $0.error == nil && !$0.isRendering }, "All eight LUT results must render alongside the original")
            try expect(pixel(model.comparisonItems.first { $0.url == swap }?.image) == [210, 90, 40], "Red-blue swap must render correctly")
            model.focusComparisonCube(swap)
            try expect(pixel(model.after) == [210, 90, 40], "Active export image must match focused grid tile")
            let completeSelection = model.selectedCubeURLs
            let originalPixels = try pixel(model.before)
            for target in [5, 3, 2] {
                while model.selectedCubeURLs.count > target { model.toggleComparisonCube(model.selectedCubeURLs.last!) }
                try wait("remove down to \(target) effects") { !model.isRendering }
                try expect(model.comparisonItems.count == target && model.comparisonItems.map(\.url) == model.selectedCubeURLs, "Removed effects must disappear without placeholder items")
                try expect(model.comparisonItems.allSatisfy { $0.image != nil } && pixel(model.before) == originalPixels, "Remaining effects and fixed original must stay available")
            }
            let retainedSelection = model.selectedCubeURLs
            model.comparisonMode = "split"
            try wait("switch to slide comparison") { !model.isRendering }
            try expect(model.selectedCubeURLs == retainedSelection && model.after != nil, "Slide mode preserves multi-selection and renders the active effect")
            model.comparisonMode = "compare"
            try wait("restore adaptive comparison") { !model.isRendering }
            try expect(model.selectedCubeURLs == retainedSelection && model.comparisonItems.count == retainedSelection.count, "Adaptive mode restores every selected effect")
            for url in completeSelection where !model.selectedCubeURLs.contains(url) { model.toggleComparisonCube(url) }
            model.focusComparisonCube(swap)
            try wait("restore all eight effects") { !model.isRendering }
            try expect(model.comparisonItems.count == 8 && model.before != nil, "Restore eight LUTs and keep original")
            // Folder input mode must refresh its tiles even while an outside CUBE is active.
            model.comparisonMode = "compare"
            model.configure(cubeURL: external, adaptation: "clog3", logGamut: "cinema-gamut", lutOutput: "gamma24")
            model.toggleComparisonCube(entries[0].url)
            try wait("mixed library grid") { !model.isRendering }
            try expect(model.cubeURL == external, "Outside CUBE remains active in mixed grid")
            model.folderUsesSRGB = false
            try expect(model.isRendering, "Folder mode change must refresh mixed grid")
            try wait("mixed grid Log refresh") { !model.isRendering }
            try expect(pixel(model.comparisonItems.first { $0.url == entries[0].url }?.image) != [40, 90, 210], "Folder mode change must replace stale sRGB results")
            model.folderUsesSRGB = true
            model.clearComparisonSelection()
            for entry in entries[0..<7] { model.toggleComparisonCube(entry.url) }
            model.toggleComparisonCube(swap)
            model.focusComparisonCube(swap)
            // A new source must invalidate cached results, including work still queued.
            model.loadPhoto(firstPhoto); model.loadPhoto(secondPhoto)
            try wait("rapid source replacement") { !model.isRendering }
            try expect(pixel(model.before) == [180, 60, 20] && pixel(model.after) == [20, 60, 180], "Stale source work must not overwrite the latest source")
            // File identity includes mtime and size; changing an already cached LUT must invalidate it.
            try cube(entries[0].url) { _, _, _ in [0.25, 0.5, 0.75] }
            model.render()
            try wait("edited LUT invalidates cache") { !model.isRendering }
            try expect(pixel(model.comparisonItems.first { $0.url == entries[0].url }?.image) == [64, 128, 191], "Changed CUBE must not reuse stale cached color table")
            // A malformed look must fail independently while the other seven remain usable.
            try "not a CUBE".write(to: entries[1].url, atomically: true, encoding: .utf8)
            model.render()
            try wait("isolated invalid CUBE") { !model.isRendering }
            try expect(model.comparisonItems.filter { $0.image != nil }.count == 7 && model.comparisonItems.filter { $0.error != nil }.count == 1, "One invalid CUBE must not fail the entire grid")
            model.render(); model.cancel()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            try expect(!model.isRendering && model.comparisonItems.allSatisfy { !$0.isRendering }, "Cancel must stop grid loading indicators")
        }
        try testPF3Comparisons(in: temporary)
        print("Photo preview regression checks passed: \(checks)\(resources == nil ? " (render checks require --resources)" : " (including real Python/Swift rendering)")")
    }
}
