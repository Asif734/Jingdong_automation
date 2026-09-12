import CryptoKit
import Foundation

public enum VideoTransferIdentity {
    public static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public static func key(customerUID: String, messageID: String) -> VideoTransferKey {
        VideoTransferKey(customerHash: hash(customerUID), messageHash: hash(messageID))
    }
}

public struct VideoTransferKey: Codable, Hashable, Sendable {
    public let customerHash: String
    public let messageHash: String

    public init(customerHash: String, messageHash: String) {
        self.customerHash = customerHash
        self.messageHash = messageHash
    }
}

public enum DurableVideoTransferPhase: String, Codable, Sendable {
    case discovered
    case opening
    case addressCaptured
    case downloading
    case validating
    case downloaded
    case preparingEvidence
    case readyForAI
    case admittedToAI
    case completed
    case waitingForRetry
    case terminalFailure
}

public enum VideoTransferFailureCategory: String, Codable, Sendable {
    case addressUnavailable
    case dnsResolution
    case connectTimeout
    case tlsFailure
    case offline
    case connectionReset
    case httpRejected
    case redirectRejected
    case responseTimeout
    case invalidContent
    case invalidVideo
    case localFile
    case retryBudgetExhausted
    case legacyUnknown
}

public enum VideoTransferDisposition: Equatable, Sendable {
    case needsOpen
    case inFlight
    case waitingUntil(Date)
    case terminal
}

public struct DurableVideoTransferRecord: Codable, Equatable, Sendable {
    public let key: VideoTransferKey
    public var customerUID: String?
    public var phase: DurableVideoTransferPhase
    public var attemptCount: Int
    public var scheduledRetryIndex: Int
    public var nextAttemptAt: Date?
    public var leaseUntil: Date?
    public var needsFreshAddress: Bool
    public var fallbackAdmitted: Bool
    public var fileName: String?
    public var failure: VideoTransferFailureCategory?
    public var updatedAt: Date

    public init(
        key: VideoTransferKey,
        customerUID: String?,
        phase: DurableVideoTransferPhase = .discovered,
        attemptCount: Int = 0,
        scheduledRetryIndex: Int = 0,
        nextAttemptAt: Date? = nil,
        leaseUntil: Date? = nil,
        needsFreshAddress: Bool = false,
        fallbackAdmitted: Bool = false,
        fileName: String? = nil,
        failure: VideoTransferFailureCategory? = nil,
        updatedAt: Date = Date()
    ) {
        self.key = key
        self.customerUID = customerUID
        self.phase = phase
        self.attemptCount = attemptCount
        self.scheduledRetryIndex = scheduledRetryIndex
        self.nextAttemptAt = nextAttemptAt
        self.leaseUntil = leaseUntil
        self.needsFreshAddress = needsFreshAddress
        self.fallbackAdmitted = fallbackAdmitted
        self.fileName = fileName
        self.failure = failure
        self.updatedAt = updatedAt
    }
}

public enum VideoTransferStateError: LocalizedError, Equatable {
    case missingRecord
    case invalidCustomerUID
    case customerIdentityMismatch
    case unsupportedSchema(Int)

    public var errorDescription: String? {
        switch self {
        case .missingRecord: return "视频传输记录不存在"
        case .invalidCustomerUID: return "客户 UID 不完整或不安全"
        case .customerIdentityMismatch: return "客户 UID 与已保存身份不匹配"
        case .unsupportedSchema(let version): return "不支持的视频传输状态版本：\(version)"
        }
    }
}

