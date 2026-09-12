import Foundation
import CustomerReplyBatchAppSupport

public enum ModelTestCoordinatorError: LocalizedError {
    case emptyMessage
    case emptyReply

    public var errorDescription: String? {
        switch self {
        case .emptyMessage: return "请输入客户问题或添加图片"
        case .emptyReply: return "模型没有返回可显示的回答"
        }
    }
}

public actor ModelTestCoordinator {
    public let conversationID: String
    private let store: TestConversationStore
    private let generator: any ReplyGenerating
    private let knowledgeBaseURL: URL

    public init(
        conversationID: String,
        store: TestConversationStore,
        generator: any ReplyGenerating,
        knowledgeBaseURL: URL
    ) {
        self.conversationID = conversationID
        self.store = store
        self.generator = generator
        self.knowledgeBaseURL = knowledgeBaseURL
    }

    public func send(text: String, imagePaths: [String]) async throws -> ModelTestResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !imagePaths.isEmpty else {
            throw ModelTestCoordinatorError.emptyMessage
        }
        let displayText = trimmed.isEmpty ? "[图片]" : trimmed
        try await store.appendCustomer(text: displayText, imagePaths: imagePaths, to: conversationID)
        let input = try await store.promptInput(for: conversationID, knowledgeBaseURL: knowledgeBaseURL)
        let generated = try await generator.generate(for: input)
        let answer = generated.reply.replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw ModelTestCoordinatorError.emptyReply }
        try await store.appendService(text: answer, to: conversationID)
        return ModelTestResult(answer: answer, diagnostic: RunDiagnostic(timing: generated.timing))
    }
}
