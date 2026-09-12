import XCTest
@testable import AutoReplyApp
import AutoReplyCore
import QianniuOCRAppSupport

private actor VideoEventAdmissionRecorder {
    private(set) var prepared: [String] = []
    private(set) var discoveries: [String] = []

    func admitPrepared(revision: String) -> PreparedReplyAdmission {
        guard !prepared.contains(revision) else { return .alreadyPresent }
        prepared.append(revision)
        return .inserted
    }

    func admitDiscovery(revision: String) -> Bool {
        guard !discoveries.contains(revision) else { return false }
        discoveries.append(revision)
        return true
    }
}

private actor DownloadedReceiptRecorder {
    private(set) var hashes: [String] = []
    func receive(_ receipt: DownloadedCustomerVideo) { hashes.append(receipt.messageHash) }
}

private actor VideoSnapshotAdmissionRecorder {
    private(set) var snapshots: [CaptureSnapshot] = []
    func admit(_ snapshot: CaptureSnapshot) { snapshots.append(snapshot) }
}

private struct StubVideoEvidencePreparer: CustomerVideoEvidencePreparing {
    let rootURL: URL

    func prepare(receipt: DownloadedCustomerVideo) async throws -> CustomerVideoEvidenceManifest {
        let directory = rootURL.appendingPathComponent(receipt.messageHash, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("frame".utf8).write(to: directory.appendingPathComponent("frame-01.jpg"))
        return CustomerVideoEvidenceManifest(
            schemaVersion: 2,
            messageHash: receipt.messageHash,
            durationSeconds: 1,
            width: 100,
            height: 100,
            frames: [CustomerVideoFrame(timestampSeconds: 0.5, fileName: "frame-01.jpg", sha256: "hash")],
            audioFileName: nil,
            transcript: [VideoTranscriptSegment(startSeconds: 0, durationSeconds: 1, text: "机器不转了")]
        )
    }
}

final class VideoAnalysisInboxTests: XCTestCase {
    func testInboxRejectsSameCustomerVideoContentUnderDifferentMessageHashes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let firstFile = root.appendingPathComponent("first.mp4")
        let secondFile = root.appendingPathComponent("second.mp4")
        let identicalVideoBytes = Data("same downloaded video bytes".utf8)
        try identicalVideoBytes.write(to: firstFile)
        try identicalVideoBytes.write(to: secondFile)
        let inbox = VideoAnalysisInbox(stateURL: root.appendingPathComponent("inbox.json"))

        let firstInserted = try await inbox.enqueue(DownloadedCustomerVideo(
            customerUID: "buyer-a", messageHash: "message-id-hash-one",
            fileURL: firstFile, bytes: Int64(identicalVideoBytes.count), completedAt: Date()
        ))
        let duplicateInserted = try await inbox.enqueue(DownloadedCustomerVideo(
            customerUID: "buyer-a", messageHash: "message-id-hash-two",
            fileURL: secondFile, bytes: Int64(identicalVideoBytes.count), completedAt: Date()
        ))

        let messageHashes = try await inbox.entries().map(\.messageHash)
        XCTAssertTrue(firstInserted)
        XCTAssertFalse(duplicateInserted)
        XCTAssertEqual(messageHashes, ["message-id-hash-one"])
    }

    func testInboxAllowsDifferentCustomersToSendSameVideoContent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let firstFile = root.appendingPathComponent("first.mp4")
        let secondFile = root.appendingPathComponent("second.mp4")
        let identicalVideoBytes = Data("same downloaded video bytes".utf8)
        try identicalVideoBytes.write(to: firstFile)
        try identicalVideoBytes.write(to: secondFile)
        let inbox = VideoAnalysisInbox(stateURL: root.appendingPathComponent("inbox.json"))

        let firstInserted = try await inbox.enqueue(DownloadedCustomerVideo(
            customerUID: "buyer-a", messageHash: "message-id-hash-one",
            fileURL: firstFile, bytes: Int64(identicalVideoBytes.count), completedAt: Date()
        ))
        let secondInserted = try await inbox.enqueue(DownloadedCustomerVideo(
            customerUID: "buyer-b", messageHash: "message-id-hash-two",
            fileURL: secondFile, bytes: Int64(identicalVideoBytes.count), completedAt: Date()
        ))

