import XCTest
import Combine
import UnreadCore
@testable import UnreadApp

final class ProgressDisplayTests: XCTestCase {
    @MainActor func model() -> ProgressDisplayModel {
        ProgressDisplayModel(root: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString))
    }
    @MainActor func testRepeatedStatusIsNotAppendedAndNewRunClearsLocalTimeline() {
        let value = model()
        value.beginRun()
        value.record("检查列表")
        value.record("检查列表")
        XCTAssertEqual(value.localEvents.filter { $0.title == "检查列表" }.count, 1)
        value.beginRun()
        XCTAssertFalse(value.localEvents.contains { $0.title == "检查列表" })
    }
    @MainActor func testNoTargetStopsLocalActivityWithoutInventingAQueueTask() {
        let value = model()
        value.beginRun()
        value.finishLookup(noTarget: true)
        XCTAssertFalse(value.isAutomationActive)
        XCTAssertTrue(value.tasks.isEmpty)
        XCTAssertTrue(value.localHeadline.contains("未触发"))
    }
    @MainActor func testNewOCRNoMessagesStopsRatherThanGeneratingForever() throws {
        let value = model()
        value.beginRun()
        value.arm(uid: "alice", baseline: OCRStatusSample(texts: ["准备就绪"], recognitionButtonEnabled: true))
        value.finishLookup(noTarget: false)
        value.receiveOCR(try XCTUnwrap(OCRStatusSample(texts: ["识别完成 · 没有新消息 · UID：alice（ax_header） 总耗时：30 ms"], recognitionButtonEnabled: true)))
        XCTAssertFalse(value.isAutomationActive)
        XCTAssertTrue(value.localHeadline.contains("未入队"))
    }
    @MainActor func testDeliveredTaskMayStillHoldCleanupSlotWithoutAppearingToSendAgain() {
        let value = model()
        let task = ProgressTask(id: "a", uid: "alice", stage: "发送器确认成功", events: [], isTerminal: true, cliActive: true)
        value.apply(ProgressSnapshot(tasks: [task], warnings: [], activeCLICount: 1))
        XCTAssertEqual(value.tasks.first?.stage, "发送器确认成功")
        XCTAssertEqual(value.activeCLICount, 1)
        XCTAssertTrue(value.isAutomationActive)
        XCTAssertTrue(value.headline.contains("发送器确认成功"))
    }
    @MainActor func testFailureEndsLookupButDoesNotRemoveOtherCustomerWork() {
        let value = model()
        value.apply(ProgressSnapshot(tasks: [ProgressTask(id: "b", uid: "bob", stage: "生成中", events: [], isTerminal: false, cliActive: true)], warnings: [], activeCLICount: 1))
        value.beginRun()
        value.failLookup("权限不足")
        XCTAssertEqual(value.tasks.map(\.uid), ["bob"])
        XCTAssertTrue(value.isAutomationActive)
        XCTAssertTrue(value.localHeadline.contains("权限不足"))
    }
    @MainActor func testFailedTaskWithLiveCleanupDoesNotClaimReplyWasHandedOff() {
        let value = model()
        value.apply(ProgressSnapshot(tasks: [ProgressTask(id: "f", uid: "失败客户", stage: "生成失败", events: [], isTerminal: true, cliActive: true)], warnings: [], activeCLICount: 1))
        XCTAssertTrue(value.headline.contains("生成失败"))
        XCTAssertFalse(value.headline.contains("回复已交接"))
    }
    @MainActor func testTerminalResultIsVisibleInCollapsedHeadline() {
        let value = model()
        value.beginRun()
        value.finishLookup(noTarget: true)
        value.apply(ProgressSnapshot(tasks: [ProgressTask(id: "done", uid: "alice", stage: "发送成功", events: [ProgressEvent(id: "e", date: Date().addingTimeInterval(1), title: "发送成功", detail: "")], isTerminal: true, cliActive: false)], warnings: [], activeCLICount: 0))
        value.collapsed = true
        XCTAssertTrue(value.headline.contains("发送成功"))
    }
    @MainActor func testSameSecondTerminalTimestampStillShowsResult() {
        let value = model()
        value.beginRun()
        value.finishLookup(noTarget: true)
        let second = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        value.apply(ProgressSnapshot(tasks: [ProgressTask(id: "done", uid: "alice", stage: "发送成功", events: [ProgressEvent(id: "e", date: second, title: "发送成功", detail: "")], isTerminal: true, cliActive: false)], warnings: [], activeCLICount: 0))
        XCTAssertTrue(value.headline.contains("发送成功"))
    }
    @MainActor func testOverlayIsClickThroughUntilFirstFreshSnapshot() {
        let value = model()
        XCTAssertTrue(value.isOverlayReadOnly)
        value.apply(ProgressSnapshot(tasks: [], warnings: [], activeCLICount: 0))
        XCTAssertFalse(value.isOverlayReadOnly)
    }
    @MainActor func testUnchangedPollDoesNotRebuildUIOrAccessibilityTree() {
        let value = model()
        let snapshot = ProgressSnapshot(tasks: [], warnings: [], activeCLICount: 0)
        value.apply(snapshot)
        var updates = 0
        let observation = value.objectWillChange.sink { updates += 1 }
        value.apply(snapshot)
        XCTAssertEqual(updates, 0)
        withExtendedLifetime(observation) {}
    }
    @MainActor func testUnreadableRootDoesNotUnlockOverlayAsIfIdle() {
        let value = model()
        value.apply(ProgressSnapshot(tasks: [], warnings: ["进度目录不可读；状态未知，不能据此判断完成。"], activeCLICount: 0))
        XCTAssertTrue(value.isOverlayReadOnly)
    }
}
