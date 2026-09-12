import XCTest
import AppKit
import AutoReplyCore
import QianniuOCRAppSupport
import CustomerReplyBatchAppSupport
@testable import AutoReplyApp

private struct FloatingUnusedGenerator: ReplyGenerating {
    func generate(for input: PromptInput) async throws -> GeneratedReply { throw CancellationError() }
}

@MainActor private final class FloatingIdleUI: NativeUIAutomation {
    let leaseRegistry = UIOperationLeaseRegistry()
    func checkSafety() throws {}
    func discover(eligibleUIDs: Set<String>?, lease: UIOperationLease) async throws -> [String] { [] }
    func open(uid: String, lease: UIOperationLease) async throws {}
    func header(lease: UIOperationLease) async throws -> String? { nil }
    func observeUnread(uid: String, lease: UIOperationLease) async throws -> (hasUnread: Bool, latestPreviewIsImage: Bool) { (false, false) }
    func recognize(includeImages: Bool, lease: UIOperationLease, stage: @escaping (OCRStage) -> Void) async throws -> OCRRunResult { OCRRunResult(lines: []) }
    func activateForValidation(lease: UIOperationLease) async throws {}
    func send(uid: String, text: String, lease: UIOperationLease) async throws -> DeliveryResult { .sent }
    func openTransferMenu(uid: String, lease: UIOperationLease) async throws {}
}

@MainActor final class FloatingProgressPanelTests: XCTestCase {
    private func hideProgressWindows() {
        NSApplication.shared.windows.filter { $0.title == "AI 客服 · 实时进度" }.forEach { $0.orderOut(nil) }
    }

    func testPanelFloatsWithoutTakingKeyboardFocusOrLeavingCurrentSpace() {
        let panel = AutoReplyFloatingProgressPanel()
        XCTAssertEqual(panel.level, .floating)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
    }

    func testVideoDetectionNoticeAppearsForOneSecondThenClears() async {
        let notice = VideoDetectionNoticeController()

        notice.show(messageID: "VIDEO.105")

        XCTAssertEqual(notice.text, "检测到视频")
        try? await Task.sleep(for: .milliseconds(1_100))
        XCTAssertNil(notice.text)
    }

    func testSameVideoMessageDoesNotFlashTwice() async {
        let notice = VideoDetectionNoticeController(displayDuration: .milliseconds(10))
        notice.show(messageID: "VIDEO.ONCE")
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(notice.text)

        notice.show(messageID: "VIDEO.ONCE")

        XCTAssertNil(notice.text)
    }

    func testVideoFlowProgressShowsEveryOperationalStepWithoutClaimingDownloadSucceeded() {
        let notice = VideoDetectionNoticeController()

        notice.advanceVideoFlow(.detected)
        XCTAssertEqual(notice.videoFlowText, "视频流程：✓ 105 → ○ 打开 → ○ 发起下载 → ○ 关窗 → ○ 继续扫描")

        notice.advanceVideoFlow(.opening)
        XCTAssertEqual(notice.videoFlowText, "视频流程：✓ 105 → ● 打开 → ○ 发起下载 → ○ 关窗 → ○ 继续扫描")

        notice.advanceVideoFlow(.downloadRequested)
        notice.advanceVideoFlow(.closingPlayer)
        notice.advanceVideoFlow(.resumedScanning)

        XCTAssertEqual(notice.videoFlowText, "视频流程：✓ 105 → ✓ 打开 → ✓ 发起下载 → ✓ 关窗 → ✓ 继续扫描")
        XCTAssertFalse(notice.videoFlowText.contains("下载成功"))
    }

    func testVideoDownloadCompletionIsShownPersistentlyInTheUI() {
        let notice = VideoDetectionNoticeController()

        notice.showDownloadCompleted(
            messageID: "VIDEO.36",
            bytes: 7_055_187,
            elapsed: 11.2
        )

        XCTAssertTrue(notice.videoFlowText.contains("视频下载完成"))
        XCTAssertTrue(notice.videoFlowText.contains("VIDEO.36"))
        XCTAssertTrue(notice.videoFlowText.contains("7.06 MB"))
        XCTAssertTrue(notice.videoFlowText.contains("11.2 秒"))
    }

