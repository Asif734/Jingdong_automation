import Foundation
import XCTest
@testable import QianniuOCRAppSupport

final class QianniuVideoTransferTests: XCTestCase {
    func testBestEffortJobReportsStartAndSuccessfulCompletionWithoutCreatingFailureState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let events = BestEffortVideoEventRecorder()
        let startedAt = Date(timeIntervalSince1970: 1_788_100_000)
        let completedAt = Date(timeIntervalSince1970: 1_788_100_012)
        let clock = SequenceClock(values: [startedAt, completedAt])
        let job = BestEffortVideoDownloadJob(
            messageID: "VIDEO.MONITOR",
            customerUID: "buyer-video",
            outputDirectory: root,
            candidateProvider: {
                try XCTUnwrap(URL(string: "https://example.invalid/video.mp4"))
            },
            download: { _, destination in
                try Data(repeating: 0x2A, count: 7).write(to: destination)
            },
            now: { clock.next() },
            onStarted: { messageID, date in
                await events.recordStart(messageID: messageID, date: date)
            },
            onCompleted: { completion in
                XCTAssertTrue(FileManager.default.fileExists(atPath: completion.fileURL.path))
                await events.recordCompletion(completion)
            }
        )

        await job.run()

        let snapshot = await events.snapshot()
        XCTAssertEqual(snapshot.messageID, "VIDEO.MONITOR")
        XCTAssertEqual(snapshot.startedAt, startedAt)
        XCTAssertEqual(snapshot.completion?.messageID, "VIDEO.MONITOR")
        XCTAssertEqual(snapshot.completion?.customerUID, "buyer-video")
        XCTAssertFalse(snapshot.completion?.messageHash.isEmpty ?? true)
        XCTAssertEqual(snapshot.completion?.startedAt, startedAt)
        XCTAssertEqual(snapshot.completion?.completedAt, completedAt)
        XCTAssertEqual(snapshot.completion?.bytes, 7)
    }

    func testBestEffortJobSignalsDownloadStartWithoutWaitingForCompletionOrInspecting() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blocker = DownloadBlocker()
        let job = BestEffortVideoDownloadJob(
            messageID: "VIDEO.FIRE-AND-FORGET",
            outputDirectory: root,
            candidateProvider: {
                try XCTUnwrap(URL(string: "https://example.invalid/video.mp4"))
            },
            download: { _, destination in
                await blocker.markEntered()
                await blocker.waitUntilReleased()
                try Data("video".utf8).write(to: destination)
            }
        )

        let task = Task { await job.run() }

        try await Task.sleep(for: .milliseconds(20))
        let enteredBeforeRelease = await blocker.entered
        let finishedBeforeRelease = await blocker.finished
        XCTAssertTrue(enteredBeforeRelease)
        XCTAssertFalse(finishedBeforeRelease)

        await blocker.release()
        await task.value
        let finishedAfterRelease = await blocker.finished
        XCTAssertTrue(finishedAfterRelease)
    }

    func testSuccessfulJobEmitsOneCustomerBoundCompletionAfterFinalFileExists() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let completions = VideoCompletionRecorder()
        let job = VideoTransferJob(
            messageID: "VIDEO.RECEIPT",
            customerUID: "buyer-a",
            outputDirectory: root.appendingPathComponent("videos", isDirectory: true),
            journal: VideoTransferJournal(url: root.appendingPathComponent("journal.json")),
            candidateProvider: { try XCTUnwrap(URL(string: "https://example.invalid/video.mp4")) },
            download: { _, destination in
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("video".utf8).write(to: destination)
                return 200
            },
            inspect: { _ in
                VideoTransferInspection(bytes: 5, sha256: "sha", durationSeconds: 2,
                                        width: 100, height: 200, videoCodec: "H.264", audioCodec: nil)
            },
            completion: { receipt in
                XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.fileURL.path))
                await completions.append(receipt)
            }
        )

        await job.run()
        await job.run()

        let values = await completions.values
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values.first?.customerUID, "buyer-a")
        XCTAssertEqual(values.first?.bytes, 5)
    }

    @MainActor
    func testArmerCanUseOldLogWhenCurrentLogIsMissing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let missingCurrent = root.appendingPathComponent("app.log")
        let activeOld = root.appendingPathComponent("app.log.old")
        try Data("active-log\n".utf8).write(to: activeOld)
        let armer = QianniuLogVideoTransferArmer(
            logURLs: [missingCurrent, activeOld],
            outputDirectory: root.appendingPathComponent("videos", isDirectory: true),
            journalURL: root.appendingPathComponent("journal.json")
        )

        XCTAssertNotNil(armer.arm(messageID: "VIDEO.OLD"))
    }

    func testSuccessfulJobMovesVerifiedVideoToStableHashedPathAndWritesSanitizedJournal() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = VideoTransferJournal(url: root.appendingPathComponent("status.json"))
        let job = VideoTransferJob(
            messageID: "VIDEO.AB",
            outputDirectory: root.appendingPathComponent("收到的视频", isDirectory: true),
            journal: journal,
            candidateProvider: {
                try XCTUnwrap(URL(string: "https://msg2.cloudvideocdn.taobao.com/v.mp4?auth_key=SECRET"))
            },
            download: { _, destination in
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data("downloaded-video".utf8).write(to: destination)
                return 200
            },
            inspect: { stagedURL in
                XCTAssertEqual(stagedURL.pathExtension, "mp4")
                return VideoTransferInspection(
                    bytes: 16,
                    sha256: "file-sha256",
                    durationSeconds: 6.19,
                    width: 592,
                    height: 1280,
                    videoCodec: "H.264",
                    audioCodec: "AAC"
                )
            },
            now: { Date(timeIntervalSince1970: 1_788_000_000) }
        )

        await job.run()

        let hash = "344d94b0f9d0bea8e7bbf0fd2f15dc01e152bca483dedc701c6c4a5c77f86644"
        let final = root.appendingPathComponent("收到的视频/\(hash).mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: final.path))
        let records = try await journal.snapshot()
        XCTAssertEqual(records, [
            VideoTransferRecord(
                messageHash: hash,
                phase: .downloaded,
                fileName: "\(hash).mp4",
                bytes: 16,
                sha256: "file-sha256",
                durationSeconds: 6.19,
                width: 592,
                height: 1280,
                videoCodec: "H.264",
                audioCodec: "AAC",
                updatedAt: Date(timeIntervalSince1970: 1_788_000_000),
                failure: nil
            )
        ])
        let journalText = try String(contentsOf: root.appendingPathComponent("status.json"), encoding: .utf8)
        XCTAssertFalse(journalText.contains("VIDEO.AB"))
        XCTAssertFalse(journalText.contains("https://"))
        XCTAssertFalse(journalText.contains("auth_key"))
        XCTAssertFalse(journalText.contains("SECRET"))
    }

    func testFailureNeverPersistsSignedURLAndRemovesPartialFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let journalURL = root.appendingPathComponent("status.json")
        let journal = VideoTransferJournal(url: journalURL)
        let job = VideoTransferJob(
            messageID: "VIDEO.FAIL",
            outputDirectory: root.appendingPathComponent("收到的视频", isDirectory: true),
            journal: journal,
            candidateProvider: {
                throw NSError(
                    domain: "test",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "https://msg2.cloudvideocdn.taobao.com/f.mp4?auth_key=LEAK"]
                )
            },
            download: { _, _ in XCTFail("download must not start"); return 200 },
            inspect: { _ in throw NSError(domain: "unused", code: 1) },
            now: { Date(timeIntervalSince1970: 1_788_000_100) }
        )

        await job.run()

        let records = try await journal.snapshot()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].messageHash, "f4be38f8cffdffd0066f068a89ad8c00caa7f70dd05323dca92b7b81be26c000")
        XCTAssertEqual(records[0].phase, .failed)
        XCTAssertEqual(records[0].failure, "未能从千牛新增日志取得视频地址")
        let journalText = try String(contentsOf: journalURL, encoding: .utf8)
        XCTAssertFalse(journalText.contains("https://"))
        XCTAssertFalse(journalText.contains("auth_key"))
        XCTAssertFalse(journalText.contains("LEAK"))
        let partials = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("收到的视频", isDirectory: true),
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "partial" }
        XCTAssertTrue(partials.isEmpty)
    }

    func testInvalidDownloadedMediaRemovesStagingFileBeforeJobReturns() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("收到的视频", isDirectory: true)
        let journal = VideoTransferJournal(url: root.appendingPathComponent("status.json"))
        let job = VideoTransferJob(
            messageID: "VIDEO.INVALID",
            outputDirectory: output,
            journal: journal,
            candidateProvider: {
                try XCTUnwrap(URL(string: "https://msg2.cloudvideocdn.taobao.com/invalid.mp4?auth_key=SECRET"))
            },
            download: { _, destination in
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data("not-a-video".utf8).write(to: destination)
                return 200
            },
            inspect: { _ in throw NSError(domain: "invalid-media", code: 1) }
        )

        await job.run()

        let files = try FileManager.default.contentsOfDirectory(
            at: output,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(files.isEmpty)
        let records = try await journal.snapshot()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].phase, .failed)
        XCTAssertEqual(records[0].failure, "下载内容不是有效视频")
    }
}

private actor VideoCompletionRecorder {
    var values: [DownloadedCustomerVideo] = []
    func append(_ value: DownloadedCustomerVideo) { values.append(value) }
}

private actor DownloadBlocker {
    private(set) var entered = false
    private(set) var finished = false
    private var released = false

    func markEntered() { entered = true }

    func waitUntilReleased() async {
        while !released { try? await Task.sleep(for: .milliseconds(5)) }
        finished = true
    }

    func release() { released = true }
}

private final class SequenceClock: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Date]
    init(values: [Date]) { self.values = values }
    func next() -> Date {
        lock.lock(); defer { lock.unlock() }
        return values.removeFirst()
    }
}

private actor BestEffortVideoEventRecorder {
    private var messageID: String?
    private var startedAt: Date?
    private var completion: BestEffortVideoDownloadCompletion?

    func recordStart(messageID: String, date: Date) {
        self.messageID = messageID
        startedAt = date
    }

    func recordCompletion(_ completion: BestEffortVideoDownloadCompletion) {
        self.completion = completion
    }

    func snapshot() -> (messageID: String?, startedAt: Date?, completion: BestEffortVideoDownloadCompletion?) {
        (messageID, startedAt, completion)
    }
}
