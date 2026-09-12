import Foundation
import Darwin

public struct QueueLayout: Sendable {
    public let root: URL
    public var pending: URL { root.appendingPathComponent("待处理", isDirectory: true) }
    public var processing: URL { root.appendingPathComponent("处理中", isDirectory: true) }
    public var outgoing: URL { root.appendingPathComponent("待发送", isDirectory: true) }
    public var humanReview: URL { root.appendingPathComponent("待人工确认", isDirectory: true) }
    public var completed: URL { root.appendingPathComponent("已完成", isDirectory: true) }
    public var failed: URL { root.appendingPathComponent("失败", isDirectory: true) }
    public var runtime: URL { root.appendingPathComponent("运行状态", isDirectory: true) }
    public var testReplies: URL { root.appendingPathComponent("测试回复", isDirectory: true) }
}

public final class BatchLock {
    private let url: URL
    private let fileManager: FileManager

    init(url: URL, fileManager: FileManager) {
        self.url = url
        self.fileManager = fileManager
    }

    deinit { try? fileManager.removeItem(at: url) }
}

public struct PublishedReply: Codable, Sendable {
    public let schemaVersion: Int
    public let taskID: String
    public let uid: String
    public let sourceHistoryVersion: String
    public let sourceTask: String
    public let decision: ReplyDecision
    public let riskLevel: RiskLevel
    public let action: ReplyAction
    public let replyText: String
    public let transferReason: TransferReason
    public let reason: String
    public let createdAt: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case taskID = "task_id"
        case uid
        case sourceHistoryVersion = "source_history_version"
        case sourceTask = "source_task"
        case decision
        case riskLevel = "risk_level"
        case action
        case replyText = "reply_text"
        case transferReason = "transfer_reason"
        case reason
        case createdAt = "created_at"
    }
}

public enum QueueStoreError: LocalizedError {
    case batchAlreadyRunning
    case missingSource(URL)

    public var errorDescription: String? {
        switch self {
        case .batchAlreadyRunning: return "已有一个批处理正在运行"
        case .missingSource(let url): return "待处理文件不存在：\(url.path)"
        }
    }
}

public final class QueueStore {
    public let layout: QueueLayout
    private let fileManager: FileManager
    private let encoder: JSONEncoder

