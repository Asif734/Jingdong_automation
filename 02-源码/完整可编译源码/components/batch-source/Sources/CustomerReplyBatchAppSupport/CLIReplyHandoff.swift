import Foundation
import CustomerReplyBatchCore

/// Owned by the stdout reader; inspected by the reaper only after the reader joins.
final class CLIReplyStream: @unchecked Sendable {
    private var pending = Data()
    private var discarding = false
    private var eligible = true
    private var started = false
    private var ended = false
    private var candidate: ReplyEnvelope?
    private var runningItems = Set<String>()
    private(set) var turnFailed = false
    private(set) var threadID: String?
    var cleanupWatchdog: Task<Void, Never>?

    func finish() {
        // EOF can terminate a valid JSON line without a newline. At this point
        // use normal reaped fallback, but never miss an explicit failed turn.
        if !discarding && !pending.isEmpty { event(pending, ready: { _, _ in }) }
        pending.removeAll()
    }

    func consume(_ data: Data, ready: (ReplyEnvelope) -> Void) {
        consume(data) { reply, _ in ready(reply) }
    }

    func consume(_ data: Data, ready: (ReplyEnvelope, String?) -> Void) {
        for (index, part) in data.split(separator: 0x0A, omittingEmptySubsequences: false).enumerated() {
            if index > 0 {
                if !discarding && !pending.isEmpty { event(pending, ready: ready) }
                pending.removeAll(keepingCapacity: true)
                discarding = false
            }
            if !discarding {
                if pending.count + part.count > 4 * 1_024 * 1_024 {
                    pending.removeAll(keepingCapacity: true)
                    discarding = true
                    eligible = false
                } else { pending.append(contentsOf: part) }
            }
        }
    }

    private func event(_ data: Data, ready: (ReplyEnvelope, String?) -> Void) {
        guard !ended else { return }
        guard let row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = row["type"] as? String else { eligible = false; return }
        switch type {
        case "thread.started":
            if let value = row["thread_id"] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let threadID, threadID != value { eligible = false }
                else { threadID = value }
            }
        case "turn.started":
            if started { eligible = false }
            started = true
            candidate = nil
        case "turn.failed":
            turnFailed = true
            ended = true
            candidate = nil
        case "error":
            // A CLI may recover from transport errors. Keep the ordinary exit/file path.
            eligible = false
            candidate = nil
        case "item.started", "item.updated", "item.completed":
            guard let item = row["item"] as? [String: Any] else { eligible = false; return }
            let id = item["id"] as? String
            if type == "item.started" {
                candidate = nil
                if let id { runningItems.insert(id) } else { eligible = false }
            }
            if type == "item.completed", let id { runningItems.remove(id) }
            guard type == "item.completed", item["type"] as? String == "agent_message" else { return }
            candidate = nil
            guard item["phase"] == nil || item["phase"] as? String == "final_answer",
                  let text = item["text"] as? String,
                  let body = text.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
                  [Set(["action", "reply_text", "transfer_reason", "reason"]),
                   Set(["decision", "risk_level", "reply_text", "reason"])].contains(Set(object.keys)),
                  let reply = try? JSONDecoder().decode(ReplyEnvelope.self, from: body),
                  reply.decision == .autoSend,
                  !reply.replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            candidate = reply
        case "turn.completed":
            ended = true
            if started && eligible && runningItems.isEmpty, let candidate { ready(candidate, threadID) }
        default:
            // Unknown protocol extensions use the existing, fully reaped fallback.
            eligible = false
        }
    }
}

/// Exactly one return, including races between stdout, stdin failure and process exit.
final class CLIReplyHandoff: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<GeneratedReply, Error>?
    private var inputFinished = false
    private var pending: GeneratedReply?

    init(_ continuation: CheckedContinuation<GeneratedReply, Error>) {
        self.continuation = continuation
    }

    func offer(_ reply: GeneratedReply) {
        lock.lock()
        if inputFinished {
            let target = continuation
            continuation = nil
            lock.unlock()
            target?.resume(returning: reply)
        } else {
            pending = reply
            lock.unlock()
        }
    }

    func didWriteInput() {
        lock.lock()
        inputFinished = true
        let reply = pending
        pending = nil
        let target = reply == nil ? nil : continuation
        if reply != nil { continuation = nil }
        lock.unlock()
        if let reply { target?.resume(returning: reply) }
    }

    func finish(_ result: Result<GeneratedReply, Error>) {
        lock.lock()
        let target = continuation
        continuation = nil
        pending = nil
        lock.unlock()
        target?.resume(with: result)
    }
}
