import Foundation
import CustomerReplyBatchAppSupport

enum CodexFailureDisposition: Equatable {
    case unrelated
    case retryOnce
    case transferImmediately
}

enum CodexFailureRoutingPolicy {
    static func disposition(for error: Error) -> CodexFailureDisposition {
        guard let error = error as? CodexGeneratorError else { return .unrelated }
        switch error {
        case .executableMissing, .chatGPTLoginRequired:
            return .transferImmediately
        case .invalidReply:
            return .retryOnce
        case .commandFailed(_, let message):
            let value = message.lowercased()
            if containsAny(value, permanentMarkers) {
                return .transferImmediately
            }
            // Every other confirmed Codex process/transport failure receives one
            // bounded retry. Unknown future Codex failures must never retry forever.
            return .retryOnce
        }
    }

    static func isStoredCodexFailure(_ message: String?) -> Bool {
        guard let message else { return false }
        return message.hasPrefix("Codex 退出码")
            || message.hasPrefix("Codex 返回无效")
            || message.hasPrefix("未找到本机 Codex CLI")
            || message.hasPrefix("Codex 必须使用 ChatGPT 登录")
    }

    private static func containsAny(_ value: String, _ markers: [String]) -> Bool {
        markers.contains { value.contains($0) }
    }

    private static let permanentMarkers = [
        "http 400", "status 400", "400 bad request", "invalid_request_error",
        "http 401", "status 401", "401 unauthorized", "unauthorized",
        "http 403", "status 403", "403 forbidden", "forbidden",
        "http 413", "status 413", "413 payload too large",
        "http 422", "status 422", "422 unprocessable",
        "http 429", "status 429", "429 too many requests", "too many requests", "rate limit",
        "credit_balance_exhausted", "organization_usage_limit_exceeded",
        "organization_spend_limit_exceeded", "project_spend_limit_exceeded",
        "insufficient_quota", "quota exceeded",
        "model_not_found", "model not found", "unsupported model", "does not have access to model",
        "maximum context length", "context_length_exceeded", "context window"
    ]
}
