import XCTest
@testable import CustomerReplyBatchCore

final class QueueSnapshotTests: XCTestCase {
    func testSnapshotSortsByFirstQueuedAtThenUIDAndFallsBackToQueuedAt() throws {
        let root = try temporaryDirectory()
        try writePointer(root: root, uid: "c", first: "2026-08-24T10:00:00Z", queued: nil)
        try writePointer(root: root, uid: "b", first: nil, queued: "2026-08-24T09:00:00Z")
        try writePointer(root: root, uid: "a", first: "2026-08-24T10:00:00Z", queued: nil)

        let tasks = try QueueSnapshot.load(from: root)

        XCTAssertEqual(tasks.map(\.uid), ["b", "a", "c"])
    }

    func testTaskIdentityIsStableAndChangesWithVersion() {
        let first = TaskIdentity.make(uid: "u1", historyVersion: "v1")
        XCTAssertEqual(first, TaskIdentity.make(uid: "u1", historyVersion: "v1"))
        XCTAssertNotEqual(first, TaskIdentity.make(uid: "u1", historyVersion: "v2"))
        XCTAssertEqual(first.count, 64)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func writePointer(root: URL, uid: String, first: String?, queued: String?) throws {
        var value: [String: Any] = [
            "uid": uid,
            "user_directory": "/tmp/\(uid)",
            "history_version": "v1"
        ]
        value["first_queued_at"] = first
        value["queued_at"] = queued
        let data = try JSONSerialization.data(withJSONObject: value)
        try data.write(to: root.appendingPathComponent("\(uid).json"))
    }
}
