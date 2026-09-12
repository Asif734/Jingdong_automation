import Foundation

public struct OutgoingTask: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let taskID: String
    public let uid: String
    public let sourceHistoryVersion: String
    public let sourceTask: String
    public let decision: String
    public let riskLevel: String
    public let replyText: String
    public let reason: String
    public let createdAt: String
    public var sourceURL: URL?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case taskID = "task_id"
        case uid
        case sourceHistoryVersion = "source_history_version"
        case sourceTask = "source_task"
        case decision
        case riskLevel = "risk_level"
        case replyText = "reply_text"
        case reason
        case createdAt = "created_at"
    }
}

public struct ClaimedOutgoingTask: Sendable {
    public let task: OutgoingTask
    public let claimURL: URL
}

public enum SenderQueueError: LocalizedError {
    case invalidTask(String)
    case missingTask(URL)

    public var errorDescription: String? {
        switch self {
        case .invalidTask(let reason): return "无效待发送任务：\(reason)"
        case .missingTask(let url): return "待发送任务不存在：\(url.path)"
        }
    }
}
