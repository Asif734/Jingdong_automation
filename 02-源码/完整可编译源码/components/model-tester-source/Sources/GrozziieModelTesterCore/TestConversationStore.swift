import Foundation
import CustomerReplyBatchAppSupport

public enum TestConversationStoreError: LocalizedError {
    case missingConversation(String)

    public var errorDescription: String? {
        switch self {
        case .missingConversation(let id): return "找不到测试会话：\(id)"
        }
    }
}

public actor TestConversationStore {
    public let rootURL: URL
    private let makeID: () -> String
    private let now: () -> Date
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        rootURL: URL,
        makeID: @escaping () -> String = { UUID().uuidString.lowercased() },
        now: @escaping () -> Date = { Date() }
    ) {
        self.rootURL = rootURL
        self.makeID = makeID
        self.now = now
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    public func create() throws -> TestConversation {
        let id = makeID()
        let conversation = TestConversation(
            id: id,
            uid: "model-test-\(id)",
            createdAt: now()
        )
        try save(conversation)
        return conversation
    }

    public func load(_ id: String) throws -> TestConversation {
        let url = conversationURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TestConversationStoreError.missingConversation(id)
        }
        return try decoder.decode(TestConversation.self, from: Data(contentsOf: url))
    }

    public func appendCustomer(text: String, imagePaths: [String], to id: String) throws {
        var conversation = try load(id)
        conversation.messages.append(TestMessage(
            sender: .customer,
            text: text,
            timestamp: now(),
            imagePaths: imagePaths
        ))
        try save(conversation)
    }

    public func appendService(text: String, to id: String) throws {
        var conversation = try load(id)
        conversation.messages.append(TestMessage(
            sender: .service,
            text: text,
            timestamp: now()
        ))
        try save(conversation)
    }

    public func delete(_ id: String) throws {
        let directory = directoryURL(id)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    public func deleteAll() throws {
        if FileManager.default.fileExists(atPath: rootURL.path) {
            try FileManager.default.removeItem(at: rootURL)
        }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    public func promptInput(for id: String, knowledgeBaseURL: URL) throws -> PromptInput {
        let conversation = try load(id)
        let lines = try conversation.messages.map(jsonLine)
        let history = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        let lastServiceIndex = conversation.messages.lastIndex { $0.sender == .service }
        let unanswered = conversation.messages.enumerated().filter { index, message in
            message.sender == .customer && index > (lastServiceIndex ?? -1)
        }.map(\.element)
        let targetLines = try unanswered.map(jsonLine)
        let images = conversation.messages.flatMap(\.imagePaths)
        return PromptInput(
            uid: conversation.uid,
            historyVersion: historyVersion(history),
            historyJSONL: history,
            historyText: conversation.messages.map(\.text).joined(separator: "\n"),
            imagePaths: images,
            knowledgeBasePaths: [knowledgeBaseURL.path],
            targetCustomerJSONL: targetLines.joined(separator: "\n") + (targetLines.isEmpty ? "" : "\n")
        )
    }

    private func save(_ conversation: TestConversation) throws {
        let directory = directoryURL(conversation.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(conversation)
        try data.write(to: conversationURL(conversation.id), options: .atomic)
        let lines = try conversation.messages.map(jsonLine)
        let jsonl = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        try Data(jsonl.utf8).write(to: directory.appendingPathComponent("history.jsonl"), options: .atomic)
        let text = conversation.messages.map { "[\($0.sender.rawValue)] \($0.text)" }.joined(separator: "\n\n")
        try Data(text.utf8).write(to: directory.appendingPathComponent("history.txt"), options: .atomic)
    }

    private func jsonLine(_ message: TestMessage) throws -> String {
        var value: [String: Any] = [
            "sender": message.sender.rawValue,
            "t": message.imagePaths.isEmpty ? "text" : "image",
            "v": message.text,
            "timestamp": ISO8601DateFormatter().string(from: message.timestamp),
        ]
        if !message.imagePaths.isEmpty { value["image_paths"] = message.imagePaths }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func historyVersion(_ history: String) -> String {
        "bytes-\(Data(history.utf8).count)"
    }

    private func directoryURL(_ id: String) -> URL {
        rootURL.appendingPathComponent(id, isDirectory: true)
    }

    private func conversationURL(_ id: String) -> URL {
        directoryURL(id).appendingPathComponent("conversation.json")
    }
}
