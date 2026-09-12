import Foundation
import XCTest
@testable import QianniuSenderCore

final class SenderWorkerTests: XCTestCase {
    func testWorkerStopsAfterUncertainOutcomeAndLeavesLaterTasksPending() async throws {
        let root = try makeRoot()
        let store = try SenderQueueStore(root: root)
        try writeTask(root: root, taskID: "sent", uid: "u1", createdAt: "2026-08-24T10:00:01Z")
        try writeTask(root: root, taskID: "failed", uid: "u2", createdAt: "2026-08-24T10:00:02Z")
        try writeTask(root: root, taskID: "uncertain", uid: "u3", createdAt: "2026-08-24T10:00:03Z")
        try writeTask(root: root, taskID: "later", uid: "u4", createdAt: "2026-08-24T10:00:04Z")
        let sender = ScriptedSender(outcomes: [
            "u1": .sent,
            "u2": .failedBeforeSend("找不到用户"),
            "u3": .uncertainAfterSend("无法确认回执"),
            "u4": .sent,
        ])
        let worker = SenderWorker(store: store, sender: sender, now: { "2026-08-24T10:00:10Z" })

        let summary = await worker.runUntilDrained()

        XCTAssertEqual(summary.total, 3)
        XCTAssertEqual(summary.sent, 1)
        XCTAssertEqual(summary.failedBeforeSend, 1)
        XCTAssertEqual(summary.uncertainAfterSend, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("已完成/u1/sent.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("发送失败/failed.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("待人工确认/uncertain.json").path))
        XCTAssertEqual(try store.snapshot().map(\.taskID), ["later"])
    }

    func testWorkerProcessesTaskQueuedDuringCurrentRun() async throws {
        let root = try makeRoot()
        let store = try SenderQueueStore(root: root)
        try writeTask(root: root, taskID: "first", uid: "u1", createdAt: "2026-08-24T10:00:01Z")
        let sender = EnqueuingSender(root: root)
        let worker = SenderWorker(store: store, sender: sender, now: { "2026-08-24T10:00:10Z" })

        let summary = await worker.runUntilDrained()

        XCTAssertEqual(summary.total, 2)
        XCTAssertEqual(summary.sent, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("已完成/u2/second.json").path))
    }

    func testSecondWorkerCannotSendWhileFirstOwnsLock() async throws {
        let root = try makeRoot()
        let store = try SenderQueueStore(root: root)
        try writeTask(root: root, taskID: "one", uid: "u1", createdAt: "2026-08-24T10:00:01Z")
        let sender = DelayedSender()
        let first = SenderWorker(store: store, sender: sender, now: { "2026-08-24T10:00:10Z" })
        let second = SenderWorker(store: store, sender: sender, now: { "2026-08-24T10:00:10Z" })

        async let firstSummary = first.runUntilDrained()
        await sender.waitUntilStarted()
        let secondSummary = await second.runUntilDrained()
        await sender.release()
        _ = await firstSummary

        XCTAssertTrue(secondSummary.skippedBecauseAlreadyRunning)
        let sendCount = await sender.currentSendCount()
        XCTAssertEqual(sendCount, 1)
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sender-worker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}

private actor ScriptedSender: MessageSending {
    let outcomes: [String: SendOutcome]
    init(outcomes: [String: SendOutcome]) { self.outcomes = outcomes }
    func send(uid: String, text: String, attemptMarkerURL: URL?) async -> SendOutcome {
        outcomes[uid] ?? .failedBeforeSend("没有测试结果")
    }
}

private actor EnqueuingSender: MessageSending {
    let root: URL
    var didEnqueue = false
    init(root: URL) { self.root = root }
    func send(uid: String, text: String, attemptMarkerURL: URL?) async -> SendOutcome {
        if !didEnqueue {
            didEnqueue = true
            try? writeTask(root: root, taskID: "second", uid: "u2", createdAt: "2026-08-24T10:00:02Z")
        }
        return .sent
    }
}

private actor DelayedSender: MessageSending {
    private var started = false
    private var released = false
    private(set) var sendCount = 0

    func send(uid: String, text: String, attemptMarkerURL: URL?) async -> SendOutcome {
        sendCount += 1
        started = true
        while !released { await Task.yield() }
        return .sent
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func release() { released = true }
    func currentSendCount() -> Int { sendCount }
}

private func writeTask(root: URL, taskID: String, uid: String, createdAt: String) throws {
    let pending = root.appendingPathComponent("待发送", isDirectory: true)
    try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
    let object: [String: Any] = [
        "schema_version": 1,
        "task_id": taskID,
        "uid": uid,
        "source_history_version": "v1",
        "source_task": root.appendingPathComponent("处理中/\(taskID).json").path,
        "decision": "auto_send",
        "risk_level": "low",
        "reply_text": "测试回复",
        "reason": "测试",
        "created_at": createdAt,
    ]
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: pending.appendingPathComponent("\(taskID).json"))
}
