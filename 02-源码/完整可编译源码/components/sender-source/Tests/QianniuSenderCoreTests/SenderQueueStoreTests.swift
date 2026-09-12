import Foundation
import XCTest
@testable import QianniuSenderCore

final class SenderQueueStoreTests: XCTestCase {
    func testSnapshotSortsFIFOAndClaimMovesOnlyTheSelectedTask() throws {
        let root = try makeRoot()
        let store = try SenderQueueStore(root: root)
        try writeTask(root: root, taskID: "later", uid: "u2", createdAt: "2026-08-24T10:00:02Z")
        try writeTask(root: root, taskID: "earlier", uid: "u1", createdAt: "2026-08-24T10:00:01Z")

        let snapshot = try store.snapshot()
        let claimed = try store.claim(snapshot[0])

        XCTAssertEqual(snapshot.map(\.taskID), ["earlier", "later"])
        XCTAssertEqual(claimed.task.taskID, "earlier")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("待发送/earlier.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("发送中/earlier.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("待发送/later.json").path))
    }

    func testCompleteArchivesReplyAndRemovesProcessingClaim() throws {
        let root = try makeRoot()
        let store = try SenderQueueStore(root: root)
        try writeTask(root: root, taskID: "task-1", uid: "user-1", createdAt: "2026-08-24T10:00:01Z")
        let batchClaim = root.appendingPathComponent("处理中/task-1.json")
        try FileManager.default.createDirectory(at: batchClaim.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: batchClaim)
        let claimed = try store.claim(try XCTUnwrap(store.snapshot().first))

        try store.complete(claimed, sentAt: "2026-08-24T10:00:03Z")

        let completed = root.appendingPathComponent("已完成/user-1/task-1.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: completed.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: claimed.claimURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: batchClaim.path))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: completed)) as? [String: Any])
        XCTAssertEqual(object["sent_at"] as? String, "2026-08-24T10:00:03Z")
        XCTAssertEqual(object["reply_text"] as? String, "测试回复")
    }

    func testFailureBeforeSendAndUncertainAfterSendUseDifferentDirectories() throws {
        let root = try makeRoot()
        let store = try SenderQueueStore(root: root)
        try writeTask(root: root, taskID: "fail", uid: "u1", createdAt: "2026-08-24T10:00:01Z")
        var claimed = try store.claim(try XCTUnwrap(store.snapshot().first))
        try store.failBeforeSend(claimed, reason: "找不到用户", failedAt: "2026-08-24T10:00:02Z")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("发送失败/fail.json").path))

        try writeTask(root: root, taskID: "uncertain", uid: "u2", createdAt: "2026-08-24T10:00:03Z")
        claimed = try store.claim(try XCTUnwrap(store.snapshot().first))
        try store.markUncertain(claimed, reason: "发送后无法确认", attemptedAt: "2026-08-24T10:00:04Z")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("待人工确认/uncertain.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("待发送/uncertain.json").path))
    }

    func testSnapshotRejectsNonAutoSendTask() throws {
        let root = try makeRoot()
        _ = try SenderQueueStore(root: root)
        try writeTask(root: root, taskID: "review", uid: "u1", createdAt: "2026-08-24T10:00:01Z", decision: "human_review")

        XCTAssertThrowsError(try SenderQueueStore(root: root).snapshot()) { error in
            XCTAssertTrue(error.localizedDescription.contains("auto_send"))
        }
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sender-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func writeTask(
        root: URL,
        taskID: String,
        uid: String,
        createdAt: String,
        decision: String = "auto_send"
    ) throws {
        let pending = root.appendingPathComponent("待发送", isDirectory: true)
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        let object: [String: Any] = [
            "schema_version": 1,
            "task_id": taskID,
            "uid": uid,
            "source_history_version": "v1",
            "source_task": root.appendingPathComponent("处理中/\(taskID).json").path,
            "decision": decision,
            "risk_level": "low",
            "reply_text": "测试回复",
            "reason": "测试",
            "created_at": createdAt,
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: pending.appendingPathComponent("\(taskID).json"))
    }
}
