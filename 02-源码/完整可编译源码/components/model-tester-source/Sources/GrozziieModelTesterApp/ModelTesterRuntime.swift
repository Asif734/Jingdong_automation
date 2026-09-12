import Foundation
import CustomerReplyBatchAppSupport
import GrozziieModelTesterCore

actor ModelTesterRuntime {
    private let store: TestConversationStore
    private let generator: CodexReplyGenerator
    private let knowledgeRecorder: RecordingKnowledgeRetriever
    private let knowledgeBaseURL: URL
    private var coordinator: ModelTestCoordinator
    private var currentConversationID: String
    let codexExecutableURL: URL

    init(store: TestConversationStore, generator: CodexReplyGenerator, knowledgeRecorder: RecordingKnowledgeRetriever, knowledgeBaseURL: URL, coordinator: ModelTestCoordinator, currentConversationID: String, codexExecutableURL: URL) {
        self.store = store
        self.generator = generator
        self.knowledgeRecorder = knowledgeRecorder
        self.knowledgeBaseURL = knowledgeBaseURL
        self.coordinator = coordinator
        self.currentConversationID = currentConversationID
        self.codexExecutableURL = codexExecutableURL
    }

    static func make() async throws -> ModelTesterRuntime {
        guard let resourcesRoot = Bundle.main.resourceURL else {
            throw BundledResourcesError.missingKnowledgeBase
        }
        guard let codex = CodexInstallationLocator.resolve() else {
            throw CodexGeneratorError.executableMissing
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GrozziieModelTester", isDirectory: true)
        let resources = try BundledResources.resolve(
            resourceRoot: resourcesRoot,
            applicationSupportRoot: support
        )
        let conversations = support.appendingPathComponent("Conversations", isDirectory: true)
        let traces = support.appendingPathComponent("Traces", isDirectory: true)
        try FileManager.default.createDirectory(at: traces, withIntermediateDirectories: true)
        let store = TestConversationStore(rootURL: conversations)
        let conversation = try await store.create()
        let recorder = RecordingKnowledgeRetriever(base: resources.retriever)
        let generator = CodexReplyGenerator(
            executableURL: codex,
            traceDirectory: traces,
            knowledgeRetriever: recorder
        )
        let coordinator = ModelTestCoordinator(
            conversationID: conversation.id,
            store: store,
            generator: generator,
            knowledgeBaseURL: resources.knowledgeBaseURL
        )
        return ModelTesterRuntime(
            store: store,
            generator: generator,
            knowledgeRecorder: recorder,
            knowledgeBaseURL: resources.knowledgeBaseURL,
            coordinator: coordinator,
            currentConversationID: conversation.id,
            codexExecutableURL: codex
        )
    }

    func send(text: String, imagePaths: [String]) async throws -> ModelTestResult {
        let result = try await coordinator.send(text: text, imagePaths: imagePaths)
        return ModelTestResult(
            answer: result.answer,
            diagnostic: result.diagnostic,
            citations: await knowledgeRecorder.lastDocuments()
        )
    }

    func newConversation() async throws {
        let conversation = try await store.create()
        currentConversationID = conversation.id
        coordinator = ModelTestCoordinator(
            conversationID: conversation.id,
            store: store,
            generator: generator,
            knowledgeBaseURL: knowledgeBaseURL
        )
    }

    func deleteCurrentConversation() async throws {
        try await store.delete(currentConversationID)
        try await newConversation()
    }

    func deleteAllConversations() async throws {
        try await store.deleteAll()
        try await newConversation()
    }
}
