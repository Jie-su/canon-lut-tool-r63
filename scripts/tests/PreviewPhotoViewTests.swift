import AppKit
import Foundation

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

@main struct PreviewPhotoViewTests {
    private static var checks = 0

    private static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw TestFailure(description: message) }
        checks += 1
    }

    private static func nearly(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.00001 }

    private static func markerImage(upperLeft: CGColor = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)) throws -> CGImage {
        // CGContext image coordinates: red at the lower-left, green at the
        // lower-right, blue at upper-left, yellow at upper-right.
        guard let context = CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8,
                                      bytesPerRow: 120 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw TestFailure(description: "Could not create marker bitmap")
        }
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        for (rect, color) in [(CGRect(x: 0, y: 0, width: 20, height: 20), CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)),
                              (CGRect(x: 100, y: 0, width: 20, height: 20), CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)),
                              (CGRect(x: 0, y: 60, width: 20, height: 20), upperLeft),
                              (CGRect(x: 100, y: 60, width: 20, height: 20), CGColor(srgbRed: 1, green: 1, blue: 0, alpha: 1))] {
            context.setFillColor(color); context.fill(rect)
        }
        guard let image = context.makeImage() else { throw TestFailure(description: "Could not create marker image") }
        return image
    }

    private static func solidImage(_ color: CGColor) throws -> CGImage {
        guard let context = CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8,
                                      bytesPerRow: 120 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw TestFailure(description: "Could not create split bitmap")
        }
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        guard let image = context.makeImage() else { throw TestFailure(description: "Could not create split image") }
        return image
    }

    private static func bitmap(_ view: BoundedPhotoNSView) throws -> NSBitmapImageRep {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw TestFailure(description: "Could not allocate offscreen view bitmap")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    private static func rgb(_ bitmap: NSBitmapImageRep, _ x: Int, _ y: Int) throws -> [CGFloat] {
        let pixelX = Int(CGFloat(x) * CGFloat(bitmap.pixelsWide) / bitmap.size.width)
        let pixelY = Int(CGFloat(y) * CGFloat(bitmap.pixelsHigh) / bitmap.size.height)
        guard let color = bitmap.colorAt(x: pixelX, y: pixelY)?.usingColorSpace(.sRGB) else {
            throw TestFailure(description: "Could not inspect rendered pixel")
        }
        return [color.redComponent, color.greenComponent, color.blueComponent]
    }

    private static func isColor(_ actual: [CGFloat], _ expected: [CGFloat]) -> Bool {
        // NSView caching uses the current display profile. Identify the marker
        // colour rather than testing the display's colour calibration.
        zip(actual, expected).allSatisfy { $1 > 0.5 ? $0 > 0.75 : $0 < 0.35 }
    }

    static func main() throws {
        _ = NSApplication.shared
        let image = try markerImage()
        let view = BoundedPhotoNSView(frame: CGRect(x: 0, y: 0, width: 180, height: 180))
        try expect(view.intrinsicContentSize.width == NSView.noIntrinsicMetric && view.intrinsicContentSize.height == NSView.noIntrinsicMetric,
                   "Image must not impose its pixel size on the layout")
        view.setPhoto(image, fillsPanels: false, commonFitSize: .zero)
        let complete = try bitmap(view)
        // Caching uses top-to-bottom bitmap rows. All four original corners
        // remain visible, and their orientation must be retained.
        try expect(isColor(try rgb(complete, 10, 40), [0, 0, 1]), "Complete mode lost/flipped upper-left corner")
        try expect(isColor(try rgb(complete, 170, 40), [1, 1, 0]), "Complete mode lost/flipped upper-right corner")
        try expect(isColor(try rgb(complete, 10, 140), [1, 0, 0]), "Complete mode lost/flipped lower-left corner")
        try expect(isColor(try rgb(complete, 170, 140), [0, 1, 0]), "Complete mode lost/flipped lower-right corner")

        view.setPhoto(image, fillsPanels: true, commonFitSize: .zero)
        let filled = try bitmap(view)
        // A landscape image filling a square crops its left/right outermost
        // corners instead of stretching the content or resizing the panel.
        try expect(isColor(try rgb(filled, 2, 2), [1, 1, 1]), "Fill should clip the corner markers")
        try expect(isColor(try rgb(filled, 177, 177), [1, 1, 1]), "Fill should cover the entire panel")
        try expect(view.frame.size == CGSize(width: 180, height: 180), "Fill changed the view frame")
        for point in [NSPoint(x: 90, y: 90), NSPoint(x: 90, y: 200), NSPoint(x: -100, y: 90)] {
            try expect(view.hitTest(point) == nil,
                       "A filled image must not intercept result selection or controls outside its viewport")
        }

        for panel in [CGSize(width: 480, height: 160), CGSize(width: 160, height: 480), CGSize(width: 341.4, height: 239.9)] {
            let bounds = CGRect(origin: .zero, size: panel)
            let fit = BoundedPhotoNSView.destinationRect(imageSize: CGSize(width: 120, height: 80), in: bounds,
                                                        fillsPanels: false, commonFitSize: CGSize(width: 10_000, height: 10_000))
            try expect(bounds.insetBy(dx: -0.00001, dy: -0.00001).contains(fit), "Even stale common sizing must fit actual panel bounds")
            try expect(nearly(fit.width / fit.height, 1.5), "Complete mode stretched the source")
            let fill = BoundedPhotoNSView.destinationRect(imageSize: CGSize(width: 120, height: 80), in: bounds, fillsPanels: true)
            try expect(fill.insetBy(dx: -0.00001, dy: -0.00001).contains(bounds), "Fill left a panel edge uncovered")
            try expect(nearly(fill.width / fill.height, 1.5), "Fill mode stretched the source")
        }
        let common = CGSize(width: 90, height: 60)
        for panel in [CGSize(width: 100, height: 100), CGSize(width: 300, height: 100)] {
            let rect = BoundedPhotoNSView.destinationRect(imageSize: CGSize(width: 120, height: 80), in: CGRect(origin: .zero, size: panel),
                                                         fillsPanels: false, commonFitSize: common)
            try expect(rect.size == common, "Unequal comparison panels must retain common photo scale")
        }

        let anchor = CGPoint(x: 0.25, y: 0.75)
        for factor: CGFloat in [1, 1.5, 2] { for backing: CGFloat in [1, 2] {
            var previousSize: CGSize?
            for panel in [CGSize(width: 100, height: 100), CGSize(width: 300, height: 100), CGSize(width: 200, height: 400)] {
                let bounds = CGRect(origin: .zero, size: panel)
                let rect = BoundedPhotoNSView.destinationRect(imageSize: CGSize(width: 120, height: 80), in: bounds,
                                                             fillsPanels: true, commonFitSize: CGSize(width: 9, height: 6),
                                                             zoomFactor: factor, normalizedCenter: anchor,
                                                             backingScaleFactor: backing)
                try expect(nearly(rect.width, 120 * factor / backing) && nearly(rect.height, 80 * factor / backing),
                           "100/150/200% must use preview pixels and account for Retina screen pixels")
                if let previousSize = previousSize {
                    try expect(rect.size == previousSize, "Unequal panels must retain the same absolute pixel zoom")
                }
                previousSize = rect.size
                let centeredPhotoPoint = BoundedPhotoNSView.normalizedImagePoint(at: CGPoint(x: bounds.midX, y: bounds.midY),
                    imageSize: CGSize(width: 120, height: 80), in: bounds, fillsPanels: false,
                    zoomFactor: factor, normalizedCenter: anchor, backingScaleFactor: backing)
                try expect(centeredPhotoPoint.map { nearly($0.x, anchor.x) && nearly($0.y, anchor.y) } == true,
                           "All panels must show the same normalized source point at their centers")
            }
        } }

        let testBounds = CGRect(x: 0, y: 0, width: 180, height: 180)
        let upperLeft = BoundedPhotoNSView.normalizedImagePoint(at: CGPoint(x: 10, y: 140),
            imageSize: CGSize(width: 120, height: 80), in: testBounds, fillsPanels: false)
        try expect(upperLeft.map { nearly($0.x, 1.0 / 18) && nearly($0.y, 1.0 / 12) } == true,
                   "Click coordinates must use the photo's top-left origin")
        try expect(BoundedPhotoNSView.normalizedImagePoint(at: CGPoint(x: 90, y: 10),
            imageSize: CGSize(width: 120, height: 80), in: testBounds, fillsPanels: false) == nil,
                   "Letterbox clicks must not change the zoom target")
        try expect(BoundedPhotoNSView.normalizedImagePoint(at: CGPoint(x: 90, y: 200),
            imageSize: CGSize(width: 120, height: 80), in: testBounds, fillsPanels: true,
            zoomFactor: 2, normalizedCenter: anchor) == nil,
                   "An oversized zoom drawing must not map clicks outside its viewport")

        // A small blue corner region becomes the center in every zoom level.
        // Inspect actual AppKit pixels, including after replacing the PF3 image.
        let blueCenter = CGPoint(x: 1.0 / 12, y: 1.0 / 8)
        for factor: CGFloat in [1, 1.5, 2] {
            view.setPhoto(image, fillsPanels: false, commonFitSize: .zero,
                          zoomFactor: factor, normalizedCenter: blueCenter)
            let zoomed = try bitmap(view)
            try expect(isColor(try rgb(zoomed, 90, 90), [0, 0, 1]), "Selected photo region moved or flipped during pixel zoom")
            try expect(view.frame.size == CGSize(width: 180, height: 180), "Pixel zoom changed layout bounds")
        }
        let replacement = try markerImage()
        var clicked: CGPoint?
        view.setPhoto(replacement, fillsPanels: false, commonFitSize: .zero,
                      zoomFactor: 1.5, normalizedCenter: blueCenter, onImageClick: { clicked = $0 })
        try expect(view.zoomFactor == 1.5 && view.normalizedCenter == blueCenter,
                   "Replacing an effect image must retain the externally supplied zoom and center")
        try expect(isColor(try rgb(try bitmap(view), 90, 90), [0, 0, 1]), "Effect image replacement lost the centered source region")
        try expect(view.hitTest(NSPoint(x: 90, y: 90)) === view, "Interactive photos must receive visible image clicks")
        try expect(view.hitTest(NSPoint(x: 90, y: 200)) == nil, "Interactive zoom intercepted a control outside its viewport")

        // hitTest receives superview coordinates, while mouseDown receives
        // window coordinates. Exercise both with an offset native photo view.
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        view.setFrameOrigin(NSPoint(x: 40, y: 70))
        host.addSubview(view)
        try expect(view.hitTest(NSPoint(x: 130, y: 160)) === view, "Offset photo hit-testing used the wrong coordinate space")
        let eventLocation = view.convert(NSPoint(x: 90, y: 90), to: nil)
        guard let event = NSEvent.mouseEvent(with: .leftMouseDown, location: eventLocation, modifierFlags: [],
                                            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                                            clickCount: 1, pressure: 1) else { throw TestFailure(description: "Could not create click event") }
        view.mouseDown(with: event)
        try expect(clicked.map { nearly($0.x, blueCenter.x) && nearly($0.y, blueCenter.y) } == true,
                   "Native image click must report the shared top-left normalized photo point")
        view.removeFromSuperview()
        view.setFrameOrigin(.zero)
        view.setPhoto(image, fillsPanels: false, commonFitSize: .zero, onImageClick: { _ in })
        try expect(view.hitTest(NSPoint(x: 90, y: 10)) == nil, "Interactive overview intercepted a letterbox click")
        try expect(view.hitTest(NSPoint(x: 90, y: 149)) === view, "Visible photo region should remain interactive without a caption reserve")
        view.setPhoto(image, fillsPanels: false, commonFitSize: .zero,
                      onImageClick: { _ in }, excludedTopHeight: 36)
        try expect(view.hitTest(NSPoint(x: 90, y: 149)) == nil,
                   "The photo must not intercept floating caption or remove-button clicks")
        try expect(view.hitTest(NSPoint(x: 90, y: 140)) === view,
                   "Caption reservation must not disable the photo below its header")
        try expect(view.hitTest(NSPoint(x: 90, y: 200)) == nil,
                   "Caption reservation must not enlarge the native hit region")
        clicked = nil
        view.setPhoto(image, fillsPanels: false, commonFitSize: .zero,
                      onImageClick: { clicked = $0 }, excludedTopHeight: 36,
                      excludedHitRects: [CGRect(x: 80, y: 0, width: 20, height: 180)])
        try expect(view.hitTest(NSPoint(x: 90, y: 90)) == nil,
                   "Native photo must leave split-divider dragging to its overlay")
        try expect(view.hitTest(NSPoint(x: 50, y: 90)) === view,
                   "A split divider reserve must not disable neighboring visible image pixels")
        guard let dividerEvent = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 90, y: 90), modifierFlags: [],
                                                   timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1,
                                                   clickCount: 1, pressure: 1) else { throw TestFailure(description: "Could not create divider click") }
        view.mouseDown(with: dividerEvent)
        try expect(clicked == nil, "A divider event must not toggle the shared photo zoom")

        // A single native canvas composes the split view. These pixel checks
        // verify the actual clip, not a SwiftUI mask around an NSView surface.
        let red = try solidImage(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        let blue = try solidImage(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        for split: CGFloat in [0.25, 0.5, 0.75] {
            view.setPhoto(red, fillsPanels: false, commonFitSize: .zero,
                          comparisonImage: blue, splitPosition: split)
            let composed = try bitmap(view)
            let boundary = Int(180 * split)
            try expect(isColor(try rgb(composed, boundary - 5, 90), [1, 0, 0]), "Before image crossed the split boundary")
            try expect(isColor(try rgb(composed, boundary + 5, 90), [0, 0, 1]), "After image was not drawn to the right of the split")
        }
        view.setPhoto(red, fillsPanels: false, commonFitSize: .zero)
        try expect(view.comparisonImage == nil, "Clearing the comparison image must remove the split")
        try expect(isColor(try rgb(try bitmap(view), 150, 90), [1, 0, 0]), "A removed comparison image left stale after pixels")
        for (position, expected): (CGFloat, [CGFloat]) in [(-1, [0, 0, 1]), (2, [1, 0, 0])] {
            view.setPhoto(red, fillsPanels: false, commonFitSize: .zero,
                          comparisonImage: blue, splitPosition: position)
            try expect(isColor(try rgb(try bitmap(view), 90, 90), expected), "Split endpoints must clamp safely")
        }

        let greenCorner = try markerImage(upperLeft: CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
        for factor: CGFloat in [1, 1.5, 2] {
            view.setPhoto(image, fillsPanels: false, commonFitSize: .zero,
                          zoomFactor: factor, normalizedCenter: blueCenter,
                          comparisonImage: greenCorner, splitPosition: 0.5)
            let composed = try bitmap(view)
            try expect(isColor(try rgb(composed, 88, 90), [0, 0, 1]), "Pixel zoom moved the before-image source region away from the split center")
            try expect(isColor(try rgb(composed, 92, 90), [0, 1, 0]), "Pixel zoom used a different focus or crop for the comparison image")
        }
        clicked = nil
        view.setPhoto(red, fillsPanels: false, commonFitSize: .zero,
                      zoomFactor: 1.5, normalizedCenter: anchor, onImageClick: { clicked = $0 },
                      comparisonImage: blue, splitPosition: 0.5)
        guard let rightEvent = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 100, y: 90), modifierFlags: [],
                                                 timestamp: 0, windowNumber: 0, context: nil, eventNumber: 2,
                                                 clickCount: 1, pressure: 1) else { throw TestFailure(description: "Could not create comparison-side click") }
        view.mouseDown(with: rightEvent)
        try expect(clicked.map { nearly($0.x, 0.25 + 10.0 / 180) && nearly($0.y, 0.75) } == true,
                   "Clicking the comparison side must map the same normalized primary-photo coordinates")

        let started = Date()
        for index in 0..<100 {
            let size = CGSize(width: 180 + index % 7, height: 160 + index % 11)
            view.setFrameSize(size)
            view.setPhoto(image, fillsPanels: index % 2 == 0, commonFitSize: CGSize(width: 150, height: 100),
                          zoomFactor: index % 3 == 0 ? nil : [CGFloat(1), 1.5, 2][index % 3],
                          normalizedCenter: CGPoint(x: CGFloat(index % 10) / 10, y: 0.7))
            _ = try bitmap(view)
            try expect(view.frame.size == size && view.bounds.size == size, "Repeated fit/fill updates changed layout bounds")
        }
        try expect(Date().timeIntervalSince(started) < 10, "Repeated display switching did not complete promptly")
        try expect(BoundedPhotoNSView.destinationRect(imageSize: .zero, in: view.bounds, fillsPanels: true).isEmpty,
                   "Invalid source dimensions must be safe")
        try expect(BoundedPhotoNSView.destinationRect(imageSize: CGSize(width: 120, height: 80), in: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 10), fillsPanels: false).isEmpty,
                   "Invalid panel dimensions must be safe")
        print("Bounded photo view checks passed: \(checks) (fit/fill, linked pixel zoom, normalized click mapping, effect replacement, bounded input, 100 mode/resize updates)")
    }
}
