import CoreGraphics
import ImageIO
import XCTest
import QianniuOCRCore
@testable import QianniuOCRAppSupport

@MainActor
final class StaticPanelOCRIntegrationTests: XCTestCase {
    func testPaddleWebEngineRecognizesKnownPanelWithoutLosingStandaloneOnes() async throws {
        let imageURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "qianniu-right-panel",
                withExtension: "png",
                subdirectory: "Fixtures"
            )
        )
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(imageURL as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let engine = PaddleOCRWebEngine()

        let lines: [OCRLine]
        do {
            lines = try await engine.recognize(image)
        } catch {
            XCTFail("OCR error type=\(String(reflecting: error)); localized=\(error.localizedDescription)")
            return
        }
        let texts = lines.map(\.text)

        XCTAssertEqual(texts.filter { $0 == "1" }.count, 2, "raw OCR texts: \(texts)")
        for expected in [
            "消息记录",
            "一个月",
            "全部消息",
            "文件",
            "图片/视频",
            "由小秦转交给小丹",
            "tb263147182",
            "你好",
        ] {
            XCTAssertTrue(texts.contains(expected), "missing \(expected); raw OCR texts: \(texts)")
        }
        XCTAssertEqual(texts.filter { $0 == "tb263147182" }.count, 3)
        XCTAssertEqual(texts.filter { $0.contains("加普威旗舰店") }.count, 2)
        XCTAssertEqual(texts.filter { $0.contains("2026-8-8") && $0.contains("13:48") }.count, 5)
    }
}