    func testFrameExtractionProgressReportsFramesAndSavedAudio() {
        let notice = VideoDetectionNoticeController()

        notice.showFrameExtractionStarted(messageID: "VIDEO.36")
        XCTAssertTrue(notice.videoFlowText.contains("正在抽帧"))
        XCTAssertTrue(notice.videoFlowText.contains("转写语音"))

        notice.showFrameExtractionCompleted(
            messageID: "VIDEO.36",
            frameCount: 12,
            audioSaved: true,
            transcriptSegmentCount: 3
        )
        XCTAssertTrue(notice.videoFlowText.contains("已提取 12 帧"))
        XCTAssertTrue(notice.videoFlowText.contains("音轨已保存"))
        XCTAssertTrue(notice.videoFlowText.contains("语音已转写 3 段"))

        notice.showVideoReplyQueued(messageID: "VIDEO.36")
        XCTAssertTrue(notice.videoFlowText.contains("已提交 AI 回复"))
    }

    func testMainStatusViewUsesPersistentVideoCompletionStatus() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try AutomationAppModel(root: root, ui: FloatingIdleUI(), generator: FloatingUnusedGenerator())
        model.videoDetectionNotice.showFrameExtractionCompleted(
            messageID: "VIDEO.36",
            frameCount: 7,
            audioSaved: true,
            transcriptSegmentCount: 2
        )

