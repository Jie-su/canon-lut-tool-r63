import AppKit
import SwiftUI

/// The photo never participates in SwiftUI's size negotiation. In particular,
/// fill changes a drawing rectangle, not the size of a resizable Image child.
struct PreviewPhotoView: NSViewRepresentable {
    let image: CGImage
    var fillsPanels = false
    var commonFitSize: CGSize = .zero
    /// nil keeps the fitted/filled overview. 1 means one preview pixel per
    /// screen pixel; point dimensions account for the window's backing scale.
    var zoomFactor: CGFloat? = nil
    /// A point in the photo, normalized from its top-left corner.
    var normalizedCenter = CGPoint(x: 0.5, y: 0.5)
    var onImageClick: ((CGPoint) -> Void)? = nil
    /// Reserves floating captions and their buttons above the photo surface.
    var excludedTopHeight: CGFloat = 0
    /// Local AppKit rectangles reserved for overlays such as a split divider.
    var excludedHitRects: [CGRect] = []
    /// Optional after-image drawn to the right of an in-view divider.
    var comparisonImage: CGImage? = nil
    var splitPosition: CGFloat = 0.5

    func makeNSView(context: Context) -> BoundedPhotoNSView {
        BoundedPhotoNSView(frame: .zero)
    }

    func updateNSView(_ view: BoundedPhotoNSView, context: Context) {
        view.setPhoto(image, fillsPanels: fillsPanels, commonFitSize: commonFitSize,
                      zoomFactor: zoomFactor, normalizedCenter: normalizedCenter,
                      onImageClick: onImageClick, excludedTopHeight: excludedTopHeight,
                      excludedHitRects: excludedHitRects, comparisonImage: comparisonImage,
                      splitPosition: splitPosition)
    }
}

final class BoundedPhotoNSView: NSView {
    private(set) var image: CGImage?
    private(set) var fillsPanels = false
    private(set) var commonFitSize: CGSize = .zero
    private(set) var zoomFactor: CGFloat?
    private(set) var normalizedCenter = CGPoint(x: 0.5, y: 0.5)
    private var onImageClick: ((CGPoint) -> Void)?
    private(set) var excludedTopHeight: CGFloat = 0
    private(set) var excludedHitRects: [CGRect] = []
    private(set) var comparisonImage: CGImage?
    private(set) var splitPosition: CGFloat = 0.5

    private var photoSize: CGSize {
        image.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
    }

