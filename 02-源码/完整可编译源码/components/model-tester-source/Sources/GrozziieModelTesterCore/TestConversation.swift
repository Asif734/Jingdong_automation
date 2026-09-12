import Foundation

public enum TestMessageSender: String, Codable, Sendable {
    case customer
    case service
}

public struct TestMessage: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let sender: TestMessageSender
    public let text: String
    public let timestamp: Date
    public let imagePaths: [String]

    public init(
        id: UUID = UUID(),
        sender: TestMessageSender,
        text: String,
        timestamp: Date,
        imagePaths: [String] = []
    ) {
        self.id = id
        self.sender = sender
        self.text = text
        self.timestamp = timestamp
        self.imagePaths = imagePaths
    }
}

public struct TestConversation: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let uid: String
    public let createdAt: Date
    public var messages: [TestMessage]

    public init(id: String, uid: String, createdAt: Date, messages: [TestMessage] = []) {
        self.id = id
        self.uid = uid
        self.createdAt = createdAt
        self.messages = messages
    }
}
