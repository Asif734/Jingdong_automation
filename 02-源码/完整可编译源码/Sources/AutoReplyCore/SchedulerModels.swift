import Foundation
import CustomerReplyBatchAppSupport
import CustomerReplyBatchCore

@MainActor public protocol AutomationDriver: AnyObject {
    /// Synchronously removes authority from every in-flight native UI action.
    /// Implementations without native UI may keep the default no-op.
    func revokeUIOperations()
    func discover() async throws -> [String]
    func capture(uid: String, after cursor: CustomerCursor) async throws -> CaptureSnapshot
    func capture(uid: String, after cursor: CustomerCursor, includeImages: Bool) async throws -> CaptureSnapshot
    func captureBeforeDelivery(uid: String, after cursor: CustomerCursor) async throws -> CaptureSnapshot
    func send(uid: String, text: String) async throws -> DeliveryResult
    func recordTransferPlaceholder(uid: String, customerRevision: String, reply: ReplyEnvelope) async throws
    func reconcile(uid: String, replyText: String, after cursor: CustomerCursor) async throws -> DeliveryObservation
}

public extension AutomationDriver {
    func revokeUIOperations() {}
    func recordTransferPlaceholder(uid: String, customerRevision: String, reply: ReplyEnvelope) async throws {}
    func capture(uid: String, after cursor: CustomerCursor, includeImages: Bool) async throws -> CaptureSnapshot {
        try await capture(uid: uid, after: cursor)
    }
    func reconcile(uid: String, replyText: String, after cursor: CustomerCursor) async throws -> DeliveryObservation {
        .unavailable
    }
}

public enum AutomationDriverError: LocalizedError {
    case unsafeUI(String)
    /// The capture failed while opening/verifying the conversation, before
    /// OCR or any image/video interaction was allowed to begin.
    case captureFailedBeforeMedia(String)
    public var errorDescription: String? {
        switch self {
        case .unsafeUI(let reason), .captureFailedBeforeMedia(let reason): return reason
        }
    }
}

public struct CustomerCursor: Codable, Equatable, Hashable, Sendable {
    public let count: Int
    public let digest: String

    public static let empty = CustomerCursor(
        count: 0,
        digest: String(repeating: "0", count: 64)
    )

    public init(count: Int, digest: String) {
        self.count = count
        self.digest = digest
    }
}

public struct CaptureSnapshot: Codable, Equatable, Sendable {
    public let uid: String
    public let customerRevision: String
    public let historyJSONL: String
    public let imagePaths: [String]
    public let knowledgeBasePaths: [String]
    public let hasUnansweredCustomer: Bool
    public let shouldGenerate: Bool
    public let targetCustomerJSONL: String
    public let startCursor: CustomerCursor?
    public let endCursor: CustomerCursor?
    public let preservesHistoryCheckpoint: Bool

    public init(uid: String, customerRevision: String, historyJSONL: String,
                imagePaths: [String] = [], knowledgeBasePaths: [String] = [],
                hasUnansweredCustomer: Bool, shouldGenerate: Bool,
                targetCustomerJSONL: String = "", startCursor: CustomerCursor? = nil,
                endCursor: CustomerCursor? = nil,
                preservesHistoryCheckpoint: Bool = false) {
        self.uid = uid
        self.customerRevision = customerRevision
        self.historyJSONL = historyJSONL
        self.imagePaths = imagePaths
        self.knowledgeBasePaths = knowledgeBasePaths
        self.hasUnansweredCustomer = hasUnansweredCustomer
        self.shouldGenerate = shouldGenerate
        self.targetCustomerJSONL = targetCustomerJSONL
        self.startCursor = startCursor
        self.endCursor = endCursor
        self.preservesHistoryCheckpoint = preservesHistoryCheckpoint
    }

    private enum CodingKeys: String, CodingKey {
        case uid, customerRevision, historyJSONL, imagePaths, knowledgeBasePaths
        case hasUnansweredCustomer, shouldGenerate, targetCustomerJSONL
        case startCursor, endCursor
        case preservesHistoryCheckpoint
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        uid = try values.decode(String.self, forKey: .uid)
        customerRevision = try values.decode(String.self, forKey: .customerRevision)
        historyJSONL = try values.decode(String.self, forKey: .historyJSONL)
        imagePaths = try values.decodeIfPresent([String].self, forKey: .imagePaths) ?? []
        knowledgeBasePaths = try values.decodeIfPresent([String].self, forKey: .knowledgeBasePaths) ?? []
        hasUnansweredCustomer = try values.decode(Bool.self, forKey: .hasUnansweredCustomer)
        shouldGenerate = try values.decode(Bool.self, forKey: .shouldGenerate)
        targetCustomerJSONL = try values.decodeIfPresent(String.self, forKey: .targetCustomerJSONL) ?? ""
        startCursor = try values.decodeIfPresent(CustomerCursor.self, forKey: .startCursor)
        endCursor = try values.decodeIfPresent(CustomerCursor.self, forKey: .endCursor)
        preservesHistoryCheckpoint = try values.decodeIfPresent(Bool.self, forKey: .preservesHistoryCheckpoint) ?? false
    }

