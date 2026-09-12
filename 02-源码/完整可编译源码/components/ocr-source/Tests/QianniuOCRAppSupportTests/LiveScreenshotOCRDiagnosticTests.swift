import CoreGraphics
import Foundation
import ImageIO
import XCTest
import QianniuOCRCore
@testable import QianniuOCRAppSupport

@MainActor
final class LiveScreenshotOCRDiagnosticTests: XCTestCase {
    func testOptionalLiveScreenshot() async throws {
        guard let path = ProcessInfo.processInfo.environment["QIANNIU_OCR_DIAGNOSTIC_IMAGE"] else {
            throw XCTSkip("Set QIANNIU_OCR_DIAGNOSTIC_IMAGE to run the live diagnostic.")
        }
        let imageURL = URL(fileURLWithPath: path)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(imageURL as CFURL, nil))
        var image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        if let crop = ProcessInfo.processInfo.environment["QIANNIU_OCR_DIAGNOSTIC_CROP"] {
            let values = crop.split(separator: ",").compactMap { Double($0) }
            XCTAssertEqual(values.count, 4)
            guard values.count == 4 else { return }
            image = try XCTUnwrap(image.cropping(to: CGRect(
                x: values[0], y: values[1], width: values[2], height: values[3]
            )))
        }

        let started = ContinuousClock.now
        let lines = try await PaddleOCRWebEngine().recognize(image)
        let elapsed = started.duration(to: .now)
        let boxes = await Task.detached {
            ConsensusChatImageDetector().detect(in: image)
        }.value
        let parsed = ParsedChatParser.parse(
            lines: lines,
            imageBoxes: boxes,
            imageHeight: CGFloat(image.height),
            serviceAliases: ProcessInfo.processInfo.environment["QIANNIU_OCR_DIAGNOSTIC_SERVICE_ALIASES"]
                .map { Set($0.split(separator: ",").map(String.init)) }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let parsedJSON = String(decoding: try encoder.encode(parsed), as: UTF8.self)
        print("LIVE_OCR_ELAPSED=\(elapsed)")
        print("LIVE_OCR_LINES_BEGIN")
        for line in SpatialOrdering.readingOrder(lines) {
            print("\(line.text)\t\(line.box.debugDescription)\tconfidence=\(line.confidence ?? -1)")
        }
        print("LIVE_OCR_LINES_END")
        print("LIVE_IMAGE_BOXES=\(boxes)")
        print("LIVE_PARSED_BEGIN")
        print(parsedJSON)
        print("LIVE_PARSED_END")
    }
}