        XCTAssertEqual(
            AutomationStatusView.videoStatusText(from: model.videoDetectionNotice),
            "视频处理：VIDEO.36 · 已提取 7 帧 · 音轨已保存 · 语音已转写 2 段"
        )
    }

    func testRunningOverlayAcceptsTitlebarDragButPassesThroughItsBody() {
        let frame = CGRect(x: 100, y: 100, width: 460, height: 530)
        XCTAssertFalse(AutoReplyFloatingProgressPanel.shouldIgnoreMouse(
            cursor: CGPoint(x: 200, y: 620), pressedButtons: 0, frame: frame,
            automationActive: true, titleDragArmed: false))
        XCTAssertTrue(AutoReplyFloatingProgressPanel.shouldIgnoreMouse(
            cursor: CGPoint(x: 200, y: 400), pressedButtons: 0, frame: frame,
            automationActive: true, titleDragArmed: false))
        XCTAssertFalse(AutoReplyFloatingProgressPanel.shouldIgnoreMouse(
            cursor: CGPoint(x: 300, y: 400), pressedButtons: 1, frame: frame,
            automationActive: true, titleDragArmed: true))
        XCTAssertFalse(AutoReplyFloatingProgressPanel.shouldIgnoreMouse(
            cursor: CGPoint(x: 200, y: 400), pressedButtons: 0, frame: frame,
            automationActive: false, titleDragArmed: false))
    }

    func testToggleRecreatesAClosedProgressWindow() throws {
        hideProgressWindows(); defer { hideProgressWindows() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try AutomationAppModel(root: root, ui: FloatingIdleUI(), generator: FloatingUnusedGenerator())
        let controller = AutoReplyProgressPanelController(model: model)
        controller.show()
        let first = try XCTUnwrap(NSApplication.shared.windows.first { $0.title == "AI 客服 · 实时进度" && $0.isVisible })
        first.orderOut(nil)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: first))

        controller.toggleCollapsed()

        let reopened = NSApplication.shared.windows.first { $0 !== first && $0.title == "AI 客服 · 实时进度" && $0.isVisible }
        XCTAssertNotNil(reopened)
        XCTAssertTrue(reopened?.isVisible == true)
        reopened?.close()
    }

    func testToggleBringsAnExistingHiddenProgressWindowBackOnScreen() throws {
        hideProgressWindows(); defer { hideProgressWindows() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try AutomationAppModel(root: root, ui: FloatingIdleUI(), generator: FloatingUnusedGenerator())
        let controller = AutoReplyProgressPanelController(model: model)
        controller.show()
        let window = try XCTUnwrap(NSApplication.shared.windows.first { $0.title == "AI 客服 · 实时进度" && $0.isVisible })
        window.setFrameOrigin(NSPoint(x: 9_000, y: 9_000))
        window.orderOut(nil)
        XCTAssertFalse(window.isVisible)

        controller.toggleCollapsed()

        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(NSScreen.screens.contains { $0.visibleFrame.intersects(window.frame) })
        window.close()
    }

    func testHeadlinePrefersTheExactLiveUIStage() {
        XCTAssertEqual(AutoReplyProgressPresentation.headline(
            isRunning: true,
            currentUIOwner: "tb263147182",
            stages: ["tb263147182": "OCR：识别聊天内容"],
            records: [],
            liveGenerationCount: 0,
            generationCapacity: 10
        ), "tb263147182 · OCR：识别聊天内容")
    }

    func testHeadlineShowsDynamicCapacityAndResumeThenOneSecondIdleScan() {
        var record = SchedulerRecord(uid: "stoneshishininger", sequence: 7)
        record.state = .generating
        record.sessionStage = "恢复客户会话 · 增量提交 2 条消息"
        XCTAssertEqual(AutoReplyProgressPresentation.headline(
            isRunning: true,
            currentUIOwner: nil,
            stages: [:],
            records: [record],
            liveGenerationCount: 3,
            generationCapacity: 10
        ), "stoneshishininger · AI 正在生成回复 · 恢复客户会话 · 增量提交 2 条消息 · CLI 3/10")
        XCTAssertEqual(AutoReplyProgressPresentation.headline(
            isRunning: true,
            currentUIOwner: nil,
            stages: [:],
            records: [],
            liveGenerationCount: 0,
            generationCapacity: 10
        ), "扫描当前可见红点 · 每 1 秒")
    }

    func testCustomerStageKeepsUncertainRecordsVisibleForManualReconciliation() {
        var active = SchedulerRecord(uid: "active", sequence: 3)
        active.state = .generating
        var uncertain = SchedulerRecord(uid: "warning", sequence: 2)
        uncertain.state = .uncertain
        var completed = SchedulerRecord(uid: "done", sequence: 1)
        completed.state = .completed

        let visible = AutoReplyProgressPresentation.customerStageRecords(
            [completed, uncertain, active]
        )

        XCTAssertEqual(visible.map(\.uid), ["active", "warning", "done"])
    }

    func testTaskDetailsExposeRevisionDeadlineRetryAndFailureReason() {
        let now = Date(timeIntervalSince1970: 1_100)
        let record = SchedulerRecord(
            uid: "buyer", sequence: 4, state: .parked,
            snapshot: CaptureSnapshot(
                uid: "buyer", customerRevision: "abcdef0123456789", historyJSONL: "",
                hasUnansweredCustomer: true, shouldGenerate: true
            ),
            retries: 2, updatedAt: Date(timeIntervalSince1970: 1_090),
            stageAttempt: StageAttempt(
                stage: "capture", failures: 2,
                startedAt: Date(timeIntervalSince1970: 1_080),
                deadlineAt: Date(timeIntervalSince1970: 1_120)
            ),
            parkedReason: "OCR failed twice"
        )

        let details = AutoReplyProgressPresentation.taskDetails(record, now: now)

        XCTAssertTrue(details.contains("版本 abcdef012345"))
        XCTAssertTrue(details.contains("阶段 capture"))
        XCTAssertTrue(details.contains("已用 20.0s"))
        XCTAssertTrue(details.contains("剩余 20.0s"))
        XCTAssertTrue(details.contains("重试 2"))
        XCTAssertTrue(details.contains("OCR failed twice"))
    }
}
