import XCTest
@testable import GrozziieModelTesterCore

final class TestConversationStoreTests: XCTestCase {
    func testCustomerAndServiceMessagesPersistInOrderAndBecomePromptInput() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TestConversationStore(
            rootURL: root,
            makeID: { "conversation-one" },
            now: { Date(timeIntervalSince1970: 1_777_777_777) }
        )

        let conversation = try await store.create()
        try await store.appendCustomer(text: "TD630无法开机", imagePaths: [], to: conversation.id)
        let input = try await store.promptInput(
            for: conversation.id,
            knowledgeBaseURL: URL(fileURLWithPath: "/tmp/kb.zip")
        )
        try await store.appendService(text: "请先重新插拔电源线。", to: conversation.id)
        let loaded = try await store.load(conversation.id)

        XCTAssertEqual(conversation.uid, "model-test-conversation-one")
        XCTAssertEqual(loaded.messages.map(\.sender), [.customer, .service])
        XCTAssertEqual(loaded.messages.map(\.text), ["TD630无法开机", "请先重新插拔电源线。"])
        XCTAssertTrue(input.historyJSONL.contains("\"sender\":\"customer\""))
        XCTAssertTrue(input.targetCustomerJSONL.contains("TD630无法开机"))
        XCTAssertFalse(input.targetCustomerJSONL.contains("请先重新插拔电源线"))
        XCTAssertEqual(input.knowledgeBasePaths, ["/tmp/kb.zip"])
    }

    func testNewConversationDoesNotInheritPriorHistory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var ids = ["first", "second"]
        let store = TestConversationStore(
            rootURL: root,
            makeID: { ids.removeFirst() },
            now: { Date() }
        )

        let first = try await store.create()
        try await store.appendCustomer(text: "旧问题", imagePaths: [], to: first.id)
        let second = try await store.create()
        let loaded = try await store.load(second.id)

        XCTAssertEqual(second.uid, "model-test-second")
        XCTAssertTrue(loaded.messages.isEmpty)
    }

    func testDeleteRemovesOnlySelectedConversation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var ids = ["first", "second"]
        let store = TestConversationStore(rootURL: root, makeID: { ids.removeFirst() })
        let first = try await store.create()
        let second = try await store.create()

        try await store.delete(first.id)

        do {
            _ = try await store.load(first.id)
            XCTFail("被删除的会话仍然可以读取")
        } catch TestConversationStoreError.missingConversation {
            // Expected.
        }
        let surviving = try await store.load(second.id)
        XCTAssertEqual(surviving.id, "second")
    }

    func testDeleteAllRemovesEveryConversation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var ids = ["first", "second"]
        let store = TestConversationStore(rootURL: root, makeID: { ids.removeFirst() })
        let first = try await store.create()
        let second = try await store.create()

        try await store.deleteAll()

        for id in [first.id, second.id] {
            do {
                _ = try await store.load(id)
                XCTFail("删除全部后仍可读取会话 \(id)")
            } catch TestConversationStoreError.missingConversation {
                // Expected.
            }
        }
    }
}
