import Foundation
import QianniuVideoProbeCore

enum VideoTransferPhase: String, Codable, Equatable, Sendable {
    case waitingForAddress
    case downloading
    case downloaded
    case failed
}

public struct VideoTransferInspection: Codable, Equatable, Sendable {
    public let bytes: Int64
    public let sha256: String
    public let durationSeconds: Double
    public let width: Int
    public let height: Int
    public let videoCodec: String
    public let audioCodec: String?

    public init(
        bytes: Int64,
        sha256: String,
        durationSeconds: Double,
        width: Int,
        height: Int,
        videoCodec: String,
        audioCodec: String?
    ) {
        self.bytes = bytes
        self.sha256 = sha256
        self.durationSeconds = durationSeconds
        self.width = width
        self.height = height
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
    }
}

public struct DownloadedCustomerVideo: Equatable, Sendable {
    public let customerUID: String
    public let messageHash: String
    public let fileURL: URL
    public let bytes: Int64
    public let completedAt: Date

    public init(customerUID: String, messageHash: String, fileURL: URL, bytes: Int64, completedAt: Date) {
        self.customerUID = customerUID
        self.messageHash = messageHash
        self.fileURL = fileURL
        self.bytes = bytes
        self.completedAt = completedAt
    }
}

private actor VideoTransferCompletionGate {
    private var emitted = false
    func claim() -> Bool {
        guard !emitted else { return false }
        emitted = true
        return true
    }
}

struct VideoTransferRecord: Codable, Equatable, Sendable {
    let messageHash: String
    let phase: VideoTransferPhase
    let fileName: String?
    let bytes: Int64?
    let sha256: String?
    let durationSeconds: Double?
    let width: Int?
    let height: Int?
    let videoCodec: String?
    let audioCodec: String?
    let updatedAt: Date
    let failure: String?
}

actor VideoTransferJournal {
    private struct Payload: Codable {
        var schemaVersion = 1
        var records: [VideoTransferRecord]
    }

    private let url: URL
    private let maximumRecords: Int
    private var payload: Payload?

    init(url: URL, maximumRecords: Int = 10_000) {
        self.url = url
        self.maximumRecords = max(1, maximumRecords)
    }

    func record(_ record: VideoTransferRecord) throws {
        var value = try load()
        value.records.removeAll { $0.messageHash == record.messageHash }
        value.records.append(record)
        if value.records.count > maximumRecords {
            value.records.removeFirst(value.records.count - maximumRecords)
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: url, options: .atomic)
        payload = value
    }

    func snapshot() throws -> [VideoTransferRecord] {
        try load().records
    }

    private func load() throws -> Payload {
        if let payload { return payload }
        let value: Payload
        if FileManager.default.fileExists(atPath: url.path) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            value = try decoder.decode(Payload.self, from: Data(contentsOf: url))
        } else {
            value = Payload(records: [])
        }
        payload = value
        return value
    }
}

struct VideoTransferJob: Sendable {
    typealias CandidateProvider = @Sendable () async throws -> URL
    typealias Download = @Sendable (URL, URL) async throws -> Int
    typealias Inspect = @Sendable (URL) async throws -> VideoTransferInspection
    typealias Now = @Sendable () -> Date
    typealias Completion = @Sendable (DownloadedCustomerVideo) async -> Void

    private let messageHash: String
    private let customerUID: String
    private let outputDirectory: URL
    private let journal: VideoTransferJournal
    private let candidateProvider: CandidateProvider
    private let download: Download
    private let inspect: Inspect
    private let now: Now
    private let completion: Completion?
    private let completionGate = VideoTransferCompletionGate()

    init(
        messageID: String,
        customerUID: String = "",
        outputDirectory: URL,
        journal: VideoTransferJournal,
        candidateProvider: @escaping CandidateProvider,
        download: @escaping Download,
        inspect: @escaping Inspect,
        completion: Completion? = nil,
        now: @escaping Now = { Date() }
    ) {
        messageHash = VideoTransferIdentity.hash(messageID)
        self.customerUID = customerUID
        self.outputDirectory = outputDirectory
        self.journal = journal
        self.candidateProvider = candidateProvider
        self.download = download
        self.inspect = inspect
        self.completion = completion
        self.now = now
    }

