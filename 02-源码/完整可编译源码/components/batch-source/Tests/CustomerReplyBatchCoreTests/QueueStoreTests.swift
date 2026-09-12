import XCTest
@testable import CustomerReplyBatchCore

final class QueueStoreTests: XCTestCase {
    func testSecondBatchCannotAcquireLockUntilFirstReleases() throws {
        let store = try makeStore()
        var first: BatchLock? = try store.acquireBatchLock()
        XCTAssertNotNil(first)
        XCTAssertThrowsError(try store.acquireBatchLock())
        first = nil
        XCTAssertNoThrow(try store.acquireBatchLock())
    }

    func testClaimMovesPendingAndNewerPointerSurvivesPublishingOlderReply() throws {
        let store = try makeStore()
        let old = QueuePointer(uid: "u1", userDirectory: "/tmp/u1", historyVersion: "v1", queuedAt: "2026-08-24T10:00:00Z")
        try store.writePending(old)
        let claimed = try store.claim(try XCTUnwrap(QueueSnapshot.load(from: store.layout.pending).first))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.layout.pending.appendingPathComponent("u1.json").path))

        let newer = QueuePointer(uid: "u1", userDirectory: "/tmp/u1", historyVersion: "v2", queuedAt: "2026-08-24T10:01:00Z")
        try store.writePending(newer)
        let reply = ReplyEnvelope(decision: .autoSend, riskLevel: .low, replyText: "您好", reason: "普通咨询")
        let output = try store.publish(reply, for: claimed)

        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.layout.pending.appendingPathComponent("u1.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: claimed.claimURL.path))
    }

    func testRecoverStaleClaimMovesItBackToPendingWhenNoOutputExists() throws {
        let store = try makeStore()
        let pointer = QueuePointer(uid: "u1", userDirectory: "/tmp/u1", historyVersion: "v1", queuedAt: "2026-08-24T10:00:00Z")
        try store.writePending(pointer)
        let claim = try store.claim(try XCTUnwrap(QueueSnapshot.load(from: store.layout.pending).first))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3_600)], ofItemAtPath: claim.claimURL.path)

        let recovered = try store.recoverStaleClaims(olderThan: 1_800)

        XCTAssertEqual(recovered, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.layout.pending.appendingPathComponent("u1.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: claim.claimURL.path))
    }

    func testPublishAlsoWritesMachineAndHumanReadableTestingReplies() throws {
        let store = try makeStore()
        let pointer = QueuePointer(
            uid: "customer-1",
            userDirectory: "/tmp/customer-1",
            historyVersion: "v1",
            queuedAt: "2026-08-24T10:00:00Z"
        )
        try store.writePending(pointer)
        let claimed = try store.claim(
            try XCTUnwrap(QueueSnapshot.load(from: store.layout.pending).first)
        )
        let reply = ReplyEnvelope(
            decision: .autoSend,
            riskLevel: .low,
            replyText: "您好，请先安装对应系统的打印机驱动。",
            reason: "知识库中有对应安装流程"
        )

        _ = try store.publish(reply, for: claimed, now: Date(timeIntervalSince1970: 0))

        let directory = store.layout.testReplies
            .appendingPathComponent("customer-1", isDirectory: true)
        let json = directory.appendingPathComponent("\(claimed.taskID).json")
        let text = directory.appendingPathComponent("\(claimed.taskID).txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: json.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: text.path))
        let readable = try String(contentsOf: text, encoding: .utf8)
        XCTAssertTrue(readable.contains("您好，请先安装对应系统的打印机驱动。"))
        XCTAssertTrue(readable.contains("知识库中有对应安装流程"))
        XCTAssertTrue(readable.contains("仅供测试，尚未发送"))
    }

    private func makeStore() throws -> QueueStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try QueueStore(root: root)
    }
}
