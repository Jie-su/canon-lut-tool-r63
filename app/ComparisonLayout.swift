import Foundation
import CoreGraphics

/// Stable, edge-to-edge panel partitions. Image fitting is separate so a wider
/// panel in the last row never gives its photo a privileged comparison scale.
enum ComparisonLayout {
    private static let templates = [[1], [2], [2, 1], [2, 2], [3, 2],
                                    [3, 3], [3, 2, 2], [3, 3, 2], [3, 3, 3]]

    static func frames(count: Int, in size: CGSize, spacing: CGFloat = 2) -> [CGRect] {
        guard (1...9).contains(count), size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return [] }
        let rows = templates[count - 1]
        let requestedGap = spacing.isFinite ? max(0, spacing) : 2
        // Keep even a transient one-point viewport valid during window resizing.
        let gap = min(requestedGap, min(size.width, size.height) / CGFloat(count * 2))
        let height = (size.height - gap * CGFloat(rows.count - 1)) / CGFloat(rows.count)
        var result: [CGRect] = []
        for (row, population) in rows.enumerated() {
            let width = (size.width - gap * CGFloat(population - 1)) / CGFloat(population)
            for column in 0..<population {
                result.append(CGRect(x: CGFloat(column) * (width + gap),
                                     y: CGFloat(row) * (height + gap),
                                     width: width, height: height))
            }
        }
        return result
    }

    /// A single fitted image size shared by the original and every result.
    /// Captions float above the canvas and therefore consume no image height.
    static func commonImageSize(in frames: [CGRect], imageAspectRatio: CGFloat) -> CGSize {
        guard !frames.isEmpty, frames.allSatisfy({ valid($0.size) }) else { return .zero }
        let aspect = safeAspect(imageAspectRatio)
        let width = frames.map(\.width).min()!
        let height = frames.map(\.height).min()!
        let fittedHeight = min(height, width / aspect)
        return CGSize(width: fittedHeight * aspect, height: fittedHeight)
    }

    /// Fill only changes the viewport: proportional enlargement is clipped by
    /// the panel. PNG export continues to use the complete rendered CGImage.
    static func filledImageSize(in panel: CGSize, imageAspectRatio: CGFloat) -> CGSize {
        guard valid(panel) else { return .zero }
        let aspect = safeAspect(imageAspectRatio)
        let height = max(panel.height, panel.width / aspect)
        return CGSize(width: height * aspect, height: height)
    }

    private static func valid(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }

    private static func safeAspect(_ ratio: CGFloat) -> CGFloat {
        let value = ratio.isFinite && ratio > 0 ? ratio : 1.5
        return min(1_000_000, max(0.000_001, value))
    }
}
