import Foundation
import CryptoKit

public struct QueuePointer: Codable, Equatable, Sendable {
    public let uid: String
    public let userDirectory: String
    public let historyVersion: String
    public let firstQueuedAt: String?
    public let queuedAt: String?
    public let updatedAt: String?
    public var sourceURL: URL?

    enum CodingKeys: String, CodingKey {
        case uid
        case userDirectory = "user_directory"
        case historyVersion = "history_version"
        case firstQueuedAt = "first_queued_at"
        case queuedAt = "queued_at"
        case updatedAt = "updated_at"
    }

    public init(uid: String, userDirectory: String, historyVersion: String, firstQueuedAt: String? = nil, queuedAt: String? = nil, updatedAt: String? = nil, sourceURL: URL? = nil) {
        self.uid = uid
        self.userDirectory = userDirectory
        self.historyVersion = historyVersion
        self.firstQueuedAt = firstQueuedAt
        self.queuedAt = queuedAt
        self.updatedAt = updatedAt
        self.sourceURL = sourceURL
    }
}

public enum ReplyDecision: String, Codable, Sendable {
    case autoSend = "auto_send"
    case humanReview = "human_review"
    case noAction = "no_action"
}

public enum RiskLevel: String, Codable, Sendable {
    case low, medium, high
}

public enum ReplyAction: String, Codable, Sendable {
    case reply
    case replyThenTransfer = "reply_then_transfer"
}

public enum TransferReason: String, Codable, Sendable {
    case none
    /// Reserved for the host application when Codex cannot produce a reply.
    /// It is intentionally absent from the model output schema.
    case aiServiceUnavailable = "ai_service_unavailable"
    case customerExplicitlyRequestedHuman = "customer_explicitly_requested_human"
    case explicitReturnRefund = "explicit_return_refund"
    case remoteAssistance = "remote_assistance"
    case refundOperation = "refund_operation"
    case logisticsLookup = "logistics_lookup"
    case troubleshootingExhausted = "troubleshooting_exhausted"
}

public struct ReplyEnvelope: Codable, Equatable, Sendable {
    public let decision: ReplyDecision
    public let riskLevel: RiskLevel
    public let action: ReplyAction
    public let replyText: String
    public let transferReason: TransferReason
    public let reason: String

    enum CodingKeys: String, CodingKey {
        case decision
        case riskLevel = "risk_level"
        case action
        case replyText = "reply_text"
        case transferReason = "transfer_reason"
        case reason
    }

    public init(decision: ReplyDecision, riskLevel: RiskLevel, replyText: String, reason: String,
                action: ReplyAction = .reply, transferReason: TransferReason = .none) {
        self.decision = decision
        self.riskLevel = riskLevel
        self.action = action
        self.replyText = replyText
        self.transferReason = transferReason
        self.reason = reason
    }

    public init(action: ReplyAction, replyText: String, transferReason: TransferReason, reason: String) {
        self.init(decision: .autoSend, riskLevel: .low, replyText: replyText, reason: reason,
                  action: action, transferReason: transferReason)
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        replyText = try values.decode(String.self, forKey: .replyText)
        reason = try values.decode(String.self, forKey: .reason)
        if values.contains(.action) {
            action = try values.decode(ReplyAction.self, forKey: .action)
            transferReason = try values.decode(TransferReason.self, forKey: .transferReason)
            decision = .autoSend
            riskLevel = .low
        } else {
            decision = try values.decode(ReplyDecision.self, forKey: .decision)
            riskLevel = try values.decode(RiskLevel.self, forKey: .riskLevel)
            action = .reply
            transferReason = .none
        }
        guard (action == .reply && transferReason == .none)
                || (action == .replyThenTransfer && transferReason != .none) else {
            throw DecodingError.dataCorruptedError(
                forKey: .transferReason,
                in: values,
                debugDescription: "action 与 transfer_reason 组合无效"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(decision, forKey: .decision)
        try values.encode(riskLevel, forKey: .riskLevel)
        try values.encode(action, forKey: .action)
        try values.encode(replyText, forKey: .replyText)
        try values.encode(transferReason, forKey: .transferReason)
        try values.encode(reason, forKey: .reason)
    }
}

public enum TaskIdentity {
    public static func make(uid: String, historyVersion: String) -> String {
        let digest = SHA256.hash(data: Data("\(uid):\(historyVersion)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public struct ClaimedTask: Sendable {
    public let pointer: QueuePointer
    public let taskID: String
    public let claimURL: URL

    public init(pointer: QueuePointer, taskID: String, claimURL: URL) {
        self.pointer = pointer
        self.taskID = taskID
        self.claimURL = claimURL
    }
}