    public var promptInput: PromptInput {
        PromptInput(uid: uid, historyVersion: customerRevision, historyJSONL: historyJSONL,
                    historyText: "", imagePaths: imagePaths, knowledgeBasePaths: knowledgeBasePaths,
                    targetCustomerJSONL: targetCustomerJSONL,
                    preservesHistoryCheckpoint: preservesHistoryCheckpoint)
    }
}

public enum DeliveryResult: Equatable, Sendable {
    case sent
    case failedBeforeSend(String)
    case uncertain(String)
}

public struct StageAttempt: Codable, Equatable, Sendable {
    public var stage: String
    public var failures: Int
    public var operationID: UUID?
    public var startedAt: Date?
    public var deadlineAt: Date?

    public init(stage: String, failures: Int = 0, operationID: UUID? = nil,
                startedAt: Date? = nil, deadlineAt: Date? = nil) {
        self.stage = stage
        self.failures = failures
        self.operationID = operationID
        self.startedAt = startedAt
        self.deadlineAt = deadlineAt
    }
}

public enum SchedulerJobState: String, Codable, Sendable {
    case discovered, capturing, queued, generating, ready, sending
    case completed, superseded, failed, parked, uncertain
    public var isTerminal: Bool {
        [.completed, .superseded, .failed, .parked].contains(self)
    }
}

/// The delivery conclusion attached to archived generated text. It deliberately
/// distinguishes a verified send from a reply that was never sent or cannot be
/// safely treated as sent.
public enum SchedulerDeliveryOutcome: String, Codable, Equatable, Sendable {
    case sent
    case notSent
    case uncertain
}

public enum PreparedReplyAdmission: Equatable, Sendable {
    case inserted
    case alreadyPresent
    case rejected
}

public enum SchedulerTaskKind: String, Codable, Equatable, Sendable {
    case customerReply
    case transfer
}

