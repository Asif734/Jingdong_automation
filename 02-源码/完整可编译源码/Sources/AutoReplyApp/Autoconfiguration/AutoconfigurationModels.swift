import CoreGraphics
import Foundation
import QianniuOCRCore
import QianniuSenderCore
import UnreadCore

enum ReadinessPhase: String, Codable, CaseIterable, Sendable {
    case installed
    case permissionsPending
    case qianniuPending
    case operatorPending
    case codexPending
    case probing
    case calibrating
    case prewarming
    case readOnlyReady
    case running
    case degraded
    case waitingExternalState
    case recalibrating
}

enum CapabilityLevel: String, Codable, Sendable {
    case verified
    case fallback
    case unavailable
}

struct CapabilityStatus: Codable, Equatable, Sendable {
    let level: CapabilityLevel
    let strategy: String
    let detail: String
}

struct SendCalibrationDiagnostic: Codable, Equatable, Sendable {
    let stage: String
    let rawPressableCount: Int
    let eligibleCandidateCount: Int
    let selectedStrategy: String
    let level: CapabilityLevel
    let canContinue: Bool
    let nextAction: String
}

struct SendCalibrationDecision: Equatable, Sendable {
    let trigger: QianniuSendTrigger
    let fallbackPoint: CGPoint?
    let diagnostic: SendCalibrationDiagnostic
}

struct ReadinessStateExport: Codable, Equatable, Sendable {
    let phase: ReadinessPhase
    let ocrPrepared: Bool
    let v2Prepared: Bool
    let profileCreated: Bool
    let endToEndVerified: Bool
}

struct InstallationState: Codable, Equatable, Sendable {
    let installedAppPath: String
    let appVersion: String
    let resourceManifestSHA256: String
}

struct OperatorConfig: Codable, Equatable, Sendable {
    let serviceAliases: [String]
    let autoStartWhenReady: Bool
}

struct MachineCompatibilityProfile: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let profileID: UUID
    let fingerprintDigest: String
    let capabilities: [String: CapabilityStatus]
    let readOnlyPassedAt: Date?
    let endToEndPassedAt: Date?
    let environmentFingerprint: EnvironmentFingerprint?
    let windowPolicy: WindowSelectionPolicy?
    let conversationListPolicy: ConversationListPolicy?
    let identityPolicy: ConversationIdentityPolicy?
    let capturePolicy: CaptureSelectionPolicy?
    let composerPolicy: ComposerSelectionPolicy?
    let sendPolicy: QianniuSendTrigger?
    let calibrationDiagnostics: [SendCalibrationDiagnostic]?

    init(
        schemaVersion: Int = 4,
        profileID: UUID,
        fingerprintDigest: String,
        capabilities: [String: CapabilityStatus],
        readOnlyPassedAt: Date?,
        endToEndPassedAt: Date?,
        environmentFingerprint: EnvironmentFingerprint? = nil,
        windowPolicy: WindowSelectionPolicy? = nil,
        conversationListPolicy: ConversationListPolicy? = nil,
        identityPolicy: ConversationIdentityPolicy? = nil,
        capturePolicy: CaptureSelectionPolicy? = nil,
        composerPolicy: ComposerSelectionPolicy? = nil,
        sendPolicy: QianniuSendTrigger? = nil,
        calibrationDiagnostics: [SendCalibrationDiagnostic]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.profileID = profileID
        self.fingerprintDigest = fingerprintDigest
        self.capabilities = capabilities
        self.readOnlyPassedAt = readOnlyPassedAt
        self.endToEndPassedAt = endToEndPassedAt
        self.environmentFingerprint = environmentFingerprint
        self.windowPolicy = windowPolicy
        self.conversationListPolicy = conversationListPolicy
        self.identityPolicy = identityPolicy
        self.capturePolicy = capturePolicy
        self.composerPolicy = composerPolicy
        self.sendPolicy = sendPolicy
        self.calibrationDiagnostics = calibrationDiagnostics
    }

    var requiresFullAdaptiveCalibration: Bool {
        schemaVersion < 4
            || windowPolicy == nil
            || conversationListPolicy == nil
            || identityPolicy == nil
            || capturePolicy == nil
            || composerPolicy == nil
            || sendPolicy == nil
            || environmentFingerprint == nil
    }

    var systemVideoDownloadAvailable: Bool {
        capabilities["videoDownloadSystem"]?.level != .unavailable
    }

    var alternateVideoRouteAvailable: Bool {
        capabilities["videoDownloadAlternate"]?.level != .unavailable
    }

    var videoTransferMode: String {
        if systemVideoDownloadAvailable && alternateVideoRouteAvailable { return "system+alternate" }
        if systemVideoDownloadAvailable { return "system" }
        return "unavailable"
    }

    static var empty: MachineCompatibilityProfile {
        MachineCompatibilityProfile(
            schemaVersion: 4,
            profileID: UUID(),
            fingerprintDigest: "",
            capabilities: [:],
            readOnlyPassedAt: nil,
            endToEndPassedAt: nil
        )
    }
}
