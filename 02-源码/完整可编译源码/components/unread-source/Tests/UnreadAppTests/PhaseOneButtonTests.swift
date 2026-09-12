import XCTest
@testable import UnreadApp

final class PhaseOneButtonTests: XCTestCase {
    @MainActor func testActualSwiftUIButtonDescriptionWithMissingTitleIsRecognized() {
        // Recorded by the signed read-only harness from the actual installed OCR.
        XCTAssertTrue(PhaseOneLink.matchesRecognitionButton(role: "AXButton", title: nil, description: "识别千牛主聊天区"))
        XCTAssertTrue(PhaseOneLink.matchesRecognitionButton(role: "AXButton", title: "", description: "识别千牛主聊天区"))
    }
    @MainActor func testExactLegacyTitleAndOnlyRecognitionButtonMatch() {
        XCTAssertTrue(PhaseOneLink.matchesRecognitionButton(role: "AXButton", title: "识别千牛主聊天区", description: nil))
        XCTAssertFalse(PhaseOneLink.matchesRecognitionButton(role: "AXButton", title: nil, description: "复制全部"))
        XCTAssertFalse(PhaseOneLink.matchesRecognitionButton(role: "AXStaticText", title: nil, description: "识别千牛主聊天区"))
        XCTAssertFalse(PhaseOneLink.matchesRecognitionButton(role: "AXButton", title: "其他按钮", description: "识别千牛主聊天区"))
        XCTAssertFalse(PhaseOneLink.matchesRecognitionButton(role: "AXButton", title: nil, description: "识别千牛主聊天区更多"))
    }
}
