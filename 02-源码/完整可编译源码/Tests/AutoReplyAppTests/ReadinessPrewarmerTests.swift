import CustomerReplyBatchAppSupport
import Foundation
import QianniuOCRAppSupport
import XCTest
@testable import AutoReplyApp

@MainActor
final class ReadinessPrewarmerTests: XCTestCase {
    func testPrepareReportsEachSubsystemSeparately() async throws {
        let ocr = RecordingOCRPrewarmer()
        let knowledge = RecordingKnowledgePrewarmer(version: "v2-top12")
        let codex = RecordingCodexReadiness(result: .loggedIn)
        let speech = RecordingSpeechPrewarmer()
        let prewarmer = ReadinessPrewarmer(
            ocr: ocr,
            knowledge: knowledge,
            knowledgeBasePaths: ["/fixture/knowledge.zip"],
            speech: speech,
            codex: codex
        )

        let statuses = try await prewarmer.prepare()

        XCTAssertEqual(statuses["ocr"]?.level, .verified)
        XCTAssertEqual(statuses["v2"]?.strategy, "persistent-top12")
        XCTAssertEqual(statuses["speech"]?.strategy, "persistent-sensevoice-int8")
        XCTAssertEqual(statuses["codex"]?.level, .verified)
        let ocrCalls = ocr.callCount()
        let knowledgeCalls = await knowledge.callCount()
        let probeCalls = await codex.probeCallCount()
        XCTAssertEqual(ocrCalls, 1)
        XCTAssertEqual(knowledgeCalls, 1)
        let speechCalls = await speech.callCount()
        XCTAssertEqual(speechCalls, 1)
        XCTAssertEqual(probeCalls, 1)
    }

    func testKeywordKnowledgeModeIsDegradedButRunnable() async throws {
        let prewarmer = ReadinessPrewarmer(
            ocr: RecordingOCRPrewarmer(),
            knowledge: RecordingKnowledgePrewarmer(version: "v2-lexical-only"),
            knowledgeBasePaths: ["/fixture/knowledge.zip"],
            speech: RecordingSpeechPrewarmer(),
            codex: RecordingCodexReadiness(result: .loggedIn)
        )

        let statuses = try await prewarmer.prepare()

        XCTAssertEqual(statuses["v2"]?.level, .fallback)
        XCTAssertEqual(statuses["v2"]?.strategy, "lexical-fallback")
    }

    func testConcurrentPrepareCallsShareOnePreparationTask() async throws {
        let ocr = RecordingOCRPrewarmer(delay: .milliseconds(40))
        let knowledge = RecordingKnowledgePrewarmer(version: "v2-top12")
        let codex = RecordingCodexReadiness(result: .loggedIn)
        let speech = RecordingSpeechPrewarmer(delay: .milliseconds(40))
        let prewarmer = ReadinessPrewarmer(
            ocr: ocr,
            knowledge: knowledge,
            knowledgeBasePaths: ["/fixture/knowledge.zip"],
            speech: speech,
            codex: codex
        )

        async let first = prewarmer.prepare()
        async let second = prewarmer.prepare()
        _ = try await (first, second)

        let ocrCalls = ocr.callCount()
        let knowledgeCalls = await knowledge.callCount()
        let probeCalls = await codex.probeCallCount()
        XCTAssertEqual(ocrCalls, 1)
        XCTAssertEqual(knowledgeCalls, 1)
        let speechCalls = await speech.callCount()
        XCTAssertEqual(speechCalls, 1)
        XCTAssertEqual(probeCalls, 1)
    }
}

private actor RecordingSpeechPrewarmer: VideoSpeechPrewarming {
    private let delay: Duration?
    private var calls = 0

    init(delay: Duration? = nil) { self.delay = delay }

    func prepareSpeechRecognition() async throws {
        calls += 1
        if let delay { try await Task.sleep(for: delay) }
    }

    func callCount() -> Int { calls }
}

@MainActor
private final class RecordingOCRPrewarmer: OCRPrewarming {
    private let delay: Duration?
    private var calls = 0

    init(delay: Duration? = nil) { self.delay = delay }

    func prepareOCR() async throws {
        calls += 1
        if let delay { try await Task.sleep(for: delay) }
    }

    func callCount() -> Int { calls }
}

private actor RecordingKnowledgePrewarmer: KnowledgePrewarming {
    private let version: String
    private var calls = 0

    init(version: String) { self.version = version }

    func prepare(knowledgeBasePaths: [String]) async throws -> KnowledgePreparation {
        calls += 1
        return KnowledgePreparation(version: version)
    }

    func shutdown() async {}
    func callCount() -> Int { calls }
}

private actor RecordingCodexReadiness: CodexReadinessChecking {
    private let result: CodexLoginState
    private var probeCalls = 0

    init(result: CodexLoginState) { self.result = result }

    func codexState() async throws -> CodexLoginState { result }
    func runNoToolGenerationProbe() async throws { probeCalls += 1 }
    func probeCallCount() -> Int { probeCalls }
}
