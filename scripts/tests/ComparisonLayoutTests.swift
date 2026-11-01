import Foundation
import CoreGraphics

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

@main struct ComparisonLayoutTests {
    private static var checks = 0
    private static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw TestFailure(description: message) }
        checks += 1
    }
    private static func nearly(_ a: CGFloat, _ b: CGFloat) -> Bool {
        abs(a - b) <= 0.000_001 * max(1, abs(a), abs(b))
    }
    private static func rows(_ frames: [CGRect]) -> [[CGRect]] {
        var rows: [[CGRect]] = []
        for rect in frames {
            if let last = rows.last, nearly(last[0].minY, rect.minY) { rows[rows.count - 1].append(rect) }
            else { rows.append([rect]) }
        }
        return rows
    }

    private static func checkPanels(_ frames: [CGRect], count: Int, size: CGSize, gap: CGFloat) throws {
        try expect(frames.count == count, "Wrong number of panels")
        for rect in frames {
            try expect(rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite,
                       "Non-finite panel")
            try expect(rect.width > 0 && rect.height > 0, "Empty panel")
            try expect(rect.minX >= -0.000_001 && rect.minY >= -0.000_001 && rect.maxX <= size.width + 0.000_001 && rect.maxY <= size.height + 0.000_001,
                       "Panel outside the canvas")
        }
        for a in frames.indices { for b in frames.indices where a < b {
            let intersection = frames[a].intersection(frames[b])
            try expect(intersection.isNull || intersection.width * intersection.height < 0.000_001,
                       "Overlapping panels")
        } }
        try expect(frames.first?.origin == .zero, "Original must begin in the top-left corner")
        let grouped = rows(frames)
        for row in grouped {
            try expect(nearly(row[0].minX, 0) && nearly(row.last!.maxX, size.width), "Every row must fill the entire canvas width")
            try expect(row.allSatisfy { nearly($0.height, frames[0].height) }, "Rows must share the canvas height evenly")
            for index in 1..<row.count {
                try expect(nearly(row[index].minX - row[index - 1].maxX, gap), "Inconsistent horizontal seam")
            }
        }
        for index in 1..<grouped.count {
            try expect(nearly(grouped[index][0].minY - grouped[index - 1][0].maxY, gap), "Inconsistent vertical seam")
        }
        try expect(nearly(frames.map(\.maxY).max()!, size.height), "Panels must reach the bottom of the canvas")
        // Each row has no unexplained margin or hidden empty cell: its panel
        // areas plus its seams cover the whole row, and rows fill the height.
        let totalPanelArea = frames.reduce(CGFloat(0)) { $0 + $1.width * $1.height }
        let rowSeams = grouped.reduce(CGFloat(0)) { $0 + CGFloat($1.count - 1) * gap * $1[0].height }
        let horizontalSeams = CGFloat(grouped.count - 1) * gap * size.width
        try expect(nearly(totalPanelArea + rowSeams + horizontalSeams, size.width * size.height), "Canvas has an unfilled region")
    }

    private static func checkPhotoSizing(_ frames: [CGRect], aspect: CGFloat) throws {
        let common = ComparisonLayout.commonImageSize(in: frames, imageAspectRatio: aspect)
        try expect(common.width > 0 && common.height > 0, "Empty fitted photo")
        try expect(nearly(common.width / common.height, aspect), "Fit must preserve the source photo ratio")
        var touchesConstraint = false
        for rect in frames {
            try expect(common.width <= rect.width + 0.000_001 && common.height <= rect.height + 0.000_001, "Common fit crops a panel")
            touchesConstraint = touchesConstraint || nearly(common.width, rect.width) || nearly(common.height, rect.height)
            let fill = ComparisonLayout.filledImageSize(in: rect.size, imageAspectRatio: aspect)
            try expect(nearly(fill.width / fill.height, aspect), "Fill must preserve the source photo ratio")
            try expect(fill.width >= rect.width - 0.000_001 && fill.height >= rect.height - 0.000_001, "Fill leaves an uncovered edge")
            try expect(nearly(fill.width, rect.width) || nearly(fill.height, rect.height), "Fill should use the least enlargement that covers the panel")
        }
        try expect(touchesConstraint, "Shared fit should use the largest scale that fits every panel")
    }

    static func main() throws {
        let templates = [[1], [2], [2, 1], [2, 2], [3, 2], [3, 3], [3, 2, 2], [3, 3, 2], [3, 3, 3]]
        let sizes = [CGSize(width: 1_180, height: 750), CGSize(width: 740, height: 450),
                     CGSize(width: 650, height: 1_000), CGSize(width: 2_100, height: 400),
                     CGSize(width: 320, height: 320), CGSize(width: 1, height: 1)]
        for size in sizes { for count in 1...9 { for spacing: CGFloat in [0, 2, 20] {
            let frames = ComparisonLayout.frames(count: count, in: size, spacing: spacing)
            let effectiveGap = min(spacing, min(size.width, size.height) / CGFloat(count * 2))
            try checkPanels(frames, count: count, size: size, gap: effectiveGap)
            try expect(rows(frames).map(\.count) == templates[count - 1], "Unexpected stable template for \(count)")
            try expect(frames == ComparisonLayout.frames(count: count, in: size, spacing: spacing), "Layout must be deterministic")
            for aspect: CGFloat in [1.5, 2.0 / 3, 1, 2.4] {
                try checkPhotoSizing(frames, aspect: aspect)
            }
        } } }
        let normal = CGSize(width: 1_180, height: 750)
        for count in [3, 5, 7, 8] {
            let frames = ComparisonLayout.frames(count: count, in: normal)
            let common = ComparisonLayout.commonImageSize(in: frames, imageAspectRatio: 1.5)
            let narrowest = frames.map(\.width).min()!
            // The wider final row still receives this same image size. It has
            // more neutral margin instead of silently magnifying its photos.
            try expect(common.width <= narrowest + 0.000_001, "Wide panels must not enlarge their fitted photo")
            try expect(frames.contains { $0.width > narrowest + 1 }, "The test must include an incomplete row")
        }
        try expect(ComparisonLayout.frames(count: 0, in: normal).isEmpty, "Zero panels")
        try expect(ComparisonLayout.frames(count: 10, in: normal).isEmpty, "Reject more than nine panels")
        for invalid in [CGSize.zero, CGSize(width: -1, height: 10), CGSize(width: CGFloat.infinity, height: 10), CGSize(width: 10, height: CGFloat.nan)] {
            try expect(ComparisonLayout.frames(count: 2, in: invalid).isEmpty, "Invalid viewport must be rejected")
        }
        let frames = ComparisonLayout.frames(count: 9, in: normal)
        for invalid: CGFloat in [.nan, -.infinity, 0, -1] {
            try expect(ComparisonLayout.commonImageSize(in: frames, imageAspectRatio: invalid) == ComparisonLayout.commonImageSize(in: frames, imageAspectRatio: 1.5), "Invalid aspect must fall back safely")
        }
        for extreme: CGFloat in [CGFloat.leastNonzeroMagnitude, CGFloat.greatestFiniteMagnitude] {
            let size = ComparisonLayout.commonImageSize(in: frames, imageAspectRatio: extreme)
            let fill = ComparisonLayout.filledImageSize(in: normal, imageAspectRatio: extreme)
            try expect(size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0, "Extreme aspect must produce a valid common fit")
            try expect(fill.width.isFinite && fill.height.isFinite && fill.width > 0 && fill.height > 0, "Extreme aspect must produce valid fill geometry")
        }
        try expect(ComparisonLayout.commonImageSize(in: [], imageAspectRatio: 1.5) == .zero, "No panels means no fitted image")
        try expect(ComparisonLayout.filledImageSize(in: .zero, imageAspectRatio: 1.5) == .zero, "Invalid panel means no filled image")
        try expect(ComparisonLayout.frames(count: 5, in: normal, spacing: .nan) == ComparisonLayout.frames(count: 5, in: normal), "Invalid seam falls back safely")
        print("Comparison layout checks passed: \(checks) (1...9 panels; edge-to-edge templates, shared complete fit, proportional fill)")
    }
}
