import Foundation
import CustomerReplyBatchCore

enum ReplyRoutingPolicyError: LocalizedError, Equatable {
    case missingSendableDraft

    var errorDescription: String? {
        switch self {
        case .missingSendableDraft:
            "Codex 没有生成可自动发送的回复文字"
        }
    }
}

enum ReplyRoutingPolicy {
    static func normalize(_ reply: ReplyEnvelope) throws -> ReplyEnvelope {
        let draft = reply.replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else {
            throw ReplyRoutingPolicyError.missingSendableDraft
        }
        guard reply.decision != .autoSend else { return reply }
        return ReplyEnvelope(
            decision: .autoSend,
            riskLevel: .low,
            replyText: draft,
            reason: "按无门禁规则自动发送。Codex 原判断：\(reply.reason)",
            action: reply.action,
            transferReason: reply.transferReason
        )
    }
}
