import Foundation
import XCTest
@testable import AutoReplyApp

final class VideoDownloadMonitorTests: XCTestCase {
    func testPersistsMessageIdentityAndCompletionAcrossMonitorRestart() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("video-download-monitor.json")
        let startedAt = Date(timeIntervalSince1970: 1_788_200_000)
        let completedAt = Date(timeIntervalSince1970: 1_788_200_009)
        let fileURL = root.appendingPathComponent("received.mp4")
        let monitor = VideoDownloadMonitor(storeURL: storeURL)

        try await monitor.markStarted(messageID: "VIDEO.PERSIST", at: startedAt)
        try await monitor.markCompleted(
            messageID: "VIDEO.PERSIST",
            startedAt: startedAt,
            completedAt: completedAt,
            fileURL: fileURL,
            bytes: 4_096
        )

        let restarted = VideoDownloadMonitor(storeURL: storeURL)
        let record = try await restarted.record(messageID: "VIDEO.PERSIST")
        XCTAssertEqual(record?.messageID, "VIDEO.PERSIST")
        XCTAssertEqual(record?.startedAt, startedAt)
        XCTAssertEqual(record?.completedAt, completedAt)
        XCTAssertEqual(record?.filePath, fileURL.path)
        XCTAssertEqual(record?.bytes, 4_096)
    }
}
