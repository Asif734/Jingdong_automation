import Foundation
import CustomerReplyBatchCore

public struct BatchTimingRecord: Codable, Sendable {
    public let createdAt: String
    public let uid: String
    public let taskID: String
    public let decision: String
    public let model: String?
    public let reasoningEffort: String?
    public let queueWaitMilliseconds: Double?
    public let promptLoadMilliseconds: Double
    public let loginCheckMilliseconds: Double
    public let codexExecMilliseconds: Double
    public let decodeMilliseconds: Double
    public let publishMilliseconds: Double
    public let taskProcessingMilliseconds: Double
    public var cliTraceReportPath: String? = nil
    public var sessionMode: String? = nil
    public var submittedHistoryBytes: Int = 0
    public var submittedImageCount: Int = 0
    public var sessionLeaseAgeMilliseconds: Double? = nil
    public var sessionRecoveryCount: Int = 0

    enum CodingKeys: String, CodingKey {
        case createdAt = "created_at"
        case uid
        case taskID = "task_id"
        case decision
        case model
        case reasoningEffort = "reasoning_effort"
        case queueWaitMilliseconds = "queue_wait_ms"
        case promptLoadMilliseconds = "prompt_load_ms"
        case loginCheckMilliseconds = "login_check_ms"
        case codexExecMilliseconds = "codex_exec_ms"
        case decodeMilliseconds = "decode_ms"
        case publishMilliseconds = "publish_ms"
        case taskProcessingMilliseconds = "task_processing_ms"
        case cliTraceReportPath = "cli_trace_report_path"
        case sessionMode = "session_mode"
        case submittedHistoryBytes = "submitted_history_bytes"
        case submittedImageCount = "submitted_image_count"
        case sessionLeaseAgeMilliseconds = "session_lease_age_ms"
        case sessionRecoveryCount = "session_recovery_count"
    }
}

public final class BatchTimingLogger: @unchecked Sendable {
    private let runtimeDirectory: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private let onWarning: @Sendable (String) -> Void

    public init(
        runtimeDirectory: URL,
        fileManager: FileManager = .default,
        onWarning: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.runtimeDirectory = runtimeDirectory
        self.fileManager = fileManager
        self.onWarning = onWarning
    }

    public func record(_ value: BatchTimingRecord) {
        lock.lock()
        defer { lock.unlock() }
        do {
            try recordThrowing(value)
        } catch {
            onWarning("Timing log unavailable: \(error.localizedDescription)")
        }
    }

    private func recordThrowing(_ value: BatchTimingRecord) throws {
        try fileManager.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var line = try encoder.encode(value)
        line.append(0x0A)
        let jsonl = runtimeDirectory.appendingPathComponent("耗时日志.jsonl")
        if !fileManager.fileExists(atPath: jsonl.path) {
            _ = fileManager.createFile(atPath: jsonl.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: jsonl)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)

        let latest = runtimeDirectory.appendingPathComponent("最近一次耗时.txt")
        try Data(readable(value).utf8).write(to: latest, options: .atomic)
    }

    private func readable(_ value: BatchTimingRecord) -> String {
        let queueWait = value.queueWaitMilliseconds.map { format($0) + " ms" } ?? "无法计算"
        return """
        AI 客服最近一次耗时

        生成时间：\(value.createdAt)
        UID：\(value.uid)
        任务 ID：\(value.taskID)
        处理决定：\(value.decision)
        模型：\(value.model ?? "未记录")
        推理强度：\(value.reasoningEffort ?? "未记录")
        会话模式：\(value.sessionMode ?? "未记录")
        本轮提交历史：\(value.submittedHistoryBytes) bytes
        本轮提交图片：\(value.submittedImageCount)
        会话闲置时长：\(value.sessionLeaseAgeMilliseconds.map { format($0) + " ms" } ?? "新会话")
        会话恢复次数：\(value.sessionRecoveryCount)

        排队及启动：\(queueWait)
        提示词读取：\(format(value.promptLoadMilliseconds)) ms
        登录检查：\(format(value.loginCheckMilliseconds)) ms
        Codex 执行（至结果可用）：\(format(value.codexExecMilliseconds)) ms
        CLI 内部步骤明细：\(value.cliTraceReportPath ?? "未记录")
        结果解析：\(format(value.decodeMilliseconds)) ms
        结果发布：\(format(value.publishMilliseconds)) ms
        任务处理合计：\(format(value.taskProcessingMilliseconds)) ms

        """
    }

    private func format(_ value: Double) -> String {
        String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
