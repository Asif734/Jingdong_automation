import Foundation

public struct PromptImageUsageRecord: Codable, Equatable, Sendable {
    public let createdAt: String
    public let uid: String
    public let taskID: String
    public let imagePaths: [String]

    enum CodingKeys: String, CodingKey {
        case createdAt = "created_at"
        case uid
        case taskID = "task_id"
        case imagePaths = "image_paths"
    }
}

public protocol PromptImageUsageRecording: Sendable {
    func record(uid: String, taskID: String, imagePaths: [String]) async
}

public actor PromptImageUsageLogger: PromptImageUsageRecording {
    private let runtimeDirectory: URL
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private let onWarning: @Sendable (String) -> Void

    public init(
        runtimeDirectory: URL,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() },
        onWarning: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.runtimeDirectory = runtimeDirectory
        self.fileManager = fileManager
        self.now = now
        self.onWarning = onWarning
    }

    public func record(uid: String, taskID: String, imagePaths: [String]) async {
        do {
            let record = PromptImageUsageRecord(
                createdAt: ISO8601DateFormatter().string(from: now()),
                uid: uid,
                taskID: taskID,
                imagePaths: imagePaths
            )
            let directory = runtimeDirectory.appendingPathComponent("Codex图片", isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try (encoder.encode(record) + Data([0x0A])).write(
                to: directory.appendingPathComponent("\(taskID).json"),
                options: .atomic
            )
            let pathsText = imagePaths.isEmpty
                ? "（本任务没有图片）"
                : imagePaths.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            let readable = """
            本次实际交给 Codex 的图片
            时间：\(record.createdAt)
            UID：\(uid)
            任务：\(taskID)
            图片数量：\(imagePaths.count)

            \(pathsText)
            """
            try Data((readable + "\n").utf8).write(
                to: runtimeDirectory.appendingPathComponent("最近一次Codex图片.txt"),
                options: .atomic
            )
        } catch {
            // Observability must never change queue processing or reply behavior.
            onWarning("Prompt image usage log unavailable: \(error.localizedDescription)")
        }
    }
}