    func run() async {
        let finalURL = outputDirectory.appendingPathComponent("\(messageHash).mp4")
        let partialURL = outputDirectory.appendingPathComponent(".\(messageHash).\(UUID().uuidString).partial.mp4")
        defer {
            if FileManager.default.fileExists(atPath: partialURL.path) {
                try? FileManager.default.removeItem(at: partialURL)
            }
        }
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            try await journal.record(record(phase: .waitingForAddress))
            let candidate: URL
            do {
                candidate = try await candidateProvider()
            } catch {
                try await journal.record(record(
                    phase: .failed,
                    failure: "未能从千牛新增日志取得视频地址"
                ))
                return
            }
            try await journal.record(record(phase: .downloading))
            do {
                _ = try await download(candidate, partialURL)
            } catch {
                try await journal.record(record(phase: .failed, failure: "视频后台下载失败"))
                return
            }
            let inspection: VideoTransferInspection
            do {
                inspection = try await inspect(partialURL)
            } catch {
                try await journal.record(record(phase: .failed, failure: "下载内容不是有效视频"))
                return
            }
            if FileManager.default.fileExists(atPath: finalURL.path) {
                try FileManager.default.removeItem(at: partialURL)
            } else {
                try FileManager.default.moveItem(at: partialURL, to: finalURL)
            }
            try await journal.record(record(
                phase: .downloaded,
                fileName: finalURL.lastPathComponent,
                inspection: inspection
            ))
            if await completionGate.claim() {
                await completion?(DownloadedCustomerVideo(
                    customerUID: customerUID,
                    messageHash: messageHash,
                    fileURL: finalURL,
                    bytes: inspection.bytes,
                    completedAt: now()
                ))
            }
        } catch {
            try? await journal.record(record(phase: .failed, failure: "视频文件保存失败"))
        }
    }

    private func record(
        phase: VideoTransferPhase,
        fileName: String? = nil,
        inspection: VideoTransferInspection? = nil,
        failure: String? = nil
    ) -> VideoTransferRecord {
        VideoTransferRecord(
            messageHash: messageHash,
            phase: phase,
            fileName: fileName,
            bytes: inspection?.bytes,
            sha256: inspection?.sha256,
            durationSeconds: inspection?.durationSeconds,
            width: inspection?.width,
            height: inspection?.height,
            videoCodec: inspection?.videoCodec,
            audioCodec: inspection?.audioCodec,
            updatedAt: now(),
            failure: failure
        )
    }

}

/// Starts one background download and deliberately does not inspect or retry.
/// The caller is released as soon as the request has been started, while an
/// observer may receive start/completion events without blocking the UI lane.
public struct BestEffortVideoDownloadCompletion: Equatable, Sendable {
    public let messageID: String
    public let messageHash: String
    public let customerUID: String
    public let startedAt: Date
    public let completedAt: Date
    public let fileURL: URL
    public let bytes: Int

    public init(
        messageID: String,
        messageHash: String,
        customerUID: String,
        startedAt: Date,
        completedAt: Date,
        fileURL: URL,
        bytes: Int
    ) {
        self.messageID = messageID
        self.messageHash = messageHash
        self.customerUID = customerUID
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.fileURL = fileURL
        self.bytes = bytes
    }
}

struct BestEffortVideoDownloadJob: Sendable {
    typealias CandidateProvider = @Sendable () async throws -> URL
    typealias Download = @Sendable (URL, URL) async throws -> Void
    typealias Clock = @Sendable () -> Date
    typealias Started = @Sendable (String, Date) async -> Void
    typealias Completed = @Sendable (BestEffortVideoDownloadCompletion) async -> Void

