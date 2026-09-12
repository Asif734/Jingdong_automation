import Foundation

enum ProfileValidationDecision: Equatable, Sendable {
    case reuseCurrent
    case recalibrate(capabilities: Set<String>)
    case fullCalibration
}

actor ProfileLifecycle {
    typealias Calibrator = @Sendable () async throws -> MachineCompatibilityProfile
    typealias CandidateValidation = @Sendable (MachineCompatibilityProfile) throws -> Bool

    private let store: AtomicJSONStore<MachineCompatibilityProfile>
    private let calibrateProfile: Calibrator
    private let candidateValidation: CandidateValidation
    private var failureCounts: [String: Int] = [:]
    private(set) var currentProfile: MachineCompatibilityProfile

    init(
        store: AtomicJSONStore<MachineCompatibilityProfile>,
        current: MachineCompatibilityProfile,
        candidateValidation: @escaping CandidateValidation = { !$0.requiresFullAdaptiveCalibration },
        calibrate: @escaping Calibrator
    ) {
        self.store = store
        currentProfile = current
        self.candidateValidation = candidateValidation
        calibrateProfile = calibrate
    }

    func validateQuickly(snapshot: CalibrationSnapshot) throws -> ProfileValidationDecision {
        guard currentProfile.schemaVersion >= 2,
              let existing = currentProfile.environmentFingerprint else {
            return .fullCalibration
        }
        let observed = EnvironmentFingerprint.make(from: snapshot)
        guard existing.macOSBuild == observed.macOSBuild,
              existing.architecture == observed.architecture,
              existing.qianniuVersion == observed.qianniuVersion,
              existing.qianniuBuild == observed.qianniuBuild,
              existing.qianniuRuntimeArchitecture == observed.qianniuRuntimeArchitecture,
              existing.semanticStructureDigest == observed.semanticStructureDigest else {
            return .fullCalibration
        }
        if existing.digest == observed.digest { return .reuseCurrent }
        return .recalibrate(capabilities: ["coordinateMapping"])
    }

    func recordFailure(capability: String) -> ProfileValidationDecision {
        let count = (failureCounts[capability] ?? 0) + 1
        failureCounts[capability] = count
        guard count >= 2 else { return .reuseCurrent }
        failureCounts[capability] = 0
        return .recalibrate(capabilities: [capability])
    }

    func recordEndToEndDelivery(at date: Date = Date()) throws {
        let updated = replacing(currentProfile, endToEndPassedAt: date)
        try store.saveCandidate(updated, validate: candidateValidation)
        currentProfile = updated
    }

    func adopt(_ profile: MachineCompatibilityProfile) {
        currentProfile = profile
    }

    func recalibrate(_ capabilities: Set<String>) async throws {
        let calibrated = try await calibrateProfile()
        let candidate = merge(current: currentProfile, calibrated: calibrated, capabilities: capabilities)
        try store.saveCandidate(candidate, validate: candidateValidation)
        currentProfile = candidate
        for capability in capabilities { failureCounts[capability] = 0 }
    }

    func profileForStartup(snapshot: CalibrationSnapshot) async throws -> MachineCompatibilityProfile {
        switch try validateQuickly(snapshot: snapshot) {
        case .reuseCurrent:
            return currentProfile
        case .recalibrate(let capabilities):
            try await recalibrate(capabilities)
            return currentProfile
        case .fullCalibration:
            try await recalibrate(["all"])
            return currentProfile
        }
    }

    private func merge(
        current: MachineCompatibilityProfile,
        calibrated: MachineCompatibilityProfile,
        capabilities: Set<String>
    ) -> MachineCompatibilityProfile {
        let full = capabilities.isEmpty || capabilities.contains("all")
        let replaceWindow = full || capabilities.contains("coordinateMapping") || capabilities.contains("window")
        let replaceList = full || capabilities.contains("conversationList")
        let replaceIdentity = full || capabilities.contains("identity")
        let replaceCapture = full || capabilities.contains("capture") || capabilities.contains("captureAX")
        let replaceComposer = full || capabilities.contains("composer")
        let replaceSend = full || capabilities.contains("send") || capabilities.contains("sendAX")
        let keys = capabilities.reduce(into: current.capabilities) { result, key in
            if let status = calibrated.capabilities[key] { result[key] = status }
        }
        return MachineCompatibilityProfile(
            profileID: current.profileID,
            fingerprintDigest: calibrated.fingerprintDigest,
            capabilities: full ? calibrated.capabilities : keys,
            readOnlyPassedAt: calibrated.readOnlyPassedAt ?? current.readOnlyPassedAt,
            endToEndPassedAt: current.endToEndPassedAt,
            environmentFingerprint: calibrated.environmentFingerprint,
            windowPolicy: replaceWindow ? calibrated.windowPolicy : current.windowPolicy,
            conversationListPolicy: replaceList ? calibrated.conversationListPolicy : current.conversationListPolicy,
            identityPolicy: replaceIdentity ? calibrated.identityPolicy : current.identityPolicy,
            capturePolicy: replaceCapture ? calibrated.capturePolicy : current.capturePolicy,
            composerPolicy: replaceComposer ? calibrated.composerPolicy : current.composerPolicy,
            sendPolicy: replaceSend ? calibrated.sendPolicy : current.sendPolicy
        )
    }

    private func replacing(
        _ profile: MachineCompatibilityProfile,
        endToEndPassedAt: Date
    ) -> MachineCompatibilityProfile {
        MachineCompatibilityProfile(
            schemaVersion: profile.schemaVersion,
            profileID: profile.profileID,
            fingerprintDigest: profile.fingerprintDigest,
            capabilities: profile.capabilities,
            readOnlyPassedAt: profile.readOnlyPassedAt,
            endToEndPassedAt: endToEndPassedAt,
            environmentFingerprint: profile.environmentFingerprint,
            windowPolicy: profile.windowPolicy,
            conversationListPolicy: profile.conversationListPolicy,
            identityPolicy: profile.identityPolicy,
            capturePolicy: profile.capturePolicy,
            composerPolicy: profile.composerPolicy,
            sendPolicy: profile.sendPolicy
        )
    }
}

struct LifecycleCalibrationProvider: CalibrationProviding {
    let snapshotProvider: @Sendable () async throws -> CalibrationSnapshot
    let lifecycle: ProfileLifecycle

    func calibrate() async throws -> MachineCompatibilityProfile {
        let snapshot = try await snapshotProvider()
        return try await lifecycle.profileForStartup(snapshot: snapshot)
    }
}
