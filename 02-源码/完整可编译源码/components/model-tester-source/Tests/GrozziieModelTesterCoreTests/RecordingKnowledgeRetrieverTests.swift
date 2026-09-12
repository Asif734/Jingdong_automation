import XCTest
import CustomerReplyBatchAppSupport
@testable import GrozziieModelTesterCore

final class RecordingKnowledgeRetrieverTests: XCTestCase {
    func testRecordsDocumentsReturnedByWrappedRetriever() async throws {
        let data = Data("""
        {"version":"v2-top12","documents":["tp732.md","mac-support.md"],"context":"资料内容"}
        """.utf8)
        let base = StaticRetriever(result: try JSONDecoder().decode(RetrievedKnowledge.self, from: data))
        let recorder = RecordingKnowledgeRetriever(base: base)

        _ = try await recorder.retrieve(historyJSONL: "{}\n", knowledgeBasePaths: ["kb.zip"])

        let documents = await recorder.lastDocuments()
        XCTAssertEqual(documents, ["tp732.md", "mac-support.md"])
    }
}

private actor StaticRetriever: KnowledgeContextRetrieving {
    let result: RetrievedKnowledge
    init(result: RetrievedKnowledge) { self.result = result }
    func retrieve(historyJSONL: String, knowledgeBasePaths: [String]) async throws -> RetrievedKnowledge { result }
}
