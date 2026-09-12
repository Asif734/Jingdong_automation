import CoreGraphics
import XCTest
@testable import QianniuOCRCore

final class ModelsTests: XCTestCase {
    func testJSONPresentationIsLosslessAndPrettyPrinted() throws {
        let lines = [
            OCRLine(text: "1", box: .zero),
            OCRLine(text: "原文 \"引号\"\n第二行", box: .zero),
            OCRLine(text: "1", box: .zero),
        ]

        let output = try OCRPresentation.jsonArray(lines)

        XCTAssertEqual(
            output,
            "[\n  \"1\",\n  \"原文 \\\"引号\\\"\\n第二行\",\n  \"1\"\n]"
        )
    }

    func testPixelCropUsesScaleAndWindowRelativeCoordinates() {
        let crop = CropGeometry.pixelCrop(
            panel: CGRect(x: 900, y: 220, width: 300, height: 500),
            window: CGRect(x: 100, y: 100, width: 1200, height: 700),
            imageSize: CGSize(width: 2400, height: 1400)
        )

        XCTAssertEqual(crop, CGRect(x: 1600, y: 240, width: 600, height: 1000))
    }
}
