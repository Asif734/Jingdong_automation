import CoreGraphics
import Foundation

public enum SpatialOrdering {
    public static func readingOrder(
        _ lines: [OCRLine],
        rowTolerance: CGFloat = 8
    ) -> [OCRLine] {
        let verticallySorted = lines.enumerated().sorted { lhs, rhs in
            let leftY = lhs.element.box.midY
            let rightY = rhs.element.box.midY
            if leftY != rightY { return leftY < rightY }
            if lhs.element.box.minX != rhs.element.box.minX {
                return lhs.element.box.minX < rhs.element.box.minX
            }
            return lhs.offset < rhs.offset
        }

        var rows: [[(offset: Int, element: OCRLine)]] = []
        var rowCenters: [CGFloat] = []

        for item in verticallySorted {
            if let index = rowCenters.lastIndex(where: {
                abs($0 - item.element.box.midY) <= rowTolerance
            }) {
                rows[index].append(item)
                let total = rows[index].reduce(CGFloat.zero) { $0 + $1.element.box.midY }
                rowCenters[index] = total / CGFloat(rows[index].count)
            } else {
                rows.append([item])
                rowCenters.append(item.element.box.midY)
            }
        }

        return rows.flatMap { row in
            row.sorted { lhs, rhs in
                if lhs.element.box.minX != rhs.element.box.minX {
                    return lhs.element.box.minX < rhs.element.box.minX
                }
                return lhs.offset < rhs.offset
            }.map(\.element)
        }
    }
}