        let entryCount = try await inbox.entries().count
        XCTAssertTrue(firstInserted)
        XCTAssertTrue(secondInserted)
        XCTAssertEqual(entryCount, 2)
    }

    func testInboxBackfillsContentHashForLegacyEntryBeforeRejectingDuplicate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacyFile = root.appendingPathComponent("legacy.mp4")
        let duplicateFile = root.appendingPathComponent("duplicate.mp4")
        let identicalVideoBytes = Data("legacy downloaded video bytes".utf8)
        try identicalVideoBytes.write(to: legacyFile)
        try identicalVideoBytes.write(to: duplicateFile)
        let state = root.appendingPathComponent("inbox.json")
        let legacyPayload = """
        {"schemaVersion":1,"entries":[{"customerUID":"buyer-a","messageHash":"legacy-message-hash","videoFilePath":"\(legacyFile.path)","bytes":\(identicalVideoBytes.count),"phase":"completed","attempts":1,"updatedAt":"1970-01-01T00:01:40Z","failure":null}]}
        """
        try Data(legacyPayload.utf8).write(to: state)
        let inbox = VideoAnalysisInbox(stateURL: state)

        let duplicateInserted = try await inbox.enqueue(DownloadedCustomerVideo(
            customerUID: "buyer-a", messageHash: "new-message-hash",
            fileURL: duplicateFile, bytes: Int64(identicalVideoBytes.count), completedAt: Date()
        ))

        let entries = try await inbox.entries()
        XCTAssertFalse(duplicateInserted)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.contentSHA256?.count, 64)
    }

    func testReceiptArrivingBeforePipelineInstallationIsBuffered() async {
        let relay = VideoReceiptRelay()
        let recorder = DownloadedReceiptRecorder()
        let receipt = DownloadedCustomerVideo(
            customerUID: "buyer-a", messageHash: "early-video",
            fileURL: URL(fileURLWithPath: "/tmp/early-video.mp4"), bytes: 1,
            completedAt: Date()
        )

        await relay.receive(receipt)
        await relay.install { value in await recorder.receive(value) }

        let hashes = await recorder.hashes
        XCTAssertEqual(hashes, ["early-video"])
    }

    func testCoordinatorSubmitsDownloadedVideoToCodexExactlyOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let evidenceRoot = root.appendingPathComponent("evidence", isDirectory: true)
        let inbox = VideoAnalysisInbox(stateURL: root.appendingPathComponent("inbox.json"))
        let admissions = VideoSnapshotAdmissionRecorder()
        let coordinator = VideoAnalysisCoordinator(
            inbox: inbox,
            preparer: StubVideoEvidencePreparer(rootURL: evidenceRoot),
            evidenceRoot: evidenceRoot,
            knowledgeBasePaths: ["/kb.zip"],
            admit: { snapshot in await admissions.admit(snapshot) }
        )
        let receipt = DownloadedCustomerVideo(
            customerUID: "buyer-a",
            messageHash: "video-hash",
            fileURL: root.appendingPathComponent("video.mp4"),
            bytes: 123,
            completedAt: Date()
        )

        await coordinator.receive(receipt)
        await coordinator.receive(receipt)

        let snapshots = await admissions.snapshots
        let entries = try await inbox.entries()
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.uid, "buyer-a")
        XCTAssertEqual(snapshots.first?.customerRevision, "video-analysis:video-hash")
        XCTAssertEqual(snapshots.first?.imagePaths.count, 1)
        XCTAssertTrue(snapshots.first?.targetCustomerJSONL.contains("机器不转了") == true)
        XCTAssertEqual(snapshots.first?.promptInput.preservesHistoryCheckpoint, true)
        XCTAssertEqual(entries.first?.phase, .admitted)
    }

    func testImmediateFailureAdmitsTruthfulFallbackExactlyOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DurableVideoTransferStore(url: root.appendingPathComponent("transfers.json"))
        let key = VideoTransferKey(
            customerHash: VideoTransferIdentity.hash("buyer"),
            messageHash: "safe-hash"
        )
        _ = try await store.beginOrRead(key: key, customerUID: "buyer")
        try await store.transition(key, to: .waitingForRetry, failure: .connectTimeout)
        let admissions = VideoEventAdmissionRecorder()
        let downloads = DownloadedReceiptRecorder()
        let bridge = VideoTransferEventBridge(
            transferStore: store,
            admitPrepared: { _, revision, _, _ in await admissions.admitPrepared(revision: revision) },
            admitDiscovery: { _, revision in await admissions.admitDiscovery(revision: revision) },
            receiveDownloaded: { receipt in await downloads.receive(receipt) }
        )
        let event = VideoTransferEvent.immediateRoutesExhausted(VideoTransferFailureNotice(
            customerUID: "buyer", messageHash: "safe-hash", category: .connectTimeout
        ))

        await bridge.receive(event)
        await bridge.receive(event)

        let prepared = await admissions.prepared
        let stored = try await store.record(key)
        XCTAssertEqual(prepared, ["video-download-fallback:safe-hash"])
        XCTAssertEqual(stored?.fallbackAdmitted, true)
    }

    func testLaterDownloadAfterFallbackStillReachesEvidencePipeline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DurableVideoTransferStore(url: root.appendingPathComponent("transfers.json"))
        let key = VideoTransferKey(
            customerHash: VideoTransferIdentity.hash("buyer"),
            messageHash: "safe-hash"
        )
        _ = try await store.beginOrRead(key: key, customerUID: "buyer")
        try await store.transition(key, to: .waitingForRetry, failure: .connectTimeout)
        let admissions = VideoEventAdmissionRecorder()
        let downloads = DownloadedReceiptRecorder()
        let bridge = VideoTransferEventBridge(
            transferStore: store,
            admitPrepared: { _, revision, _, _ in await admissions.admitPrepared(revision: revision) },
            admitDiscovery: { _, revision in await admissions.admitDiscovery(revision: revision) },
            receiveDownloaded: { receipt in await downloads.receive(receipt) }
        )
        let receipt = DownloadedCustomerVideo(
            customerUID: "buyer", messageHash: "safe-hash",
            fileURL: root.appendingPathComponent("safe-hash.mp4"), bytes: 123,
            completedAt: Date()
        )

        await bridge.receive(.immediateRoutesExhausted(VideoTransferFailureNotice(
            customerUID: "buyer", messageHash: "safe-hash", category: .connectTimeout
        )))
        await bridge.receive(.downloaded(receipt))

        let prepared = await admissions.prepared
        let downloadedHashes = await downloads.hashes
        XCTAssertEqual(prepared, ["video-download-fallback:safe-hash"])
        XCTAssertEqual(downloadedHashes, ["safe-hash"])
    }

    func testFreshAddressRequestQueuesOneDiscoveryAndReleasesCoordinatorLease() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DurableVideoTransferStore(url: root.appendingPathComponent("transfers.json"))
        let key = VideoTransferKey(
            customerHash: VideoTransferIdentity.hash("buyer"),
            messageHash: "safe-hash"
        )
        _ = try await store.beginOrRead(key: key, customerUID: "buyer")
        try await store.transition(key, to: .waitingForRetry, failure: .connectTimeout)
        let claimed = try await store.claimLease(key)
        XCTAssertTrue(claimed)
        let admissions = VideoEventAdmissionRecorder()
        let downloads = DownloadedReceiptRecorder()
        let bridge = VideoTransferEventBridge(
            transferStore: store,
            admitPrepared: { _, revision, _, _ in await admissions.admitPrepared(revision: revision) },
            admitDiscovery: { _, revision in await admissions.admitDiscovery(revision: revision) },
            receiveDownloaded: { receipt in await downloads.receive(receipt) }
        )
        let event = VideoTransferEvent.freshAddressNeeded(VideoTransferFreshAddressRequest(
            customerUID: "buyer", messageHash: "safe-hash"
        ))

        await bridge.receive(event)
        await bridge.receive(event)

        let discoveries = await admissions.discoveries
        let stored = try await store.record(key)
        XCTAssertEqual(discoveries, ["video-address-refresh:safe-hash"])
        XCTAssertNil(stored?.leaseUntil)
    }

    func testInboxPersistsOneSanitizedReceiptAndRecoversPendingWork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("inbox.json")
        let receipt = DownloadedCustomerVideo(
            customerUID: "buyer-a", messageHash: "safe-hash",
            fileURL: root.appendingPathComponent("safe-hash.mp4"), bytes: 123,
            completedAt: Date(timeIntervalSince1970: 100)
        )
        let first = VideoAnalysisInbox(stateURL: state)
        try await first.enqueue(receipt)
        try await first.enqueue(receipt)

        let restored = try await VideoAnalysisInbox(stateURL: state).pendingReceipts()
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.customerUID, "buyer-a")
        XCTAssertFalse(try String(contentsOf: state).contains("messageId"))
        XCTAssertFalse(try String(contentsOf: state).contains("auth_key"))
    }

    func testSnapshotUsesOrderedFramesAndStableVideoRevision() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["one.jpg", "two.jpg"] { try Data(name.utf8).write(to: root.appendingPathComponent(name)) }
        let receipt = DownloadedCustomerVideo(customerUID: "buyer", messageHash: "hash", fileURL: root,
                                              bytes: 1, completedAt: Date())
        let manifest = CustomerVideoEvidenceManifest(
            schemaVersion: 1, messageHash: "hash", durationSeconds: 3, width: 100, height: 200,
            frames: [
                CustomerVideoFrame(timestampSeconds: 0.2, fileName: "one.jpg", sha256: "1"),
                CustomerVideoFrame(timestampSeconds: 2.8, fileName: "two.jpg", sha256: "2")
            ],
            audioFileName: "audio.m4a",
            transcript: [VideoTranscriptSegment(startSeconds: 0, durationSeconds: 1, text: "机器响了一声")]
        )

        let snapshot = try VideoAnalysisSnapshotFactory.make(
            receipt: receipt, manifest: manifest, evidenceRoot: root, knowledgeBasePaths: ["/kb.zip"]
        )

        XCTAssertEqual(snapshot.customerRevision, "video-analysis:hash")
        XCTAssertEqual(snapshot.imagePaths.map(URL.init(fileURLWithPath:)).map(\.lastPathComponent), ["one.jpg", "two.jpg"])
        XCTAssertTrue(snapshot.targetCustomerJSONL.contains("机器响了一声"))
    }

    func testFallbackAsksOneTruthfulClarifyingQuestionWithoutPretendingToSeeVideo() {
        let receipt = DownloadedCustomerVideo(
            customerUID: "buyer", messageHash: "hash",
            fileURL: URL(fileURLWithPath: "/missing.mp4"), bytes: 0, completedAt: Date()
        )

        let snapshot = VideoAnalysisSnapshotFactory.fallback(receipt: receipt, knowledgeBasePaths: [])

        XCTAssertTrue(snapshot.targetCustomerJSONL.contains("未能提取可靠画面或语音"))
        XCTAssertTrue(snapshot.targetCustomerJSONL.contains("请询问客户"))
        XCTAssertFalse(snapshot.targetCustomerJSONL.contains("视频已收到"))
    }

    func testCompletedAnalysisIsNotRecoveredAsPendingWork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = VideoAnalysisInbox(stateURL: root.appendingPathComponent("inbox.json"))
        let receipt = DownloadedCustomerVideo(
            customerUID: "buyer", messageHash: "safe-hash",
            fileURL: root.appendingPathComponent("safe-hash.mp4"), bytes: 123,
            completedAt: Date()
        )
        try await inbox.enqueue(receipt)

        try await inbox.markCompleted("safe-hash")

        let pending = try await inbox.pendingReceipts()
        let entries = try await inbox.entries()
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(entries.first?.phase, .completed)
        XCTAssertNotNil(entries.first?.completedAt)
    }

    func testLegacyCompletedEntryWithoutCompletionTimeRemainsUndated() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let state = root.appendingPathComponent("inbox.json")
        let legacyPayload = """
        {"schemaVersion":1,"entries":[{"customerUID":"buyer","messageHash":"safe-hash","videoFilePath":"/tmp/safe-hash.mp4","bytes":123,"phase":"completed","attempts":1,"updatedAt":"1970-01-01T00:01:40Z","failure":null}]}
        """
        try Data(legacyPayload.utf8).write(to: state)

        let entries = try await VideoAnalysisInbox(stateURL: state).entries()

        XCTAssertEqual(entries.first?.phase, .completed)
        XCTAssertNil(entries.first?.completedAt)
    }
}