public struct SchedulerRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let uid: String
    public var sequence: Int
    public var state: SchedulerJobState
    public var snapshot: CaptureSnapshot?
    public var pendingSupplement: CaptureSnapshot?
    /// `true` means discovery saw a newer unread message while generation was
    /// active, but its durable full-history capture has not completed yet.
    public var supplementCapturePending: Bool?
    /// `true` means the optional supplement probe exhausted its bounded retry
    /// for this frozen reply and discovery must not re-arm it.
    public var supplementCaptureAbandoned: Bool?
    public var attemptID: UUID?
    public var retries: Int
    public var reply: ReplyEnvelope?
    public var deliveryOutcome: SchedulerDeliveryOutcome?
    public var deliveryStableMisses: Int?
    public var deliveryResendIssued: Bool?
    /// Safe pre-send failures are allowed two bounded queue rounds. This count
    /// is separate from OCR/UI retries so an earlier capture failure cannot
    /// consume a send attempt.
    public var safeSendFailureCount: Int?
    /// A safely failed send yields to discovery and already-admitted captures
    /// before it receives its final retry.
    public var sendRetryDeferred: Bool?
    public var sendRetryNeedsDiscovery: Bool?
    /// Number of automatic cursor-tail captures chained without a fresh unread
    /// discovery. Optional keeps older on-disk scheduler state decodable.
    public var automaticFollowUpCount: Int?
    /// Persisted before an image-enabled OCR pass so retrying the same task
    /// cannot click/copy the same visible photo again.
    public var imageCaptureAttempted: Bool?
    public let createdAt: Date
    public var updatedAt: Date
    public var nextAttemptAt: Date
    public var lastError: String?
    public var sessionStage: String?
    public var archiveReference: SchedulerArchiveReference?
    public var archivedCustomerRevision: String?
    public var stageAttempt: StageAttempt?
    public var parkedReason: String?
    public var durableAttemptTextHash: String?
    public var durableAttemptOperationID: UUID?
    public var sendWasInvoked: Bool?
    /// Stable source identity for work injected without a visible unread scan.
    /// It prevents repeated recovery wakeups from creating duplicate UI jobs.
    public var sourceRevision: String?
    /// Nil is the legacy on-disk representation and means a normal customer reply.
    public var taskKind: SchedulerTaskKind?
    public var effectiveTaskKind: SchedulerTaskKind { taskKind ?? .customerReply }
    public var customerRevision: String? { snapshot?.customerRevision ?? archivedCustomerRevision }

    public init(id: UUID = UUID(), uid: String, sequence: Int, state: SchedulerJobState = .discovered,
                snapshot: CaptureSnapshot? = nil, pendingSupplement: CaptureSnapshot? = nil,
                supplementCapturePending: Bool? = nil, supplementCaptureAbandoned: Bool? = nil,
                attemptID: UUID? = nil, retries: Int = 0,
                reply: ReplyEnvelope? = nil, createdAt: Date = Date(), updatedAt: Date = Date(),
                nextAttemptAt: Date = .distantPast, lastError: String? = nil,
                deliveryOutcome: SchedulerDeliveryOutcome? = nil, sessionStage: String? = nil,
                deliveryStableMisses: Int? = nil, deliveryResendIssued: Bool? = nil,
                automaticFollowUpCount: Int? = nil, imageCaptureAttempted: Bool? = nil,
                safeSendFailureCount: Int? = nil, sendRetryDeferred: Bool? = nil,
                sendRetryNeedsDiscovery: Bool? = nil, stageAttempt: StageAttempt? = nil,
                parkedReason: String? = nil, durableAttemptTextHash: String? = nil,
                durableAttemptOperationID: UUID? = nil, sendWasInvoked: Bool? = nil,
                sourceRevision: String? = nil, taskKind: SchedulerTaskKind? = nil) {
        self.id = id; self.uid = uid; self.sequence = sequence; self.state = state
        self.snapshot = snapshot; self.pendingSupplement = pendingSupplement
        self.supplementCapturePending = supplementCapturePending
        self.supplementCaptureAbandoned = supplementCaptureAbandoned
        self.attemptID = attemptID; self.retries = retries
        self.reply = reply; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.nextAttemptAt = nextAttemptAt; self.lastError = lastError; self.deliveryOutcome = deliveryOutcome
        self.sessionStage = sessionStage
        self.deliveryStableMisses = deliveryStableMisses
        self.deliveryResendIssued = deliveryResendIssued
        self.automaticFollowUpCount = automaticFollowUpCount
        self.imageCaptureAttempted = imageCaptureAttempted
        self.safeSendFailureCount = safeSendFailureCount
        self.sendRetryDeferred = sendRetryDeferred
        self.sendRetryNeedsDiscovery = sendRetryNeedsDiscovery
        self.stageAttempt = stageAttempt
        self.parkedReason = parkedReason
        self.durableAttemptTextHash = durableAttemptTextHash
        self.durableAttemptOperationID = durableAttemptOperationID
        self.sendWasInvoked = sendWasInvoked
        self.sourceRevision = sourceRevision
        self.taskKind = taskKind
    }
}

public struct SchedulerArchiveReference: Codable, Equatable, Sendable {
    public let relativePath: String
    public let sha256: String
    public let byteCount: Int
}

public struct SchedulerEvent: Codable, Equatable, Sendable {
    public let date: Date
    public let uid: String?
    public let message: String
    public init(date: Date, uid: String?, message: String) {
        self.date = date; self.uid = uid; self.message = message
    }
}

public struct SchedulerPersistentState: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var nextEventSequence: Int = 0
    public var nextSequence: Int
    public var records: [SchedulerRecord]
    public var events: [SchedulerEvent]
    public var answeredCursors: [String: CustomerCursor]

    public init(schemaVersion: Int = 5, nextSequence: Int = 0,
                records: [SchedulerRecord] = [], events: [SchedulerEvent] = [],
                answeredCursors: [String: CustomerCursor] = [:]) {
        self.schemaVersion = schemaVersion
        self.nextSequence = nextSequence
        self.records = records
        self.events = events
        self.answeredCursors = answeredCursors
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, nextEventSequence, nextSequence, records, events, answeredCursors
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 2
        nextEventSequence = try values.decodeIfPresent(Int.self, forKey: .nextEventSequence) ?? 0
        nextSequence = try values.decodeIfPresent(Int.self, forKey: .nextSequence) ?? 0
        records = try values.decodeIfPresent([SchedulerRecord].self, forKey: .records) ?? []
        events = try values.decodeIfPresent([SchedulerEvent].self, forKey: .events) ?? []
        answeredCursors = try values.decodeIfPresent(
            [String: CustomerCursor].self,
            forKey: .answeredCursors
        ) ?? [:]
    }
}
