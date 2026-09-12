import Foundation
import CustomerReplyBatchCore

struct TransferPlaceholder: Codable, Equatable {
    let schemaVersion: Int
    let taskID: String
    let uid: String
    let sourceCustomerRevision: String
    let transferReason: TransferReason
    let modelReason: String
    let replyText: String
    let createdAt: String
    let state: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case taskID = "task_id"
        case uid
        case sourceCustomerRevision = "source_customer_revision"
        case transferReason = "transfer_reason"
        case modelReason = "model_reason"
        case replyText = "reply_text"
        case createdAt = "created_at"
        case state
    }
}

struct TransferPlaceholderStore {
    let directory: URL
    private let encoder: JSONEncoder

    init(root: URL) {
        directory = root.appendingPathComponent("转人工任务/待实现", isDirectory: true)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    }

    @discardableResult
    func record(uid: String, customerRevision: String, reply: ReplyEnvelope, now: Date = Date()) throws -> URL {
        let taskID = TaskIdentity.make(uid: uid, historyVersion: customerRevision)
        let destination = directory.appendingPathComponent("\(taskID).json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        let value = TransferPlaceholder(
            schemaVersion: 1,
            taskID: taskID,
            uid: uid,
            sourceCustomerRevision: customerRevision,
            transferReason: reply.transferReason,
            modelReason: reply.reason,
            replyText: reply.replyText,
            createdAt: ISO8601DateFormatter().string(from: now),
            state: "placeholder"
        )
        let temporary = directory.appendingPathComponent(".\(taskID).\(UUID().uuidString).tmp")
        try encoder.encode(value).write(to: temporary, options: .atomic)
        do {
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            if !FileManager.default.fileExists(atPath: destination.path) { throw error }
        }
        return destination
    }
}
