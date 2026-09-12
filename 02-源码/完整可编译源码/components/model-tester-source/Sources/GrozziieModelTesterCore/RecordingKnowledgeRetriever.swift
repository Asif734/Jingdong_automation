import Foundation
import CustomerReplyBatchAppSupport

public actor RecordingKnowledgeRetriever: KnowledgeContextRetrieving {
    private let base: any KnowledgeContextRetrieving
    private var documents: [String] = []

    public init(base: any KnowledgeContextRetrieving) {
        self.base = base
    }

    public func retrieve(historyJSONL: String, knowledgeBasePaths: [String]) async throws -> RetrievedKnowledge {
        let result = try await base.retrieve(
            historyJSONL: historyJSONL,
            knowledgeBasePaths: knowledgeBasePaths
        )
        documents = result.documents
        return result
    }

    public func lastDocuments() -> [String] { documents }
}
