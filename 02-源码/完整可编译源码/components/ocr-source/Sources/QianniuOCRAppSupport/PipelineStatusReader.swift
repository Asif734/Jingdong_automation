import Foundation

public enum PipelineStage: String, Equatable, Sendable {
    case idle
    case queued
    case generating
    case awaitingSend
    case sending
    case humanReview
    case failed
    case completed

    public var label: String {
        switch self {
        case .idle: "等待新消息"
        case .queued: "已加入队列"
        case .generating: "Codex 正在生成回复"
        case .awaitingSend: "回复已生成，等待发送"
        case .sending: "正在发送到千牛"
        case .humanReview: "等待人工确认"
        case .failed: "处理失败"
        case .completed: "最近一次处理完成"
        }
    }
}

public struct PipelineCounts: Equatable, Sendable {
    public var queued = 0
    public var generating = 0
    public var awaitingSend = 0
    public var sending = 0
    public var humanReview = 0
    public var failed = 0
    public var completed = 0

    public var totalActive: Int {
        queued + generating + awaitingSend + sending
    }
}

public struct PipelineStatusSnapshot: Equatable, Sendable {
    public let stage: PipelineStage
    public let currentUID: String?
    public let detail: String?
    public let counts: PipelineCounts
    public let updatedAt: Date?
    public var earlierWarning: String? = nil

    public var headline: String { stage.label }

    public static let idle = PipelineStatusSnapshot(
        stage: .idle,
        currentUID: nil,
        detail: nil,
        counts: PipelineCounts(),
        updatedAt: nil
    )
}

public final class PipelineStatusReader {
    private let root: URL
    private let fileManager: FileManager
    private var activeRecordCache: [String: CachedDirectory] = [:]
    private var completedDirectorySignature: [DirectoryStamp]?
    private var completedRecordCache: [Record] = []

    public init(root: URL, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
    }

    public func read() -> PipelineStatusSnapshot {
        let queued = records(in: "待处理")
        let claimed = records(in: "处理中")
        let awaitingSend = records(in: "待发送")
        let sending = records(in: "发送中")
        let humanReview = records(in: "待人工确认")
        let failed = records(in: "失败") + records(in: "发送失败")
        let completed = completedRecords()
        let publishedTaskIDs = Set(
            (awaitingSend + sending + humanReview + failed + completed).map(\.taskID)
        )
        let generating = claimed.filter { !publishedTaskIDs.contains($0.taskID) }

        let counts = PipelineCounts(
            queued: queued.count,
            generating: generating.count,
            awaitingSend: awaitingSend.count,
            sending: sending.count,
            humanReview: humanReview.count,
            failed: failed.count,
            completed: completed.count
        )

        let activeCandidates: [(PipelineStage, [Record])] = [
            (.sending, sending),
            (.awaitingSend, awaitingSend),
            (.generating, generating),
            (.queued, queued),
        ]
        let terminalCandidates: [(PipelineStage, Record)] =
            humanReview.map { (.humanReview, $0) }
            + failed.map { (.failed, $0) }
            + completed.map { (.completed, $0) }
        let selected = activeCandidates.first(where: { !$0.1.isEmpty }).flatMap { stage, records in
            records.max(by: { $0.modifiedAt < $1.modifiedAt }).map { (stage, $0) }
        } ?? terminalCandidates.max(by: { $0.1.modifiedAt < $1.1.modifiedAt })
        guard let (stage, record) = selected else {
            return PipelineStatusSnapshot(
                stage: .idle,
                currentUID: nil,
                detail: nil,
                counts: counts,
                updatedAt: nil
            )
        }
        var snapshot = PipelineStatusSnapshot(
            stage: stage,
            currentUID: record.uid,
            detail: [.failed, .humanReview].contains(stage) ? record.error : nil,
            counts: counts,
            updatedAt: record.modifiedAt
        )
        if let warning = (humanReview + failed)
            .filter({ $0.taskID != record.taskID })
            .max(by: { $0.modifiedAt < $1.modifiedAt }) {
            let formatter = DateFormatter()
            formatter.dateFormat = "MM-dd HH:mm:ss"
            snapshot.earlierWarning = "另有未处理警告 · \(formatter.string(from: warning.modifiedAt)) · \(warning.uid ?? "未知用户")：\(warning.error ?? "待核实")"
        }
        return snapshot
    }

    private func records(in directoryName: String, recursive: Bool = false) -> [Record] {
        let directory = root.appendingPathComponent(directoryName, isDirectory: true)
        let directoryModifiedAt = (try? directory.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate) ?? .distantPast
        if !recursive,
           let cached = activeRecordCache[directoryName],
           cached.modifiedAt == directoryModifiedAt {
            return cached.records
        }
        let urls: [URL]
        if recursive {
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }
            urls = enumerator.compactMap { $0 as? URL }
        } else {
            urls = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )) ?? []
        }
        let parsed = urls.compactMap(record)
        if !recursive {
            activeRecordCache[directoryName] = CachedDirectory(
                modifiedAt: directoryModifiedAt,
                records: parsed
            )
        }
        return parsed
    }

    private func completedRecords() -> [Record] {
        let directory = root.appendingPathComponent("已完成", isDirectory: true)
        let children = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let signature = children.compactMap { url -> DirectoryStamp? in
            guard let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .isDirectoryKey, .isRegularFileKey]
            ), values.isDirectory == true || (values.isRegularFile == true && url.pathExtension == "json") else {
                return nil
            }
            return DirectoryStamp(
                path: url.path,
                modifiedAt: values.contentModificationDate ?? .distantPast
            )
        }.sorted { $0.path < $1.path }

        if signature == completedDirectorySignature {
            return completedRecordCache
        }
        let refreshed = records(in: "已完成", recursive: true)
        completedDirectorySignature = signature
        completedRecordCache = refreshed
        return refreshed
    }

    private func record(at url: URL) -> Record? {
        guard url.pathExtension.lowercased() == "json",
              !url.lastPathComponent.hasPrefix("."),
              let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
              values.isRegularFile == true,
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let uid = nonEmptyString(object["uid"])
        let error = nonEmptyString(object["send_error"])
            ?? nonEmptyString(object["error"])
            ?? nonEmptyString(object["reason"])
        return Record(
            taskID: url.deletingPathExtension().lastPathComponent,
            uid: uid,
            error: error,
            modifiedAt: values.contentModificationDate ?? .distantPast
        )
    }

    private func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct Record {
    let taskID: String
    let uid: String?
    let error: String?
    let modifiedAt: Date
}

private struct DirectoryStamp: Equatable {
    let path: String
    let modifiedAt: Date
}

private struct CachedDirectory {
    let modifiedAt: Date
    let records: [Record]
}
