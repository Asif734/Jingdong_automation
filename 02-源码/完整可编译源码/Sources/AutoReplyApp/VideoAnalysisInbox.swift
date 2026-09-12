import Foundation
import CryptoKit
import AutoReplyCore
import CustomerReplyBatchCore
import QianniuOCRAppSupport

enum VideoAnalysisPhase: String, Codable, Sendable {
    case downloaded, preparingEvidence, readyForGeneration, admitted, completed, failed
}

struct VideoAnalysisEntry: Codable, Equatable, Sendable {
    let customerUID: String
    let messageHash: String
    let videoFilePath: String
    let bytes: Int64
    var contentSHA256: String? = nil
    var completedAt: Date? = nil
    var phase: VideoAnalysisPhase
    var attempts: Int
    var updatedAt: Date
    var failure: String?
}

actor VideoAnalysisInbox {
    private struct Payload: Codable { var schemaVersion = 1; var entries: [VideoAnalysisEntry] }
    private let stateURL: URL
    private var cached: Payload?

    init(stateURL: URL) { self.stateURL = stateURL }

    @discardableResult
    func enqueue(_ receipt: DownloadedCustomerVideo) throws -> Bool {
        var payload = try load()
        guard !payload.entries.contains(where: { $0.messageHash == receipt.messageHash }) else { return false }
        let contentSHA256 = try? Self.sha256(of: receipt.fileURL)
        if let contentSHA256 {
            var hydratedExistingEntry = false
            for index in payload.entries.indices where payload.entries[index].customerUID == receipt.customerUID {
                if payload.entries[index].contentSHA256 == nil {
                    let existingURL = URL(fileURLWithPath: payload.entries[index].videoFilePath)
                    if let existingHash = try? Self.sha256(of: existingURL) {
                        payload.entries[index].contentSHA256 = existingHash
                        hydratedExistingEntry = true
                    }
                }
                if payload.entries[index].contentSHA256 == contentSHA256 {
                    if hydratedExistingEntry { try save(payload) }
                    return false
                }
            }
        }
        payload.entries.append(VideoAnalysisEntry(
            customerUID: receipt.customerUID,
            messageHash: receipt.messageHash,
            videoFilePath: receipt.fileURL.path,
            bytes: receipt.bytes,
            contentSHA256: contentSHA256,
            phase: .downloaded,
            attempts: 0,
            updatedAt: receipt.completedAt,
            failure: nil
        ))
        try save(payload)
        return true
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func pendingReceipts() throws -> [DownloadedCustomerVideo] {
        try load().entries.compactMap { entry in
            guard [.downloaded, .preparingEvidence, .readyForGeneration].contains(entry.phase)
                    || (entry.phase == .failed && entry.attempts < 2) else { return nil }
            return DownloadedCustomerVideo(customerUID: entry.customerUID, messageHash: entry.messageHash,
                                           fileURL: URL(fileURLWithPath: entry.videoFilePath),
                                           bytes: entry.bytes, completedAt: entry.updatedAt)
        }
    }

    func markPreparing(_ hash: String) throws -> Int {
        try update(hash) { entry in
            entry.phase = .preparingEvidence
            entry.attempts += 1
            entry.updatedAt = Date()
            entry.failure = nil
        }.attempts
    }

    func markReady(_ hash: String) throws { _ = try update(hash) { $0.phase = .readyForGeneration; $0.updatedAt = Date() } }
    func markAdmitted(_ hash: String) throws { _ = try update(hash) { $0.phase = .admitted; $0.updatedAt = Date() } }
    func markCompleted(_ hash: String) throws {
        _ = try update(hash) {
            let now = Date()
            $0.phase = .completed
            $0.updatedAt = now
            $0.completedAt = now
        }
    }
    func markFailed(_ hash: String, reason: String) throws {
        _ = try update(hash) { $0.phase = .failed; $0.failure = reason; $0.updatedAt = Date() }
    }

    func entries() throws -> [VideoAnalysisEntry] { try load().entries }

    private func update(_ hash: String, change: (inout VideoAnalysisEntry) -> Void) throws -> VideoAnalysisEntry {
        var payload = try load()
        guard let index = payload.entries.firstIndex(where: { $0.messageHash == hash }) else {
            throw NSError(domain: "VideoAnalysisInbox", code: 1)
        }
        change(&payload.entries[index])
        let value = payload.entries[index]
        try save(payload)
        return value
    }

    private func load() throws -> Payload {
        if let cached { return cached }
        let value: Payload
        if FileManager.default.fileExists(atPath: stateURL.path) {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            value = try decoder.decode(Payload.self, from: Data(contentsOf: stateURL))
        } else { value = Payload(entries: []) }
        cached = value
        return value
    }

    private func save(_ value: Payload) throws {
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: stateURL, options: .atomic)
        cached = value
    }
}

