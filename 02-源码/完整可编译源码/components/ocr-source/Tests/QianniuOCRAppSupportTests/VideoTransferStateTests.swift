import CryptoKit
import Foundation
import XCTest
@testable import QianniuOCRAppSupport

final class VideoTransferStateTests: XCTestCase {
    func testWaitingRetrySurvivesRelaunchAndBecomesDue() async throws {
        let fixture = try StateFixture()
        defer { fixture.remove() }
        let start = Date(timeIntervalSince1970: 1_788_100_000)
        let key = fixture.key(customerUID: "buyer-a", messageHash: "message-hash")
        let store = DurableVideoTransferStore(url: fixture.stateURL, now: { start })

        _ = try await store.beginOrRead(key: key, customerUID: "buyer-a")
        try await store.transition(key, to: .opening)
        try await store.transition(
            key,
            to: .waitingForRetry,
            failure: .connectTimeout,
            nextAttemptAt: start.addingTimeInterval(60)
        )

        let restored = DurableVideoTransferStore(
            url: fixture.stateURL,
            now: { start.addingTimeInterval(61) }
        )
        let due = try await restored.dueRecords()

        XCTAssertEqual(due.map(\.key), [key])
        XCTAssertEqual(due.first?.customerUID, "buyer-a")
        XCTAssertEqual(due.first?.failure, .connectTimeout)
    }

    func testActiveLeasePreventsDuplicateClaimAndExpiredLeaseCanBeReclaimed() async throws {
        let fixture = try StateFixture()
        defer { fixture.remove() }
        let clock = LockedTestNow(Date(timeIntervalSince1970: 1_788_100_100))
        let key = fixture.key(customerUID: "buyer-a", messageHash: "message-hash")
        let store = DurableVideoTransferStore(url: fixture.stateURL, now: { clock.value })
        _ = try await store.beginOrRead(key: key, customerUID: "buyer-a")

        let firstClaim = try await store.claimLease(key, duration: 60)
        let duplicateClaim = try await store.claimLease(key, duration: 60)
        clock.advance(by: 61)
        let reclaimed = try await store.claimLease(key, duration: 60)

        XCTAssertTrue(firstClaim)
        XCTAssertFalse(duplicateClaim)
        XCTAssertTrue(reclaimed)
    }

    func testBindingCustomerUIDRequiresMatchingHash() async throws {
        let fixture = try StateFixture()
        defer { fixture.remove() }
        let key = fixture.key(customerUID: "buyer-a", messageHash: "message-hash")
        try fixture.writeLegacyRecords(
            downloadRecords: [
                .init(messageHash: key.messageHash, phase: "failed", fileName: nil)
            ],
            processedEntries: [
                .init(messageHash: key.messageHash, customerHash: key.customerHash, type: "video")
            ]
        )
        let store = DurableVideoTransferStore(url: fixture.stateURL)
        try await store.migrateLegacyJournals(
            downloadURL: fixture.legacyDownloadURL,
            processedURL: fixture.legacyProcessedURL
        )

        await XCTAssertThrowsErrorAsync {
            try await store.bindCustomerUID("buyer-b", to: key)
        }
        try await store.bindCustomerUID("buyer-a", to: key)

        let record = try await store.record(key)
        XCTAssertEqual(record?.customerUID, "buyer-a")
    }