    public init(root: URL, fileManager: FileManager = .default) throws {
        self.layout = QueueLayout(root: root)
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        for url in [layout.pending, layout.processing, layout.outgoing, layout.humanReview, layout.completed, layout.failed, layout.runtime, layout.testReplies] {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    public func acquireBatchLock() throws -> BatchLock {
        let lockURL = layout.runtime.appendingPathComponent("batch.lock", isDirectory: true)
        do {
            try fileManager.createDirectory(at: lockURL, withIntermediateDirectories: false)
        } catch {
            throw QueueStoreError.batchAlreadyRunning
        }
        return BatchLock(url: lockURL, fileManager: fileManager)
    }

    public func requestRun() throws {
        let marker = layout.runtime.appendingPathComponent("needs-run")
        try atomicWrite(Data(ISO8601DateFormatter().string(from: Date()).utf8), to: marker)
    }

    public func consumeRunRequest() throws {
        let marker = layout.runtime.appendingPathComponent("needs-run")
        if fileManager.fileExists(atPath: marker.path) {
            try fileManager.removeItem(at: marker)
        }
    }

    public func hasRunRequest() -> Bool {
        fileManager.fileExists(
            atPath: layout.runtime.appendingPathComponent("needs-run").path
        )
    }

    public func hasPendingTasks() -> Bool {
        guard let names = try? fileManager.contentsOfDirectory(atPath: layout.pending.path) else {
            return false
        }
        return names.contains { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
    }

    public func latestHistoryVersion(uid: String) -> String? {
        let pending = layout.pending.appendingPathComponent("\(uid).json")
        if let data = try? Data(contentsOf: pending),
           let pointer = try? JSONDecoder().decode(QueuePointer.self, from: data) {
            return pointer.historyVersion
        }
        return nil
    }

    public func writePending(_ pointer: QueuePointer) throws {
        try atomicWrite(try encoder.encode(pointer), to: layout.pending.appendingPathComponent("\(pointer.uid).json"))
    }

    public func claim(_ pointer: QueuePointer) throws -> ClaimedTask {
        let taskID = TaskIdentity.make(uid: pointer.uid, historyVersion: pointer.historyVersion)
        let source = pointer.sourceURL ?? layout.pending.appendingPathComponent("\(pointer.uid).json")
        let destination = layout.processing.appendingPathComponent("\(taskID).json")
        guard fileManager.fileExists(atPath: source.path) else { throw QueueStoreError.missingSource(source) }
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.moveItem(at: source, to: destination)
        return ClaimedTask(pointer: pointer, taskID: taskID, claimURL: destination)
    }

    @discardableResult
    public func publish(_ reply: ReplyEnvelope, for task: ClaimedTask, now: Date = Date()) throws -> URL {
        let value = PublishedReply(
            schemaVersion: 1,
            taskID: task.taskID,
            uid: task.pointer.uid,
            sourceHistoryVersion: task.pointer.historyVersion,
            sourceTask: task.claimURL.path,
            decision: reply.decision,
            riskLevel: reply.riskLevel,
            action: reply.action,
            replyText: reply.replyText,
            transferReason: reply.transferReason,
            reason: reply.reason,
            createdAt: ISO8601DateFormatter().string(from: now)
        )
        let directory: URL
        switch reply.decision {
        case .autoSend: directory = layout.outgoing
        case .humanReview: directory = layout.humanReview
        case .noAction:
            directory = layout.completed.appendingPathComponent(task.pointer.uid, isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let data = try encoder.encode(value)
        let destination = directory.appendingPathComponent("\(task.taskID).json")
        let testDirectory = layout.testReplies
            .appendingPathComponent(task.pointer.uid, isDirectory: true)
        let testJSON = testDirectory.appendingPathComponent("\(task.taskID).json")
        let testText = testDirectory.appendingPathComponent("\(task.taskID).txt")
        do {
            try atomicWrite(data, to: testJSON)
            try atomicWrite(readableReply(value), to: testText)
            try atomicWrite(data, to: destination)
        } catch {
            try? fileManager.removeItem(at: testJSON)
            try? fileManager.removeItem(at: testText)
            throw error
        }
        if reply.decision == .noAction { try? fileManager.removeItem(at: task.claimURL) }
        return destination
    }

    public func outputExists(taskID: String) -> Bool {
        let candidates = [
            layout.outgoing.appendingPathComponent("\(taskID).json"),
            layout.humanReview.appendingPathComponent("\(taskID).json")
        ]
        if candidates.contains(where: { fileManager.fileExists(atPath: $0.path) }) { return true }
        guard let users = try? fileManager.contentsOfDirectory(at: layout.completed, includingPropertiesForKeys: nil) else { return false }
        return users.contains { fileManager.fileExists(atPath: $0.appendingPathComponent("\(taskID).json").path) }
    }

    public func recordFailure(for task: ClaimedTask, error: Error) throws {
        let value: [String: String] = [
            "task_id": task.taskID,
            "uid": task.pointer.uid,
            "error": error.localizedDescription,
            "failed_at": ISO8601DateFormatter().string(from: Date()),
            "source_task": task.claimURL.path
        ]
        try atomicWrite(try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), to: layout.failed.appendingPathComponent("\(task.taskID).json"))
    }

    public func removeClaim(_ task: ClaimedTask) throws {
        if fileManager.fileExists(atPath: task.claimURL.path) { try fileManager.removeItem(at: task.claimURL) }
    }

    @discardableResult
    public func recoverStaleClaims(olderThan age: TimeInterval, now: Date = Date()) throws -> Int {
        let urls = try fileManager.contentsOfDirectory(at: layout.processing, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension.lowercased() == "json" }
        var recovered = 0
        for url in urls {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
            guard let modified = values.contentModificationDate, now.timeIntervalSince(modified) >= age else { continue }
            let taskID = url.deletingPathExtension().lastPathComponent
            guard !outputExists(taskID: taskID) else { continue }
            let pointer = try JSONDecoder().decode(QueuePointer.self, from: Data(contentsOf: url))
            let pending = layout.pending.appendingPathComponent("\(pointer.uid).json")
            if fileManager.fileExists(atPath: pending.path) {
                try fileManager.removeItem(at: url)
            } else {
                try fileManager.moveItem(at: url, to: pending)
            }
            recovered += 1
        }
        return recovered
    }

    private func atomicWrite(_ data: Data, to destination: URL) throws {
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.moveItem(at: temporary, to: destination)
    }

    private func readableReply(_ reply: PublishedReply) -> Data {
        let text = """
        仅供测试，尚未发送

        UID：\(reply.uid)
        任务 ID：\(reply.taskID)
        生成时间：\(reply.createdAt)
        处理决定：\(reply.decision.rawValue)
        风险等级：\(reply.riskLevel.rawValue)

        建议回复：
        \(reply.replyText)

        判断依据：
        \(reply.reason)

        """
        return Data(text.utf8)
    }
}