actor VideoTransferEventBridge {
    typealias AdmitPrepared = @MainActor @Sendable (
        _ uid: String,
        _ revision: String,
        _ historyJSONL: String,
        _ reply: ReplyEnvelope
    ) async -> PreparedReplyAdmission
    typealias AdmitDiscovery = @MainActor @Sendable (
        _ uid: String,
        _ sourceRevision: String
    ) async -> Bool
    typealias ReceiveDownloaded = @Sendable (DownloadedCustomerVideo) async -> Void
    typealias ReceiveStatus = @MainActor @Sendable (VideoTransferPublicStatus) async -> Void

    private let transferStore: DurableVideoTransferStore
    private let admitPrepared: AdmitPrepared
    private let admitDiscovery: AdmitDiscovery
    private let receiveDownloaded: ReceiveDownloaded
    private let receiveStatus: ReceiveStatus

    init(
        transferStore: DurableVideoTransferStore,
        admitPrepared: @escaping AdmitPrepared,
        admitDiscovery: @escaping AdmitDiscovery,
        receiveDownloaded: @escaping ReceiveDownloaded,
        receiveStatus: @escaping ReceiveStatus = { _ in }
    ) {
        self.transferStore = transferStore
        self.admitPrepared = admitPrepared
        self.admitDiscovery = admitDiscovery
        self.receiveDownloaded = receiveDownloaded
        self.receiveStatus = receiveStatus
    }

    func receive(_ event: VideoTransferEvent) async {
        switch event {
        case .downloaded(let receipt):
            await receiveDownloaded(receipt)

        case .immediateRoutesExhausted(let notice):
            let key = key(customerUID: notice.customerUID, messageHash: notice.messageHash)
            guard let record = try? await transferStore.record(key),
                  !record.fallbackAdmitted else { return }
            let admission = await admitPrepared(
                notice.customerUID,
                VideoDownloadFallbackReply.revision(messageHash: notice.messageHash),
                VideoDownloadFallbackReply.historyJSONL,
                VideoDownloadFallbackReply.envelope
            )
            if admission == .inserted || admission == .alreadyPresent {
                try? await transferStore.markFallbackAdmitted(key)
            }

        case .freshAddressNeeded(let request):
            let key = key(customerUID: request.customerUID, messageHash: request.messageHash)
            _ = await admitDiscovery(
                request.customerUID,
                "video-address-refresh:\(request.messageHash)"
            )
            // resume() owns a short coordinator lease while publishing this event.
            // Once the UI discovery is present (or already deduplicated), release it
            // so the newly captured signed address can start a transfer immediately.
            try? await transferStore.releaseLease(key)

        case .stateChanged(let status):
            await receiveStatus(status)
        }
    }

    private func key(customerUID: String, messageHash: String) -> VideoTransferKey {
        VideoTransferKey(
            customerHash: VideoTransferIdentity.hash(customerUID),
            messageHash: messageHash
        )
    }
}

actor VideoReceiptRelay {
    typealias Handler = @Sendable (DownloadedCustomerVideo) async -> Void
    private var handler: Handler?
    private var buffered: [DownloadedCustomerVideo] = []

    func receive(_ receipt: DownloadedCustomerVideo) async {
        if let handler { await handler(receipt) } else { buffered.append(receipt) }
    }

    func install(_ handler: @escaping Handler) async {
        self.handler = handler
        let values = buffered
        buffered.removeAll()
        for value in values { await handler(value) }
    }
}

actor VideoAnalysisCoordinator {
    typealias Admit = @MainActor @Sendable (CaptureSnapshot) async -> Void
    private let inbox: VideoAnalysisInbox
    private let preparer: any CustomerVideoEvidencePreparing
    private let evidenceRoot: URL
    private let knowledgeBasePaths: [String]
    private let admit: Admit
    private var active = Set<String>()

    init(inbox: VideoAnalysisInbox, preparer: any CustomerVideoEvidencePreparing, evidenceRoot: URL,
         knowledgeBasePaths: [String], admit: @escaping Admit) {
        self.inbox = inbox; self.preparer = preparer; self.evidenceRoot = evidenceRoot
        self.knowledgeBasePaths = knowledgeBasePaths; self.admit = admit
    }

    func receive(_ receipt: DownloadedCustomerVideo) async {
        do {
            guard try await inbox.enqueue(receipt) else { return }
        } catch { return }
        await process(receipt)
    }

    func resumePending() async {
        guard let receipts = try? await inbox.pendingReceipts() else { return }
        for receipt in receipts { await process(receipt) }
    }

    private func process(_ receipt: DownloadedCustomerVideo) async {
        guard active.insert(receipt.messageHash).inserted else { return }
        defer { active.remove(receipt.messageHash) }
        do {
            var snapshot: CaptureSnapshot
            while true {
                let attempt = try await inbox.markPreparing(receipt.messageHash)
                do {
                    let evidencePreparer = preparer
                    let manifest = try await withOperationDeadline(
                        .seconds(90), stage: "customer-video-evidence"
                    ) {
                        try await evidencePreparer.prepare(receipt: receipt)
                    }
                    let directory = evidenceRoot.appendingPathComponent(receipt.messageHash, isDirectory: true)
                    snapshot = try VideoAnalysisSnapshotFactory.make(
                        receipt: receipt, manifest: manifest, evidenceRoot: directory,
                        knowledgeBasePaths: knowledgeBasePaths
                    )
                    try await inbox.markReady(receipt.messageHash)
                    break
                } catch {
                    if attempt < 2 {
                        try await inbox.markFailed(receipt.messageHash, reason: error.localizedDescription)
                        try? await Task.sleep(for: .seconds(1))
                        continue
                    }
                    snapshot = VideoAnalysisSnapshotFactory.fallback(
                        receipt: receipt, knowledgeBasePaths: knowledgeBasePaths
                    )
                    break
                }
            }
            await admit(snapshot)
            try await inbox.markAdmitted(receipt.messageHash)
        } catch {
            try? await inbox.markFailed(receipt.messageHash, reason: error.localizedDescription)
        }
    }
}
