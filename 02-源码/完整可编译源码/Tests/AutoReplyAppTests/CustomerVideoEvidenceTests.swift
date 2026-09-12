import XCTest
@testable import AutoReplyApp
import QianniuOCRAppSupport

final class CustomerVideoEvidenceTests: XCTestCase {
    func testAppleEmptyTranscriptFallsBackToSenseVoice() async {
        let apple = RecordingVideoSpeechTranscriber(result: [])
        let fallbackSegments = [
            VideoTranscriptSegment(startSeconds: 0, durationSeconds: 4, text: "备用识别成功")
        ]
        let senseVoice = RecordingVideoSpeechTranscriber(result: fallbackSegments)
        let transcriber = AppleThenFallbackVideoSpeechTranscriber(primary: apple, fallback: senseVoice)

        let result = await transcriber.transcribe(URL(fileURLWithPath: "/tmp/audio.m4a"))
        let appleCalls = await apple.callCount()
        let senseVoiceCalls = await senseVoice.callCount()

        XCTAssertEqual(result, fallbackSegments)
        XCTAssertEqual(appleCalls, 1)
        XCTAssertEqual(senseVoiceCalls, 1)
    }

    func testAppleNonemptyTranscriptDoesNotCallSenseVoice() async {
        let appleSegments = [
            VideoTranscriptSegment(startSeconds: 0, durationSeconds: 2, text: "苹果识别成功")
        ]
        let apple = RecordingVideoSpeechTranscriber(result: appleSegments)
        let senseVoice = RecordingVideoSpeechTranscriber(result: [])
        let transcriber = AppleThenFallbackVideoSpeechTranscriber(primary: apple, fallback: senseVoice)

        let result = await transcriber.transcribe(URL(fileURLWithPath: "/tmp/audio.m4a"))
        let senseVoiceCalls = await senseVoice.callCount()

        XCTAssertEqual(result, appleSegments)
        XCTAssertEqual(senseVoiceCalls, 0)
    }

    func testExportedAudioIsPreferredAsTheTranscriptionInput() {
        let staging = URL(fileURLWithPath: "/tmp/video-evidence/staging", isDirectory: true)
        let video = URL(fileURLWithPath: "/tmp/video-evidence/customer.mp4")

        XCTAssertEqual(
            CustomerVideoEvidencePreparer.transcriptionInputURL(
                stagingURL: staging,
                audioFileName: "audio.m4a",
                fallbackVideoURL: video
            ),
            staging.appendingPathComponent("audio.m4a")
        )
    }

    func testSamplingIsOrderedBoundedAndCoversVideo() {
        let values = CustomerVideoEvidencePreparer.sampleTimes(duration: 40, maximumFrames: 20)
        XCTAssertEqual(values.count, 20)
        XCTAssertEqual(values, values.sorted())
        XCTAssertLessThan(values.first ?? 1, 1)
        XCTAssertGreaterThan(values.last ?? 0, 39)
    }

    func testShortCustomerVideoSamplesEverySecondWithoutDeduplication() {
        let values = CustomerVideoEvidencePreparer.sampleTimes(duration: 6.19, maximumFrames: 20)

        XCTAssertEqual(values.count, 7)
        XCTAssertEqual(values, values.sorted())
        XCTAssertLessThan(values.first ?? 1, 0.3)
        XCTAssertGreaterThanOrEqual(values.last ?? 0, 5.99)
    }

    func testMediumVideoSamplesEveryTwoSeconds() {
        let values = CustomerVideoEvidencePreparer.sampleTimes(duration: 25, maximumFrames: 20)

        XCTAssertEqual(values.count, 14)
        XCTAssertEqual(values, values.sorted())
        XCTAssertGreaterThanOrEqual(values.last ?? 0, 24.8)
    }

    func testShortVideoUsesDistinctBeginningMiddleAndEndSamples() {
        let values = CustomerVideoEvidencePreparer.sampleTimes(duration: 1, maximumFrames: 8)
        XCTAssertEqual(values.count, 3)
        XCTAssertEqual(values[1], 0.5, accuracy: 0.001)
        XCTAssertGreaterThan(values[2], values[1])
    }

    func testZeroDurationProducesNoSampleTimes() {
        XCTAssertEqual(CustomerVideoEvidencePreparer.sampleTimes(duration: 0), [])
        XCTAssertEqual(CustomerVideoEvidencePreparer.sampleTimes(duration: .nan), [])
    }

    func testInvalidFileFailsWithoutPublishingEvidenceDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("invalid.mp4")
        try Data("invalid".utf8).write(to: source)
        let preparer = CustomerVideoEvidencePreparer(rootURL: root.appendingPathComponent("evidence"))
        let receipt = DownloadedCustomerVideo(customerUID: "buyer", messageHash: "hash", fileURL: source,
                                              bytes: 7, completedAt: Date())

        do {
            _ = try await preparer.prepare(receipt: receipt)
            XCTFail("invalid media must fail")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("evidence/hash").path))
    }

    func testRealVideoFixtureExtractsReadableFramesWhenProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["QIANNIU_VIDEO_FIXTURE"] else {
            throw XCTSkip("Set QIANNIU_VIDEO_FIXTURE for the live MP4 acceptance check")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = URL(fileURLWithPath: path)
        let receipt = DownloadedCustomerVideo(
            customerUID: "fixture-buyer", messageHash: "fixture-hash", fileURL: source,
            bytes: Int64((try? Data(contentsOf: source).count) ?? 0), completedAt: Date()
        )
        let manifest = try await CustomerVideoEvidencePreparer(
            rootURL: root, transcriber: NoVideoSpeechTranscriber()
        ).prepare(receipt: receipt)

        XCTAssertGreaterThan(manifest.durationSeconds, 0)
        XCTAssertFalse(manifest.frames.isEmpty)
        XCTAssertLessThanOrEqual(manifest.frames.count, 20)
        XCTAssertEqual(manifest.audioFileName, "audio.m4a")
        XCTAssertGreaterThan(
            try Data(contentsOf: root.appendingPathComponent("fixture-hash/audio.m4a")).count,
            100
        )
        for frame in manifest.frames {
            XCTAssertGreaterThan(try Data(contentsOf: root.appendingPathComponent("fixture-hash/\(frame.fileName)")).count, 100)
        }
    }
}

private actor RecordingVideoSpeechTranscriber: VideoSpeechTranscribing {
    private let result: [VideoTranscriptSegment]
    private var calls = 0

    init(result: [VideoTranscriptSegment]) { self.result = result }

    func transcribe(_ videoURL: URL) async -> [VideoTranscriptSegment] {
        calls += 1
        return result
    }

    func callCount() -> Int { calls }
}
