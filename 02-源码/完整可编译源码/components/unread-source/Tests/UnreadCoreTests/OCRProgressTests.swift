import XCTest
@testable import UnreadCore

final class OCRProgressTests: XCTestCase {
    func sample(_ status: String, enabled: Bool = true) -> OCRStatusSample? {
        OCRStatusSample(texts: ["千牛主聊天区 OCR · Plan B", status], recognitionButtonEnabled: enabled)
    }
    func testOldFinishedStatusDoesNotFinishNewRun() throws {
        let old = try XCTUnwrap(sample("识别完成 · 没有新消息 · UID：alice（ax_header） 总耗时：1,234 ms AI 客服处理状态 最近一次处理完成"))
        var tracker = OCRProgressTracker(uid: "alice", baseline: old)
        XCTAssertNil(tracker.observe(old))
        XCTAssertFalse(tracker.finished)
    }
    func testRunningThenNoNewMessagesEndsWithoutClaimingQueue() throws {
        var tracker = OCRProgressTracker(uid: "alice", baseline: nil)
        XCTAssertNotNil(tracker.observe(try XCTUnwrap(sample("正在识别文字…", enabled: false))))
        XCTAssertNil(tracker.observe(try XCTUnwrap(sample("正在识别文字…", enabled: false))))
        let end = try XCTUnwrap(tracker.observe(try XCTUnwrap(sample("识别完成 · 没有新消息 · UID：alice（ax_header） 总耗时：123 ms"))))
        XCTAssertTrue(end.isTerminal)
        XCTAssertTrue(end.noNewMessages)
        XCTAssertTrue(tracker.finished)
    }
    func testOtherUIDCannotBeAttributedToRequestedUser() throws {
        var tracker = OCRProgressTracker(uid: "alice", baseline: nil)
        let end = tracker.observe(try XCTUnwrap(sample("识别完成 · UID：bob（ax_header） 总耗时：45 ms")))
        XCTAssertNil(end)
        XCTAssertFalse(tracker.finished)
    }
    func testPipelineTextChangesDoNotTurnStaleOCRIntoNewScan() throws {
        let first = try XCTUnwrap(sample("识别完成 · UID：alice（ax_header） 总耗时：1,234 ms AI 客服处理状态 正在发送到千牛"))
        let second = try XCTUnwrap(sample("识别完成 · UID：alice（ax_header） 总耗时：1,234 ms AI 客服处理状态 最近一次处理完成"))
        var tracker = OCRProgressTracker(uid: "alice", baseline: first)
        XCTAssertNil(tracker.observe(second))
    }
    func testChangedElapsedCapturesFastScanEvenIfRunningStepWasMissed() throws {
        let first = try XCTUnwrap(sample("识别完成 · 没有新消息 · UID：alice（ax_header） 总耗时：1,234 ms"))
        let second = try XCTUnwrap(sample("识别完成 · 没有新消息 · UID：alice（ax_header） 总耗时：1,456 ms"))
        var tracker = OCRProgressTracker(uid: "alice", baseline: first)
        XCTAssertTrue(try XCTUnwrap(tracker.observe(second)).noNewMessages)
    }
    func testNilBaselineDoesNotAcceptAlreadyFinishedUI() throws {
        var tracker = OCRProgressTracker(uid: "alice", baseline: nil)
        XCTAssertNil(tracker.observe(try XCTUnwrap(sample("识别完成 · 没有新消息 · UID：alice（ax_header） 总耗时：45 ms"))))
    }
    func testNewPermissionErrorIsObservedNotSuccess() throws {
        var tracker = OCRProgressTracker(uid: "alice", baseline: sample("准备就绪"))
        let step = try XCTUnwrap(tracker.observe(try XCTUnwrap(sample("需要开启辅助功能权限"))))
        XCTAssertTrue(step.isTerminal)
        XCTAssertFalse(step.noNewMessages)
        XCTAssertTrue(step.isError)
    }
    func testQueueExportFailureWithoutUIDIsAnErrorNotATimeout() throws {
        var tracker = OCRProgressTracker(uid: "alice", baseline: sample("准备就绪"))
        let step = try XCTUnwrap(tracker.observe(try XCTUnwrap(sample("识别完成，但队列更新失败：磁盘不可写"))))
        XCTAssertTrue(step.isError)
        XCTAssertTrue(step.isTerminal)
        XCTAssertFalse(step.noNewMessages)
    }
    func testUsernameContainingNoNewPhraseDoesNotClaimNoQueueWork() throws {
        var tracker = OCRProgressTracker(uid: "客户没有新消息", baseline: sample("准备就绪"))
        let step = try XCTUnwrap(tracker.observe(try XCTUnwrap(sample("识别完成 · UID：客户没有新消息（ax_header） 总耗时：50 ms"))))
        XCTAssertFalse(step.noNewMessages)
    }
    func testTransitionalTextWithEnabledButtonIsNeverATerminalError() throws {
        var tracker = OCRProgressTracker(uid: "alice", baseline: sample("准备就绪"))
        if let observed = sample("正在识别文字…", enabled: true) {
            XCTAssertFalse(tracker.observe(observed)?.isTerminal ?? false)
        }
        XCTAssertFalse(tracker.finished)
    }
}
