import CoreGraphics
import XCTest
@testable import QianniuOCRCore

final class SpatialOrderingTests: XCTestCase {
    func testReadingOrderPrioritizesRowsThenHorizontalPosition() {
        let lines = [
            OCRLine(text: "右下", box: CGRect(x: 180, y: 104, width: 40, height: 18)),
            OCRLine(text: "右上", box: CGRect(x: 160, y: 20, width: 40, height: 18)),
            OCRLine(text: "左下", box: CGRect(x: 20, y: 100, width: 40, height: 18)),
            OCRLine(text: "左上", box: CGRect(x: 10, y: 24, width: 40, height: 18)),
        ]

        XCTAssertEqual(
            SpatialOrdering.readingOrder(lines).map(\.text),
            ["左上", "右上", "左下", "右下"]
        )
    }

    func testReadingOrderPreservesShortAndRepeatedLines() {
        let lines = [
            OCRLine(text: "1", box: CGRect(x: 20, y: 60, width: 8, height: 16)),
            OCRLine(text: "1", box: CGRect(x: 20, y: 20, width: 8, height: 16)),
        ]

        let result = SpatialOrdering.readingOrder(lines)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.map(\.text), ["1", "1"])
        XCTAssertEqual(result.map(\.box.minY), [20, 60])
    }
}
