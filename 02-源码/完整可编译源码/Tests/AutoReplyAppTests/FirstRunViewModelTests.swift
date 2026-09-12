import XCTest
@testable import AutoReplyApp

@MainActor
final class FirstRunViewModelTests: XCTestCase {
    func testPermissionActionOpensCorrectPaneWithoutStarting() {
        let settings = RecordingSettingsOpener()
        let viewModel = FirstRunViewModel(settings: settings)

        viewModel.openAccessibilitySettings()

        XCTAssertEqual(settings.lastPane, .accessibility)
        XCTAssertFalse(viewModel.startRequested)
    }

    func testScreenRecordingActionUsesItsOwnPrivacyPane() {
        let settings = RecordingSettingsOpener()
        let viewModel = FirstRunViewModel(settings: settings)

        viewModel.openScreenRecordingSettings()

        XCTAssertEqual(settings.lastPane, .screenRecording)
    }

    func testSendFallbackSummaryExplainsThatRunCanContinue() {
        let text = FirstRunViewModel.capabilitySummary(
            key: "sendAX",
            status: CapabilityStatus(
                level: .fallback,
                strategy: "returnKeyOnce",
                detail: "发送校准：可按40个，有效0个"
            )
        )

        XCTAssertTrue(text.contains("可按40个"))
        XCTAssertTrue(text.contains("有效0个"))
        XCTAssertTrue(text.contains("可继续运行"))
    }
}

@MainActor
private final class RecordingSettingsOpener: SystemSettingsOpening {
    private(set) var lastPane: SystemSettingsPane?
    func open(_ pane: SystemSettingsPane) { lastPane = pane }
}
