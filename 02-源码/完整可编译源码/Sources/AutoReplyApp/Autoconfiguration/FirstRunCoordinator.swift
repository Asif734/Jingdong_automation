import Combine
import Foundation

struct PermissionState: Equatable, Sendable {
    let accessibility: Bool
    let screenCapture: Bool
}

protocol FirstRunChecking: Sendable {
    func permissionState() async -> PermissionState
    func qianniuReceptionReady() async -> Bool
    func codexLoggedIn() async -> Bool
}

protocol CalibrationProviding: Sendable {
    func calibrate() async throws -> MachineCompatibilityProfile
}

protocol ReadinessPrewarming: Sendable {
    func prepare() async throws -> [String: CapabilityStatus]
}

@MainActor
final class FirstRunCoordinator: ObservableObject {
    @Published private(set) var phase: ReadinessPhase = .installed
    @Published private(set) var blockingReason: String?
    @Published private(set) var capabilities: [String: CapabilityStatus] = [:]
    @Published private(set) var shouldAutoStart = false
    @Published private(set) var profile: MachineCompatibilityProfile?

    private let checks: any FirstRunChecking
    private let calibration: any CalibrationProviding
    private let prewarmer: any ReadinessPrewarming
    private let onProfileReady: @MainActor @Sendable (MachineCompatibilityProfile) -> Void
    private var continuationTask: Task<Void, Never>?

    init(
        checks: any FirstRunChecking,
        calibration: any CalibrationProviding,
        prewarmer: any ReadinessPrewarming,
        onProfileReady: @escaping @MainActor @Sendable (MachineCompatibilityProfile) -> Void = { _ in }
    ) {
        self.checks = checks
        self.calibration = calibration
        self.prewarmer = prewarmer
        self.onProfileReady = onProfileReady
    }

    deinit {
        continuationTask?.cancel()
    }

    func advance(operatorConfig: OperatorConfig) async {
        shouldAutoStart = false
        blockingReason = nil

        let permissions = await checks.permissionState()
        guard permissions.accessibility else {
            wait(at: .permissionsPending, reason: "请开启辅助功能")
            return
        }
        guard permissions.screenCapture else {
            wait(at: .permissionsPending, reason: "请开启屏幕录制")
            return
        }

        guard await checks.qianniuReceptionReady() else {
            wait(at: .qianniuPending, reason: "请登录千牛并打开接待中心")
            return
        }

        let aliases = operatorConfig.serviceAliases
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !aliases.isEmpty else {
            wait(at: .operatorPending, reason: "请填写客服名称")
            return
        }

        guard await checks.codexLoggedIn() else {
            wait(at: .codexPending, reason: "请登录 Codex")
            return
        }

        do {
            phase = .probing
            phase = .calibrating
            let calibratedProfile = try await calibration.calibrate()

            phase = .prewarming
            let prewarmedCapabilities = try await prewarmer.prepare()
            let mergedCapabilities = calibratedProfile.capabilities.merging(
                prewarmedCapabilities,
                uniquingKeysWith: { _, prewarmed in prewarmed }
            )
            let readyProfile = MachineCompatibilityProfile(
                schemaVersion: calibratedProfile.schemaVersion,
                profileID: calibratedProfile.profileID,
                fingerprintDigest: calibratedProfile.fingerprintDigest,
                capabilities: mergedCapabilities,
                readOnlyPassedAt: Date(),
                endToEndPassedAt: calibratedProfile.endToEndPassedAt,
                environmentFingerprint: calibratedProfile.environmentFingerprint,
                windowPolicy: calibratedProfile.windowPolicy,
                conversationListPolicy: calibratedProfile.conversationListPolicy,
                identityPolicy: calibratedProfile.identityPolicy,
                capturePolicy: calibratedProfile.capturePolicy,
                composerPolicy: calibratedProfile.composerPolicy,
                sendPolicy: calibratedProfile.sendPolicy,
                calibrationDiagnostics: calibratedProfile.calibrationDiagnostics
            )

            capabilities = mergedCapabilities
            profile = readyProfile
            onProfileReady(readyProfile)
            blockingReason = nil
            phase = .readOnlyReady
            shouldAutoStart = operatorConfig.autoStartWhenReady
        } catch {
            wait(at: .degraded, reason: error.localizedDescription)
        }
    }

    func beginAutomaticContinuation(
        operatorConfig: @escaping @MainActor @Sendable () -> OperatorConfig
    ) {
        continuationTask?.cancel()
        continuationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.advance(operatorConfig: operatorConfig())
                if self.phase == .readOnlyReady || self.phase == .running {
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stopAutomaticContinuation() {
        continuationTask?.cancel()
        continuationTask = nil
    }

    func markRunning() {
        phase = .running
        blockingReason = nil
        shouldAutoStart = false
    }

    func readinessStateExport() -> ReadinessStateExport {
        ReadinessStateExport(
            phase: phase,
            ocrPrepared: capabilities["ocr"]?.level != .unavailable && capabilities["ocr"] != nil,
            v2Prepared: capabilities["v2"]?.level != .unavailable && capabilities["v2"] != nil,
            profileCreated: profile != nil,
            endToEndVerified: profile?.endToEndPassedAt != nil
        )
    }

    private func wait(at phase: ReadinessPhase, reason: String) {
        self.phase = phase
        blockingReason = reason
        shouldAutoStart = false
    }
}