    private let messageID: String
    private let customerUID: String
    private let messageHash: String
    private let outputDirectory: URL
    private let candidateProvider: CandidateProvider
    private let download: Download
    private let now: Clock
    private let onStarted: Started
    private let onCompleted: Completed

    init(
        messageID: String,
        customerUID: String = "",
        outputDirectory: URL,
        candidateProvider: @escaping CandidateProvider,
        download: @escaping Download,
        now: @escaping Clock = { Date() },
        onStarted: @escaping Started = { _, _ in },
        onCompleted: @escaping Completed = { _ in }
    ) {
        self.messageID = messageID
        self.customerUID = customerUID
        messageHash = VideoTransferIdentity.hash(messageID)
        self.outputDirectory = outputDirectory
        self.candidateProvider = candidateProvider
        self.download = download
        self.now = now
        self.onStarted = onStarted
        self.onCompleted = onCompleted
    }

    func run() async {
        let startedAt = now()
        await onStarted(messageID, startedAt)
        do {
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )
            let source = try await candidateProvider()
            let destination = outputDirectory.appendingPathComponent("\(messageHash).mp4")
            try await download(source, destination)
            let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
            let bytes = (attributes[.size] as? NSNumber)?.intValue ?? 0
            await onCompleted(BestEffortVideoDownloadCompletion(
                messageID: messageID,
                messageHash: messageHash,
                customerUID: customerUID,
                startedAt: startedAt,
                completedAt: now(),
                fileURL: destination,
                bytes: bytes
            ))
        } catch {}
    }
}

private actor ArmedVideoCandidateSource {
    private var watcher: ArmedVideoCandidateWatcher

    init(watcher: ArmedVideoCandidateWatcher) {
        self.watcher = watcher
    }

    func wait() async throws -> URL {
        var local = watcher
        let result = try await local.wait()
        watcher = local
        return result
    }
}

@MainActor
private final class BackgroundArmedVideoTransfer: ArmedVideoTransfer {
    private let job: VideoTransferJob
    private var started = false

    init(job: VideoTransferJob) {
        self.job = job
    }

    func start() {
        guard !started else { return }
        started = true
        let job = job
        Task.detached(priority: .utility) {
            await job.run()
        }
    }
}

@MainActor
private final class BestEffortArmedVideoTransfer: ArmedVideoTransfer {
    private let job: BestEffortVideoDownloadJob
    private var started = false

    init(job: BestEffortVideoDownloadJob) {
        self.job = job
    }

    func start() {
        guard !started else { return }
        started = true
        let job = job
        Task.detached(priority: .utility) { await job.run() }
    }
}

@MainActor
final class QianniuBestEffortVideoTransferArmer: VideoTransferArming {
    private let logURLs: [URL]
    private let outputDirectory: URL
    private let onStarted: BestEffortVideoDownloadJob.Started
    private let onCompleted: BestEffortVideoDownloadJob.Completed

    init(
        logURLs: [URL],
        outputDirectory: URL,
        onStarted: @escaping BestEffortVideoDownloadJob.Started = { _, _ in },
        onCompleted: @escaping BestEffortVideoDownloadJob.Completed = { _ in }
    ) {
        self.logURLs = logURLs
        self.outputDirectory = outputDirectory
        self.onStarted = onStarted
        self.onCompleted = onCompleted
    }

    func arm(messageID: String, customerUID: String = "") -> (any ArmedVideoTransfer)? {
        guard !messageID.isEmpty,
              let watcher = try? VideoCandidateWatcher().arm(in: logURLs) else {
            return nil
        }
        let candidateSource = ArmedVideoCandidateSource(watcher: watcher)
        let job = BestEffortVideoDownloadJob(
            messageID: messageID,
            customerUID: customerUID,
            outputDirectory: outputDirectory,
            candidateProvider: { try await candidateSource.wait() },
            download: { source, destination in
                _ = try await VideoDownloadClient().download(from: source, to: destination)
            },
            onStarted: onStarted,
            onCompleted: onCompleted
        )
        return BestEffortArmedVideoTransfer(job: job)
    }
}

