import XCTest
import CustomerReplyBatchCore
import CustomerReplyBatchAppSupport
@testable import GrozziieModelTesterCore

final class ModelTestCoordinatorTests: XCTestCase {
    func testSendPersistsCustomerThenGeneratedServiceReply() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TestConversationStore(rootURL: root, makeID: { "one" })
        let conversation = try await store.create()
        let generator = StubGenerator(result: .success(GeneratedReply(
            reply: ReplyEnvelope(
                decision: .autoSend,
                riskLevel: .low,
                replyText: "请先检查电源线两端。",
                reason: "知识库排障第一步"
            ),
            sessionID: "session-1",
            timing: ReplyGenerationTiming(
                model: "gpt-5.6-sol",
                reasoningEffort: "medium",
                codexExecMilliseconds: 1234,
                totalMilliseconds: 1300,
                sessionMode: "new"
            )
        )))
        let coordinator = ModelTestCoordinator(
            conversationID: conversation.id,
            store: store,
            generator: generator,
            knowledgeBaseURL: URL(fileURLWithPath: "/tmp/kb.zip")
        )

        let result = try await coordinator.send(text: "机器不开机", imagePaths: [])
        let saved = try await store.load(conversation.id)

        XCTAssertEqual(result.answer, "请先检查电源线两端。")
        XCTAssertEqual(result.diagnostic.model, "gpt-5.6-sol")
        XCTAssertEqual(result.diagnostic.reasoningEffort, "medium")
        XCTAssertEqual(result.diagnostic.codexMilliseconds, 1234)
        XCTAssertEqual(saved.messages.map(\.sender), [.customer, .service])
        XCTAssertEqual(saved.messages.map(\.text), ["机器不开机", "请先检查电源线两端。"])
        let callCount = await generator.callCount
        XCTAssertEqual(callCount, 1)
    }

    func testGenerationFailureKeepsCustomerMessageWithoutInventingServiceReply() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TestConversationStore(rootURL: root, makeID: { "failure" })
        let conversation = try await store.create()
        let generator = StubGenerator(result: .failure(TestError.failed))
        let coordinator = ModelTestCoordinator(
            conversationID: conversation.id,
            store: store,
            generator: generator,
            knowledgeBaseURL: URL(fileURLWithPath: "/tmp/kb.zip")
        )

        do {
            _ = try await coordinator.send(text: "请问支持Mac吗", imagePaths: [])
            XCTFail("Expected generation to fail")
        } catch { }

        let saved = try await store.load(conversation.id)
        XCTAssertEqual(saved.messages.map(\.sender), [.customer])
        XCTAssertEqual(saved.messages.first?.text, "请问支持Mac吗")
    }
}

private enum TestError: Error { case failed }

private actor StubGenerator: ReplyGenerating {
    private let result: Result<GeneratedReply, Error>
    private(set) var callCount = 0

    init(result: Result<GeneratedReply, Error>) {
        self.result = result
    }

    func generate(for input: PromptInput) async throws -> GeneratedReply {
        callCount += 1
        return try result.get()
    }
}