    private var displayScale: CGFloat { window?.backingScaleFactor ?? 1 }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    // A larger drawing rectangle never creates a larger pointer target. With
    // no handler, events still pass through to the host's selection controls.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard onImageClick != nil, !isHidden else { return nil }
        let local = convert(point, from: superview)
        return imagePoint(at: local) == nil ? nil : self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let point = imagePoint(at: convert(event.locationInWindow, from: nil)) else { return }
        onImageClick?(point)
    }

    func setPhoto(_ image: CGImage, fillsPanels: Bool, commonFitSize: CGSize,
                  zoomFactor: CGFloat? = nil,
                  normalizedCenter: CGPoint = CGPoint(x: 0.5, y: 0.5),
                  onImageClick: ((CGPoint) -> Void)? = nil,
                  excludedTopHeight: CGFloat = 0,
                  excludedHitRects: [CGRect] = [],
                  comparisonImage: CGImage? = nil,
                  splitPosition: CGFloat = 0.5) {
        self.onImageClick = onImageClick
        self.excludedTopHeight = excludedTopHeight.isFinite ? max(0, excludedTopHeight) : 0
        self.excludedHitRects = excludedHitRects
        let split = splitPosition.isFinite ? min(1, max(0, splitPosition)) : 0.5
        guard self.image !== image || self.fillsPanels != fillsPanels || self.commonFitSize != commonFitSize ||
                self.zoomFactor != zoomFactor || self.normalizedCenter != normalizedCenter ||
                self.comparisonImage !== comparisonImage || self.splitPosition != split else { return }
        self.image = image
        self.fillsPanels = fillsPanels
        self.commonFitSize = commonFitSize
        self.zoomFactor = zoomFactor
        self.normalizedCenter = normalizedCenter
        self.comparisonImage = comparisonImage
        self.splitPosition = split
        needsDisplay = true
    }

    private func imagePoint(at point: CGPoint) -> CGPoint? {
        guard point.y < bounds.maxY - min(bounds.height, excludedTopHeight),
              !excludedHitRects.contains(where: { $0.contains(point) }) else { return nil }
        return Self.normalizedImagePoint(at: point, imageSize: photoSize, in: bounds,
                                         fillsPanels: fillsPanels, commonFitSize: commonFitSize,
                                         zoomFactor: zoomFactor, normalizedCenter: normalizedCenter,
                                         backingScaleFactor: displayScale)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image = image, let context = NSGraphicsContext.current?.cgContext else { return }
        let destination = Self.destinationRect(imageSize: CGSize(width: image.width, height: image.height),
                                               in: bounds, fillsPanels: fillsPanels,
                                               commonFitSize: commonFitSize,
                                               zoomFactor: zoomFactor, normalizedCenter: normalizedCenter,
                                               backingScaleFactor: displayScale)
        guard !destination.isEmpty else { return }
        context.saveGState()
        context.clip(to: bounds)
        context.interpolationQuality = .high
        context.draw(image, in: destination)
        if let comparison = comparisonImage, splitPosition < 1 {
            let splitX = bounds.minX + bounds.width * splitPosition
            let afterDestination = Self.destinationRect(imageSize: CGSize(width: comparison.width, height: comparison.height),
                                                       in: bounds, fillsPanels: fillsPanels,
                                                       commonFitSize: commonFitSize,
                                                       zoomFactor: zoomFactor, normalizedCenter: normalizedCenter,
                                                       backingScaleFactor: displayScale)
            context.clip(to: CGRect(x: splitX, y: bounds.minY, width: bounds.maxX - splitX, height: bounds.height))
            context.draw(comparison, in: afterDestination)
        }
        context.restoreGState()
    }

    /// Complete mode uses one scale for both axes, capped by the actual local
    /// bounds as well as the shared comparison size. Fill is clipped at bounds.
    static func destinationRect(imageSize: CGSize, in bounds: CGRect, fillsPanels: Bool,
                                commonFitSize: CGSize = .zero,
                                zoomFactor: CGFloat? = nil,
                                normalizedCenter: CGPoint = CGPoint(x: 0.5, y: 0.5),
                                backingScaleFactor: CGFloat = 1) -> CGRect {
        guard valid(imageSize), valid(bounds.size), bounds.minX.isFinite, bounds.minY.isFinite else { return .zero }
        let widthScale = bounds.width / imageSize.width
        let heightScale = bounds.height / imageSize.height
        var scale = fillsPanels ? max(widthScale, heightScale) : min(widthScale, heightScale)
        let manual = zoomFactor.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        if let manual = manual {
            let backing = backingScaleFactor.isFinite && backingScaleFactor > 0 ? backingScaleFactor : 1
            scale = manual / backing
        } else if !fillsPanels, valid(commonFitSize) {
            scale = min(scale, commonFitSize.width / imageSize.width, commonFitSize.height / imageSize.height)
        }
        let width = imageSize.width * scale, height = imageSize.height * scale
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return .zero }
        let center = manual == nil ? CGPoint(x: 0.5, y: 0.5) : safeCenter(normalizedCenter)
        // Drawing uses an unflipped AppKit coordinate system; the externally
        // shared center is measured from the photo's top-left corner.
        return CGRect(x: bounds.midX - width * center.x,
                      y: bounds.midY - height * (1 - center.y), width: width, height: height)
    }

    /// Maps only a visible photo pixel, never letterboxing or a region outside
    /// this panel, to top-left normalized image coordinates.
    static func normalizedImagePoint(at point: CGPoint, imageSize: CGSize, in bounds: CGRect,
                                     fillsPanels: Bool, commonFitSize: CGSize = .zero,
                                     zoomFactor: CGFloat? = nil,
                                     normalizedCenter: CGPoint = CGPoint(x: 0.5, y: 0.5),
                                     backingScaleFactor: CGFloat = 1) -> CGPoint? {
        guard point.x.isFinite, point.y.isFinite, bounds.contains(point) else { return nil }
        let destination = destinationRect(imageSize: imageSize, in: bounds, fillsPanels: fillsPanels,
                                          commonFitSize: commonFitSize, zoomFactor: zoomFactor,
                                          normalizedCenter: normalizedCenter, backingScaleFactor: backingScaleFactor)
        guard !destination.isEmpty, destination.contains(point) else { return nil }
        return CGPoint(x: (point.x - destination.minX) / destination.width,
                       y: 1 - (point.y - destination.minY) / destination.height)
    }

    private static func safeCenter(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x.isFinite ? min(1, max(0, point.x)) : 0.5,
                y: point.y.isFinite ? min(1, max(0, point.y)) : 0.5)
    }

    private static func valid(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }
}