@MainActor
final class QianniuLogVideoTransferArmer: VideoTransferArming {
    private let logURLs: [URL]
    private let outputDirectory: URL
    private let journal: VideoTransferJournal
    private let completion: VideoTransferJob.Completion?

    init(logURLs: [URL], outputDirectory: URL, journalURL: URL,
         completion: VideoTransferJob.Completion? = nil) {
        self.logURLs = logURLs
        self.outputDirectory = outputDirectory
        journal = VideoTransferJournal(url: journalURL)
        self.completion = completion
    }

    func arm(messageID: String, customerUID: String = "") -> (any ArmedVideoTransfer)? {
        guard !messageID.isEmpty,
              let watcher = try? VideoCandidateWatcher().arm(in: logURLs) else {
            return nil
        }
        let candidateSource = ArmedVideoCandidateSource(watcher: watcher)
        let job = VideoTransferJob(
            messageID: messageID,
            customerUID: customerUID,
            outputDirectory: outputDirectory,
            journal: journal,
            candidateProvider: { try await candidateSource.wait() },
            download: { source, destination in
                try await VideoDownloadClient().download(from: source, to: destination).statusCode
            },
            inspect: { url in
                let value = try await VideoFileInspector.inspect(url)
                return VideoTransferInspection(
                    bytes: value.bytes,
                    sha256: value.sha256,
                    durationSeconds: value.durationSeconds,
                    width: value.width,
                    height: value.height,
                    videoCodec: value.videoCodec,
                    audioCodec: value.audioCodec
                )
            },
            completion: completion
        )
        return BackgroundArmedVideoTransfer(job: job)
    }
}

private actor ResilientArmedVideoCandidateSource {
    private var watcher: ArmedVideoCandidateWatcher

    init(watcher: ArmedVideoCandidateWatcher) {
        self.watcher = watcher
    }

    func wait() async throws -> URL {
        var local = watcher
        let result = try await local.wait()
        watcher = local
        return result
    }
}

@MainActor
private final class CoordinatorArmedVideoTransfer: ArmedVideoTransfer {
    private let source: ResilientArmedVideoCandidateSource
    private let key: VideoTransferKey
    private let customerUID: String
    private let coordinator: VideoTransferCoordinator
    private var started = false

    init(
        source: ResilientArmedVideoCandidateSource,
        key: VideoTransferKey,
        customerUID: String,
        coordinator: VideoTransferCoordinator
    ) {
        self.source = source
        self.key = key
        self.customerUID = customerUID
        self.coordinator = coordinator
    }

    func start() {
        guard !started else { return }
        started = true
        let source = source
        let key = key
        let customerUID = customerUID
        let coordinator = coordinator
        Task.detached(priority: .utility) {
            do {
                let address = try await source.wait()
                await coordinator.submitCapturedAddress(
                    key: key,
                    source: address,
                    customerUID: customerUID
                )
            } catch {
                await coordinator.reportAddressCaptureFailure(
                    key: key,
                    customerUID: customerUID
                )
            }
        }
    }

}

@MainActor
final class QianniuResilientVideoTransferArmer: VideoTransferArming {
    private let logURLs: [URL]
    private let coordinator: VideoTransferCoordinator

    init(logURLs: [URL], coordinator: VideoTransferCoordinator) {
        self.logURLs = logURLs
        self.coordinator = coordinator
    }

    func arm(messageID: String, customerUID: String) -> (any ArmedVideoTransfer)? {
        guard !messageID.isEmpty,
              !customerUID.isEmpty,
              let watcher = try? VideoCandidateWatcher().arm(in: logURLs) else {
            return nil
        }
        return CoordinatorArmedVideoTransfer(
            source: ResilientArmedVideoCandidateSource(watcher: watcher),
            key: VideoTransferIdentity.key(customerUID: customerUID, messageID: messageID),
            customerUID: customerUID,
            coordinator: coordinator
        )
    }
}
