import CoreGraphics
import Foundation

public enum ChatRecordParser {
    public static func extract(from lines: [OCRLine]) -> [OCRLine] {
        guard !lines.isEmpty,
              lines.allSatisfy({ $0.box.isFiniteAndPositive }) else {
            return lines
        }

        let rows = visualRows(from: lines)
        let topY = topBoundary(in: rows)
        let bottomY = bottomBoundary(in: rows, allLines: lines)

        if let topY, let bottomY, topY >= bottomY {
            return lines
        }

        let extracted = lines.filter { line in
            let belowTop = topY.map { line.box.midY > $0 } ?? true
            let aboveBottom = bottomY.map { line.box.midY < $0 } ?? true
            return belowTop && aboveBottom
        }
        return extracted.isEmpty ? lines : extracted
    }

    private static func visualRows(from lines: [OCRLine]) -> [VisualRow] {
        let sorted = lines.sorted { lhs, rhs in
            if lhs.box.midY != rhs.box.midY { return lhs.box.midY < rhs.box.midY }
            return lhs.box.minX < rhs.box.minX
        }
        var rows: [VisualRow] = []

        for line in sorted {
            if let lastIndex = rows.indices.last,
               rows[lastIndex].accepts(line) {
                rows[lastIndex].append(line)
            } else {
                rows.append(VisualRow(line))
            }
        }
        return rows
    }

    private static func topBoundary(in rows: [VisualRow]) -> CGFloat? {
        if let bannerIndex = rows.firstIndex(where: { isRoamingBanner($0.normalizedText) }) {
            return refinedTopBoundary(
                after: bannerIndex,
                fallback: rows[bannerIndex].maxY,
                in: rows
            )
        }

        if rows.count >= 2 {
            for index in 0..<(rows.count - 1) {
                let first = rows[index]
                let second = rows[index + 1]
                let gap = max(0, second.minY - first.maxY)
                let allowedGap = max(first.height, second.height) * 1.5
                if gap <= allowedGap,
                   isRoamingBanner(first.normalizedText + second.normalizedText) {
                    return refinedTopBoundary(
                        after: index + 1,
                        fallback: max(first.maxY, second.maxY),
                        in: rows
                    )
                }
            }
        }

        guard let navigationIndex = rows.firstIndex(where: isMessageTypeNavigation) else {
            return nil
        }

        return refinedTopBoundary(
            after: navigationIndex,
            fallback: rows[navigationIndex].maxY,
            in: rows
        )
    }

    private static func refinedTopBoundary(
        after anchorIndex: Int,
        fallback: CGFloat,
        in rows: [VisualRow]
    ) -> CGFloat {
        if let timestampRow = rows.dropFirst(anchorIndex + 1).first(where: { row in
            row.lines.contains { isTimestamp($0.text) }
        }) {
            // Start immediately before the whole sender/timestamp row so every
            // OCR fragment on that row is retained.
            return timestampRow.minY.nextDown
        }

        return fallback
    }

    private static func bottomBoundary(
        in rows: [VisualRow],
        allLines: [OCRLine]
    ) -> CGFloat? {
        guard let minY = allLines.map(\.box.minY).min(),
              let maxY = allLines.map(\.box.maxY).max(),
              maxY > minY else {
            return nil
        }
        let lowerRegionStart = minY + (maxY - minY) * 0.65
        return rows
            .filter { row in
                row.midY >= lowerRegionStart
                    && row.lines.contains(where: { isPageCount($0.text) })
            }
            .max(by: { $0.midY < $1.midY })?
            .minY
    }

    private static func isRoamingBanner(_ normalizedText: String) -> Bool {
        normalizedText.contains("漫游")
            && normalizedText.contains("消息")
            && (normalizedText.contains("一个月") || normalizedText.contains("近"))
    }

    private static func isMessageTypeNavigation(_ row: VisualRow) -> Bool {
        let labels = ["全部消息", "文件", "图片/视频"]
        let hits = labels.filter { label in
            row.lines.contains { normalized($0.text).contains(label) }
        }
        return hits.count >= 2
    }

    private static func isPageCount(_ text: String) -> Bool {
        let parts = normalized(text).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let current = Int(parts[0]),
              let total = Int(parts[1]) else {
            return false
        }
        return current > 0 && total > 0
    }

    private static func isTimestamp(_ text: String) -> Bool {
        let compact = normalized(text)
        return compact.range(
            of: #"^\d{4}[-/.]\d{1,2}[-/.]\d{1,2}\d{1,2}:\d{2}:\d{2}$"#,
            options: .regularExpression
        ) != nil
    }

    private static func normalized(_ text: String) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
    }
}

private struct VisualRow {
    private(set) var lines: [OCRLine]
    private(set) var minY: CGFloat
    private(set) var maxY: CGFloat

    init(_ line: OCRLine) {
        lines = [line]
        minY = line.box.minY
        maxY = line.box.maxY
    }

    var height: CGFloat { maxY - minY }
    var midY: CGFloat { (minY + maxY) / 2 }
    var normalizedText: String {
        lines
            .sorted { $0.box.minX < $1.box.minX }
            .map { line in
                String(line.text.unicodeScalars.filter {
                    !CharacterSet.whitespacesAndNewlines.contains($0)
                })
            }
            .joined()
    }

    func accepts(_ line: OCRLine) -> Bool {
        let verticallyOverlaps = min(maxY, line.box.maxY) > max(minY, line.box.minY)
        let closeCenters = abs(midY - line.box.midY) <= max(height, line.box.height) * 0.6
        return verticallyOverlaps || closeCenters
    }

    mutating func append(_ line: OCRLine) {
        lines.append(line)
        minY = min(minY, line.box.minY)
        maxY = max(maxY, line.box.maxY)
    }
}

private extension CGRect {
    var isFiniteAndPositive: Bool {
        minX.isFinite
            && minY.isFinite
            && width.isFinite
            && height.isFinite
            && width > 0
            && height > 0
    }
}