public actor DurableVideoTransferStore {
    private struct Payload: Codable {
        var schemaVersion = 2
        var records: [DurableVideoTransferRecord]
    }

    private struct LegacyDownloadPayload: Decodable {
        let records: [LegacyDownloadRecord]
    }

    private struct LegacyDownloadRecord: Decodable {
        let messageHash: String
        let phase: String
        let fileName: String?
    }

    private struct LegacyProcessedPayload: Decodable {
        let entries: [LegacyProcessedEntry]
    }

    private struct LegacyProcessedEntry: Decodable {
        let messageHash: String
        let customerHash: String
        let type: String
    }

    private let url: URL
    private let maximumRecords: Int
    private let now: @Sendable () -> Date
    private var cached: Payload?

    public init(
        url: URL,
        maximumRecords: Int = 10_000,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.url = url
        self.maximumRecords = max(1, maximumRecords)
        self.now = now
    }

    @discardableResult
    public func beginOrRead(
        key: VideoTransferKey,
        customerUID: String
    ) throws -> DurableVideoTransferRecord {
        try validate(customerUID, for: key)
        var payload = try load()
        if let index = payload.records.firstIndex(where: { $0.key == key }) {
            if let existing = payload.records[index].customerUID,
               existing != customerUID {
                throw VideoTransferStateError.customerIdentityMismatch
            }
            if payload.records[index].customerUID == nil {
                payload.records[index].customerUID = customerUID
                payload.records[index].updatedAt = now()
                try save(payload)
            }
            return payload.records[index]
        }
        let record = DurableVideoTransferRecord(
            key: key,
            customerUID: customerUID,
            updatedAt: now()
        )
        payload.records.append(record)
        trim(&payload)
        try save(payload)
        return record
    }

    public func bindCustomerUID(_ customerUID: String, to key: VideoTransferKey) throws {
        try validate(customerUID, for: key)
        var payload = try load()
        guard let index = payload.records.firstIndex(where: { $0.key == key }) else {
            throw VideoTransferStateError.missingRecord
        }
        if let existing = payload.records[index].customerUID,
           existing != customerUID {
            throw VideoTransferStateError.customerIdentityMismatch
        }
        payload.records[index].customerUID = customerUID
        payload.records[index].updatedAt = now()
        try save(payload)
    }

    public func record(_ key: VideoTransferKey) throws -> DurableVideoTransferRecord? {
        try load().records.first { $0.key == key }
    }

    public func recordsByMessageHash() throws -> [String: DurableVideoTransferRecord] {
        Dictionary(try load().records.map { ($0.key.messageHash, $0) }, uniquingKeysWith: { old, new in
            old.updatedAt >= new.updatedAt ? old : new
        })
    }

    public func allRecords() throws -> [DurableVideoTransferRecord] {
        try load().records
    }

    public func disposition(for key: VideoTransferKey) throws -> VideoTransferDisposition {
        guard let record = try record(key) else { return .needsOpen }
        switch record.phase {
        case .discovered: return .needsOpen
        case .waitingForRetry:
            if let next = record.nextAttemptAt, next > now() { return .waitingUntil(next) }
            return .needsOpen
        case .completed, .terminalFailure: return .terminal
        default: return .inFlight
        }
    }

    public func transition(
        _ key: VideoTransferKey,
        to phase: DurableVideoTransferPhase,
        failure: VideoTransferFailureCategory? = nil,
        nextAttemptAt: Date? = nil
    ) throws {
        var payload = try load()
        guard let index = payload.records.firstIndex(where: { $0.key == key }) else {
            throw VideoTransferStateError.missingRecord
        }
        payload.records[index].phase = phase
        payload.records[index].failure = failure
        payload.records[index].nextAttemptAt = nextAttemptAt
        switch phase {
        case .discovered, .downloaded, .completed, .waitingForRetry, .terminalFailure:
            payload.records[index].leaseUntil = nil
        case .opening, .addressCaptured, .downloading, .validating,
             .preparingEvidence, .readyForAI, .admittedToAI:
            break
        }
        payload.records[index].updatedAt = now()
        try save(payload)
    }

    public func recordAttempt(_ key: VideoTransferKey) throws {
        var payload = try load()
        guard let index = payload.records.firstIndex(where: { $0.key == key }) else {
            throw VideoTransferStateError.missingRecord
        }
        payload.records[index].attemptCount += 1
        payload.records[index].updatedAt = now()
        try save(payload)
    }

    public func scheduleRetry(
        _ key: VideoTransferKey,
        failure: VideoTransferFailureCategory,
        nextAttemptAt: Date,
        needsFreshAddress: Bool
    ) throws {
        var payload = try load()
        guard let index = payload.records.firstIndex(where: { $0.key == key }) else {
            throw VideoTransferStateError.missingRecord
        }
        payload.records[index].phase = .waitingForRetry
        payload.records[index].failure = failure
        payload.records[index].nextAttemptAt = nextAttemptAt
        payload.records[index].scheduledRetryIndex += 1
        payload.records[index].needsFreshAddress = needsFreshAddress
        payload.records[index].leaseUntil = nil
        payload.records[index].updatedAt = now()
        try save(payload)
    }

    public func markDownloaded(_ key: VideoTransferKey, fileName: String) throws {
        var payload = try load()
        guard let index = payload.records.firstIndex(where: { $0.key == key }) else {
            throw VideoTransferStateError.missingRecord
        }
        payload.records[index].phase = .downloaded
        payload.records[index].failure = nil
        payload.records[index].nextAttemptAt = nil
        payload.records[index].needsFreshAddress = false
        payload.records[index].leaseUntil = nil
        payload.records[index].fileName = fileName
        payload.records[index].updatedAt = now()
        try save(payload)
    }

    public func claimLease(
        _ key: VideoTransferKey,
        duration: TimeInterval = 60
    ) throws -> Bool {
        var payload = try load()
        guard let index = payload.records.firstIndex(where: { $0.key == key }) else {
            throw VideoTransferStateError.missingRecord
        }
        let current = now()
        if let lease = payload.records[index].leaseUntil, lease > current { return false }
        payload.records[index].leaseUntil = current.addingTimeInterval(max(0, duration))
        payload.records[index].updatedAt = current
        try save(payload)
        return true
    }

    public func releaseLease(_ key: VideoTransferKey) throws {
        var payload = try load()
        guard let index = payload.records.firstIndex(where: { $0.key == key }) else {
            throw VideoTransferStateError.missingRecord
        }
        payload.records[index].leaseUntil = nil
        payload.records[index].updatedAt = now()
        try save(payload)
    }

    public func dueRecords() throws -> [DurableVideoTransferRecord] {
        let current = now()
        return try load().records
            .filter { record in
                guard record.phase == .waitingForRetry else { return false }
                guard record.nextAttemptAt.map({ $0 <= current }) ?? true else { return false }
                return record.leaseUntil.map({ $0 <= current }) ?? true
            }
            .sorted { lhs, rhs in
                let left = lhs.nextAttemptAt ?? .distantPast
                let right = rhs.nextAttemptAt ?? .distantPast
                if left == right { return lhs.updatedAt < rhs.updatedAt }
                return left < right
            }
    }

    public func markFallbackAdmitted(_ key: VideoTransferKey) throws {
        var payload = try load()
        guard let index = payload.records.firstIndex(where: { $0.key == key }) else {
            throw VideoTransferStateError.missingRecord
        }
        payload.records[index].fallbackAdmitted = true
        payload.records[index].updatedAt = now()
        try save(payload)
    }

    public func markAnalysisCompleted(messageHash: String) throws {
        var payload = try load()
        var changed = false
        for index in payload.records.indices where payload.records[index].key.messageHash == messageHash {
            payload.records[index].phase = .completed
            payload.records[index].leaseUntil = nil
            payload.records[index].nextAttemptAt = nil
            payload.records[index].failure = nil
            payload.records[index].updatedAt = now()
            changed = true
        }
        if changed { try save(payload) }
    }

    public func migrateLegacyJournals(downloadURL: URL, processedURL: URL) throws {
        guard FileManager.default.fileExists(atPath: downloadURL.path),
              FileManager.default.fileExists(atPath: processedURL.path) else { return }
        let downloads = try JSONDecoder().decode(
            LegacyDownloadPayload.self,
            from: Data(contentsOf: downloadURL)
        )
        let processed = try JSONDecoder().decode(
            LegacyProcessedPayload.self,
            from: Data(contentsOf: processedURL)
        )
        let customerHashes = Dictionary(
            processed.entries.filter { $0.type == "video" }.map { ($0.messageHash, $0.customerHash) },
            uniquingKeysWith: { first, _ in first }
        )
        var payload = try load()
        let existing = Set(payload.records.map(\.key))
        for legacy in downloads.records {
            guard let customerHash = customerHashes[legacy.messageHash] else { continue }
            let key = VideoTransferKey(customerHash: customerHash, messageHash: legacy.messageHash)
            guard !existing.contains(key), !payload.records.contains(where: { $0.key == key }) else { continue }
            let downloaded = legacy.phase == "downloaded" && legacy.fileName != nil
            payload.records.append(DurableVideoTransferRecord(
                key: key,
                customerUID: nil,
                phase: downloaded ? .downloaded : .waitingForRetry,
                nextAttemptAt: downloaded ? nil : now(),
                needsFreshAddress: !downloaded,
                fileName: legacy.fileName,
                failure: downloaded ? nil : .legacyUnknown,
                updatedAt: now()
            ))
        }
        trim(&payload)
        try save(payload)
    }

    private func validate(_ customerUID: String, for key: VideoTransferKey) throws {
        guard Self.validCustomerUID(customerUID) else {
            throw VideoTransferStateError.invalidCustomerUID
        }
        guard VideoTransferIdentity.hash(customerUID) == key.customerHash else {
            throw VideoTransferStateError.customerIdentityMismatch
        }
    }

    private func load() throws -> Payload {
        if let cached { return cached }
        let value: Payload
        if FileManager.default.fileExists(atPath: url.path) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            value = try decoder.decode(Payload.self, from: Data(contentsOf: url))
            guard value.schemaVersion <= 2 else {
                throw VideoTransferStateError.unsupportedSchema(value.schemaVersion)
            }
        } else {
            value = Payload(records: [])
        }
        cached = value
        return value
    }

    private func save(_ payload: Payload) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(payload).write(to: url, options: .atomic)
        cached = payload
    }

    private func trim(_ payload: inout Payload) {
        guard payload.records.count > maximumRecords else { return }
        payload.records.sort { $0.updatedAt < $1.updatedAt }
        payload.records.removeFirst(payload.records.count - maximumRecords)
    }

    private static func validCustomerUID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 256
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value != "." && value != ".."
            && !value.contains("/") && !value.contains("\\")
            && !value.contains("...") && !value.contains("…")
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

}
