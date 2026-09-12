import XCTest
import AppKit
import UnreadCore
@testable import UnreadApp

final class FloatingPanelTests: XCTestCase {
    @MainActor func testLongTimelineDoesNotForceFloatingWindowToGrow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ProgressDisplayModel(root: root)
        let controller = ProgressPanelController(model: model)
        controller.show()
        defer { controller.hide() }
        model.hideMonitoring()
        model.apply(ProgressSnapshot(tasks: [ProgressTask(id: "long", uid: "test", stage: "已发送", events: (0..<100).map { ProgressEvent(id: "\($0)", date: Date(), title: "步骤\($0)", detail: String(repeating: "详细记录", count: 10)) }, isTerminal: true, cliActive: false)], warnings: [], activeCLICount: 0))
        controller.toggleCollapsed()
        controller.toggleCollapsed()
        try await Task.sleep(for: .milliseconds(150))
        let panel = try XCTUnwrap(NSApp.windows.first { $0 is FloatingProgressPanel && $0.isVisible })
        XCTAssertLessThanOrEqual(panel.frame.height, 600, "A long timeline must scroll, not enlarge the float")
    }
    @MainActor func testPanelNeverTakesKeyboardFocusAndStaysVisibleWhenOtherAppActive() {
        let panel = FloatingProgressPanel()
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertEqual(panel.level, .floating)
        XCTAssertFalse(panel.hidesOnDeactivate)
    }
    @MainActor func testAutomationPassesClicksThroughOverlay() {
        let panel = FloatingProgressPanel()
        panel.setAutomationActive(true)
        XCTAssertTrue(panel.ignoresMouseEvents)
        panel.setAutomationActive(false)
        XCTAssertFalse(panel.ignoresMouseEvents)
    }
    @MainActor func testStatusFilterExcludesEditorAndChatContents() {
        XCTAssertFalse(PhaseOneStatusReader.shouldDescend(role: kAXTextAreaRole as String))
        XCTAssertFalse(PhaseOneStatusReader.shouldDescend(role: kAXTextFieldRole as String))
        XCTAssertTrue(PhaseOneStatusReader.shouldDescend(role: kAXGroupRole as String))
    }
}