    func testLegacyFailureAndDownloadMigrateWithoutInventingCustomerUID() async throws {
        let fixture = try StateFixture()
        defer { fixture.remove() }
        let failed = fixture.key(customerUID: "buyer-a", messageHash: "failed-hash")
        let downloaded = fixture.key(customerUID: "buyer-b", messageHash: "downloaded-hash")
        try fixture.writeLegacyRecords(
            downloadRecords: [
                .init(messageHash: failed.messageHash, phase: "failed", fileName: nil),
                .init(messageHash: downloaded.messageHash, phase: "downloaded", fileName: "downloaded-hash.mp4")
            ],
            processedEntries: [
                .init(messageHash: failed.messageHash, customerHash: failed.customerHash, type: "video"),
                .init(messageHash: downloaded.messageHash, customerHash: downloaded.customerHash, type: "video")
            ]
        )
        let now = Date(timeIntervalSince1970: 1_788_100_200)
        let store = DurableVideoTransferStore(url: fixture.stateURL, now: { now })

        try await store.migrateLegacyJournals(
            downloadURL: fixture.legacyDownloadURL,
            processedURL: fixture.legacyProcessedURL
        )
        let records = try await store.recordsByMessageHash()

        XCTAssertEqual(records[failed.messageHash]?.phase, .waitingForRetry)
        XCTAssertEqual(records[failed.messageHash]?.nextAttemptAt, now)
        XCTAssertNil(records[failed.messageHash]?.customerUID)
        XCTAssertEqual(records[downloaded.messageHash]?.phase, .downloaded)
        XCTAssertEqual(records[downloaded.messageHash]?.fileName, "downloaded-hash.mp4")
        XCTAssertNil(records[downloaded.messageHash]?.customerUID)
    }

    func testStateFileContainsNoMessageIDOrSignedURL() async throws {
        let fixture = try StateFixture()
        defer { fixture.remove() }
        let rawMessageID = "VIDEO.RAW.SECRET"
        let messageHash = StateFixture.sha256(rawMessageID)
        let key = fixture.key(customerUID: "buyer-a", messageHash: messageHash)
        let store = DurableVideoTransferStore(url: fixture.stateURL)

        _ = try await store.beginOrRead(key: key, customerUID: "buyer-a")
        try await store.transition(key, to: .waitingForRetry, failure: .connectTimeout)

        let stored = try String(contentsOf: fixture.stateURL, encoding: .utf8)
        XCTAssertFalse(stored.contains(rawMessageID))
        XCTAssertFalse(stored.contains("https://"))
        XCTAssertFalse(stored.contains("auth_key"))
        XCTAssertTrue(stored.contains(messageHash))
    }
}

private struct StateFixture {
    struct LegacyDownload {
        let messageHash: String
        let phase: String
        let fileName: String?
    }

    struct LegacyProcessed {
        let messageHash: String
        let customerHash: String
        let type: String
    }

    let root: URL
    let stateURL: URL
    let legacyDownloadURL: URL
    let legacyProcessedURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        stateURL = root.appendingPathComponent("video-transfer-state.json")
        legacyDownloadURL = root.appendingPathComponent("video-downloads.json")
        legacyProcessedURL = root.appendingPathComponent("processed-events.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func key(customerUID: String, messageHash: String) -> VideoTransferKey {
        VideoTransferKey(customerHash: Self.sha256(customerUID), messageHash: messageHash)
    }

    func writeLegacyRecords(
        downloadRecords: [LegacyDownload],
        processedEntries: [LegacyProcessed]
    ) throws {
        let downloadObjects: [[String: Any]] = downloadRecords.map { record in
            var value: [String: Any] = [
                "messageHash": record.messageHash,
                "phase": record.phase,
                "updatedAt": "2026-09-02T12:00:00Z"
            ]
            if let fileName = record.fileName { value["fileName"] = fileName }
            return value
        }
        let processedObjects: [[String: Any]] = processedEntries.map { entry in
            [
                "messageHash": entry.messageHash,
                "customerHash": entry.customerHash,
                "type": entry.type,
                "processedAt": 810_000_000.0
            ]
        }
        let downloads: [String: Any] = ["schemaVersion": 1, "records": downloadObjects]
        let processed: [String: Any] = ["schemaVersion": 1, "entries": processedObjects]
        try JSONSerialization.data(withJSONObject: downloads, options: [.sortedKeys])
            .write(to: legacyDownloadURL, options: .atomic)
        try JSONSerialization.data(withJSONObject: processed, options: [.sortedKeys])
            .write(to: legacyProcessedURL, options: .atomic)
    }

    static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        // Expected.
    }
}

private final class LockedTestNow: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Date

    init(_ value: Date) {
        stored = value
    }

    var value: Date {
        lock.withLock { stored }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { stored = stored.addingTimeInterval(interval) }
    }
}
