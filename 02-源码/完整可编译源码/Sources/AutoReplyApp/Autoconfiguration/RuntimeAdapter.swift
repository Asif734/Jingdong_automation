import Foundation
import QianniuOCRCore
import QianniuSenderCore
import UnreadCore

enum RuntimeCaptureStrategy: String, Codable, Equatable, Sendable {
    case accessibility
    case ocr
}

struct CalibratedReceptionWindow: Equatable, Sendable {
    let policy: WindowSelectionPolicy?
    let strategy: String
}

@MainActor
protocol RuntimeAdapting: AnyObject {
    func receptionWindow() async throws -> CalibratedReceptionWindow
    func discoverCustomers() async throws -> [ConversationCandidate]
    func resolveIdentity(for candidate: ConversationCandidate) async throws -> String?
    func captureStrategy() async throws -> RuntimeCaptureStrategy
    func composerStrategy() async throws -> ComposerSelectionPolicy
    func sendStrategy() async throws -> QianniuSendTrigger
}

@MainActor
final class AdaptiveRuntimeAdapter: RuntimeAdapting {
    typealias CandidateProvider = @MainActor @Sendable () async throws -> [ConversationCandidate]

    private(set) var profile: MachineCompatibilityProfile
    private let candidateProvider: CandidateProvider

    init(
        profile: MachineCompatibilityProfile,
        candidateProvider: @escaping CandidateProvider = { [] }
    ) {
        self.profile = profile
        self.candidateProvider = candidateProvider
    }

    var windowPolicy: WindowSelectionPolicy? { profile.windowPolicy }
    var conversationListPolicy: ConversationListPolicy { profile.conversationListPolicy ?? .legacy }
    var identityPolicy: ConversationIdentityPolicy { profile.identityPolicy ?? .default }
    var capturePolicy: CaptureSelectionPolicy? { profile.capturePolicy }
    var composerPolicy: ComposerSelectionPolicy? { profile.composerPolicy }
    var sendPolicy: QianniuSendTrigger? { profile.sendPolicy }

    func update(profile: MachineCompatibilityProfile) {
        self.profile = profile
    }

    func receptionWindow() async throws -> CalibratedReceptionWindow {
        CalibratedReceptionWindow(
            policy: profile.windowPolicy,
            strategy: profile.windowPolicy == nil ? "legacy-window-selection" : "calibrated-window-selection"
        )
    }

    func discoverCustomers() async throws -> [ConversationCandidate] {
        // A malformed or unresolved row is evidence for recalibration, not a
        // reason to discard the other customer rows returned by the same scan.
        try await candidateProvider()
    }

    func resolveIdentity(for candidate: ConversationCandidate) async throws -> String? {
        candidate.identity.resolved
    }

    func captureStrategy() async throws -> RuntimeCaptureStrategy {
        let ax = profile.capabilities["captureAX"]?.level
        let ocr = profile.capabilities["captureOCR"]?.level
        if ax == .verified, profile.capturePolicy != nil { return .accessibility }
        if ocr == .verified || ocr == .fallback { return .ocr }
        if profile.capturePolicy != nil { return .accessibility }
        return .ocr
    }

    func composerStrategy() async throws -> ComposerSelectionPolicy {
        if let policy = profile.composerPolicy { return policy }
        return ComposerSelectionPolicy(
            acceptedRoles: ["AXTextArea", "AXTextField"],
            relativeRegion: .zero,
            fallback: SendFallbackPolicy(relativeClickPoint: nil)
        )
    }

    func sendStrategy() async throws -> QianniuSendTrigger {
        if let policy = profile.sendPolicy { return policy }
        if profile.capabilities["sendAX"]?.level == .verified { return .accessibilityPress }
        return .returnKeyOnce
    }
}

#if DEBUG
extension AdaptiveRuntimeAdapter {
    static func fixture(
        captureAX: CapabilityLevel = .verified,
        captureOCR: CapabilityLevel = .verified,
        sendAX: CapabilityLevel = .verified,
        candidates: [ConversationCandidate] = []
    ) -> AdaptiveRuntimeAdapter {
        let status: (CapabilityLevel, String) -> CapabilityStatus = { level, strategy in
            CapabilityStatus(level: level, strategy: strategy, detail: "fixture")
        }
        let profile = MachineCompatibilityProfile(
            profileID: UUID(),
            fingerprintDigest: "fixture",
            capabilities: [
                "captureAX": status(captureAX, "ax"),
                "captureOCR": status(captureOCR, "ocr"),
                "sendAX": status(sendAX, "ax")
            ],
            readOnlyPassedAt: nil,
            endToEndPassedAt: nil,
            capturePolicy: CaptureSelectionPolicy(relativeMessageRect: .zero),
            sendPolicy: sendAX == .verified ? .accessibilityPress : .returnKeyOnce
        )
        return AdaptiveRuntimeAdapter(profile: profile, candidateProvider: { candidates })
    }
}
#endif
