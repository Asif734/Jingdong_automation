import Foundation

public struct SenderQueueLayout: Sendable {
    public let root: URL
    public var pending: URL { root.appendingPathComponent("待发送", isDirectory: true) }
    public var sending: URL { root.appendingPathComponent("发送中", isDirectory: true) }
    public var batchProcessing: URL { root.appendingPathComponent("处理中", isDirectory: true) }
    public var failed: URL { root.appendingPathComponent("发送失败", isDirectory: true) }
    public var humanReview: URL { root.appendingPathComponent("待人工确认", isDirectory: true) }
    public var completed: URL { root.appendingPathComponent("已完成", isDirectory: true) }
    public var runtime: URL { root.appendingPathComponent("运行状态", isDirectory: true) }
}

public final class SenderQueueStore: @unchecked Sendable {
    public let layout: SenderQueueLayout
    private let fileManager: FileManager
    private let encoder: JSONEncoder

    public init(root: URL, fileManager: FileManager = .default) throws {
        self.layout = SenderQueueLayout(root: root)
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        for directory in [layout.pending, layout.sending, layout.batchProcessing, layout.failed, layout.humanReview, layout.completed, layout.runtime] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    public func snapshot() throws -> [OutgoingTask] {
        let urls = try fileManager.contentsOfDirectory(at: layout.pending, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "json" && !$0.lastPathComponent.hasPrefix(".") }
        let tasks = try urls.map { url -> OutgoingTask in
            var task = try JSONDecoder().decode(OutgoingTask.self, from: Data(contentsOf: url))
            try validate(task, fileURL: url)
            task.sourceURL = url
            return task
        }
        return tasks.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.taskID < $1.taskID
        }
    }

    public func claim(_ task: OutgoingTask) throws -> ClaimedOutgoingTask {
        let source = task.sourceURL ?? layout.pending.appendingPathComponent("\(task.taskID).json")
        guard fileManager.fileExists(atPath: source.path) else { throw SenderQueueError.missingTask(source) }
        let destination = layout.sending.appendingPathComponent("\(task.taskID).json")
        if fileManager.fileExists(atPath: destination.path) {
            throw SenderQueueError.invalidTask("发送中已存在同名任务 \(task.taskID)")
        }
        try fileManager.moveItem(at: source, to: destination)
        return ClaimedOutgoingTask(task: task, claimURL: destination)
    }

    public func complete(_ claimed: ClaimedOutgoingTask, sentAt: String) throws {
        let destinationDirectory = layout.completed.appendingPathComponent(claimed.task.uid, isDirectory: true)
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let destination = destinationDirectory.appendingPathComponent("\(claimed.task.taskID).json")
        try atomicWrite(try archiveData(task: claimed.task, extra: ["sent_at": sentAt, "send_status": "sent"]), to: destination)
        removeIfPresent(claimed.claimURL)
        removeIfPresent(layout.batchProcessing.appendingPathComponent("\(claimed.task.taskID).json"))
    }

    public func failBeforeSend(_ claimed: ClaimedOutgoingTask, reason: String, failedAt: String) throws {
        let destination = layout.failed.appendingPathComponent("\(claimed.task.taskID).json")
        try atomicWrite(
            try archiveData(task: claimed.task, extra: [
                "send_status": "failed_before_send",
                "send_error": reason,
                "failed_at": failedAt,
            ]),
            to: destination
        )
        removeIfPresent(claimed.claimURL)
    }

    public func markUncertain(_ claimed: ClaimedOutgoingTask, reason: String, attemptedAt: String) throws {
        let destination = layout.humanReview.appendingPathComponent("\(claimed.task.taskID).json")
        try atomicWrite(
            try archiveData(task: claimed.task, extra: [
                "send_status": "uncertain_after_send",
                "send_error": reason,
                "attempted_at": attemptedAt,
            ]),
            to: destination
        )
        removeIfPresent(claimed.claimURL)
    }

    private func validate(_ task: OutgoingTask, fileURL: URL) throws {
        guard task.schemaVersion == 1 else { throw SenderQueueError.invalidTask("schema_version 必须为 1") }
        guard task.decision == "auto_send" else { throw SenderQueueError.invalidTask("decision 必须为 auto_send") }
        guard !task.taskID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SenderQueueError.invalidTask("task_id 为空") }
        guard fileURL.deletingPathExtension().lastPathComponent == task.taskID else { throw SenderQueueError.invalidTask("文件名与 task_id 不一致") }
        guard !task.uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SenderQueueError.invalidTask("uid 为空") }
        guard !task.replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SenderQueueError.invalidTask("reply_text 为空") }
    }

    private func archiveData(task: OutgoingTask, extra: [String: String]) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: encoder.encode(task)) as! [String: Any]
        for (key, value) in extra { object[key] = value }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private func atomicWrite(_ data: Data, to destination: URL) throws {
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.moveItem(at: temporary, to: destination)
    }

    private func removeIfPresent(_ url: URL) {
        if fileManager.fileExists(atPath: url.path) { try? fileManager.removeItem(at: url) }
    }
}
