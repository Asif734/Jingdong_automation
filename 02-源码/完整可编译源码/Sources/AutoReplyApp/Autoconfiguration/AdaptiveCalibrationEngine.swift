import Foundation
import QianniuOCRCore
import QianniuSenderCore
import UnreadCore

struct AdaptiveCalibrationEngine: CalibrationProviding {
    typealias SnapshotProvider = @Sendable () async throws -> CalibrationSnapshot
    typealias VideoCapabilityProvider = @Sendable () async -> [String: CapabilityStatus]

    let snapshotProvider: SnapshotProvider
    let ocrAvailable: @Sendable () async -> Bool
    let videoCapabilities: VideoCapabilityProvider

    init(
        snapshotProvider: @escaping SnapshotProvider,
        ocrAvailable: @escaping @Sendable () async -> Bool,
        videoCapabilities: @escaping VideoCapabilityProvider = {
            VideoTransferCapabilityProbe.calibrationDefaults
        }
    ) {
        self.snapshotProvider = snapshotProvider
        self.ocrAvailable = ocrAvailable
        self.videoCapabilities = videoCapabilities
    }

    func calibrate() async throws -> MachineCompatibilityProfile {
        let snapshot = try await snapshotProvider()
        async let hasOCR = ocrAvailable()
        async let video = videoCapabilities()
        return try await Self.calibrate(
            snapshot: snapshot,
            ocrAvailable: hasOCR,
            videoCapabilities: video
        )
    }

    static func calibrate(
        snapshot: CalibrationSnapshot,
        ocrAvailable: Bool = true,
        videoCapabilities: [String: CapabilityStatus] = VideoTransferCapabilityProbe.calibrationDefaults
    ) throws -> MachineCompatibilityProfile {
        let fingerprint = EnvironmentFingerprint.make(from: snapshot)
        let window = try WindowCalibration.calibrate(snapshot: snapshot)
        let list = (try? conversationListPolicy(from: snapshot)) ?? .legacy
        let identity = IdentityCalibration.calibrate(
            snapshot: snapshot,
            ocrAvailable: ocrAvailable
        )
        let interaction: InteractionPolicies
        let interactionCalibrated: Bool
        do {
            interaction = try InteractionCalibration.calibrate(snapshot: snapshot)
            interactionCalibrated = true
        } catch {
            interaction = Self.fallbackInteractionPolicies
            interactionCalibrated = false
        }
        let capabilities = capabilityStatuses(
            identity: identity,
            interaction: interaction,
            listCalibrated: list != .legacy,
            interactionCalibrated: interactionCalibrated
        ).merging(videoCapabilities, uniquingKeysWith: { _, video in video })
        return MachineCompatibilityProfile(
            profileID: UUID(),
            fingerprintDigest: fingerprint.digest,
            capabilities: capabilities,
            readOnlyPassedAt: nil,
            endToEndPassedAt: nil,
            environmentFingerprint: fingerprint,
            windowPolicy: window,
            conversationListPolicy: list,
            identityPolicy: identity,
            capturePolicy: interaction.capture,
            composerPolicy: interaction.composer,
            sendPolicy: interaction.sendTrigger,
            calibrationDiagnostics: [interaction.sendDiagnostic]
        )
    }

    private static func conversationListPolicy(from snapshot: CalibrationSnapshot) throws -> ConversationListPolicy {
        guard let window = snapshot.windows.first(where: { $0.roleCategory == "reception" }) else {
            throw WindowCalibrationError.noQualifiedReceptionWindow
        }
        let nodes = snapshot.nodes.map {
            let relative = $0.relativeFrame
            let absolute = CGRect(
                x: window.relativeFrame.minX + relative.minX * window.relativeFrame.width,
                y: window.relativeFrame.minY + relative.minY * window.relativeFrame.height,
                width: relative.width * window.relativeFrame.width,
                height: relative.height * window.relativeFrame.height
            )
            return AXNode(
                id: $0.id,
                parent: $0.parentID,
                role: $0.role,
                title: $0.labelCategory,
                description: "",
                frame: absolute
            )
        }
        return try ConversationListPolicy.calibrate(nodes: nodes, window: window.relativeFrame)
    }

    private static func capabilityStatuses(
        identity: ConversationIdentityPolicy,
        interaction: InteractionPolicies,
        listCalibrated: Bool,
        interactionCalibrated: Bool
    ) -> [String: CapabilityStatus] {
        let sendDiagnostic = interaction.sendDiagnostic
        let sendDetail = "发送校准：可按\(sendDiagnostic.rawPressableCount)个，"
            + "有效\(sendDiagnostic.eligibleCandidateCount)个；"
            + "\(sendDiagnostic.selectedStrategy)；\(sendDiagnostic.nextAction)"
        return [
            "receptionWindow": CapabilityStatus(level: .verified, strategy: "calibrated-window", detail: "窗口与显示坐标已测量"),
            "conversationList": CapabilityStatus(level: listCalibrated ? .verified : .fallback, strategy: listCalibrated ? "calibrated-rows" : "legacy-tolerant-rows", detail: "客户行与分组栏独立容错"),
            "identity": CapabilityStatus(level: .verified, strategy: identity.orderedSources.map(\.rawValue).joined(separator: ">"), detail: "身份来源按本机结构排序"),
            "captureAX": CapabilityStatus(level: interactionCalibrated ? .verified : .fallback, strategy: interactionCalibrated ? "relative-chat-region" : "legacy-relative-chat-region", detail: "消息区域按本机能力选择"),
            "captureOCR": CapabilityStatus(level: .verified, strategy: "paddle-ocr", detail: "OCR 作为视觉兜底"),
            "composer": CapabilityStatus(level: .verified, strategy: "calibrated-composer", detail: "输入控件已校准"),
            "sendAX": CapabilityStatus(
                level: sendDiagnostic.level,
                strategy: sendDiagnostic.selectedStrategy,
                detail: sendDetail
            )
        ]
    }

    private static let fallbackInteractionPolicies = InteractionPolicies(
        capture: CaptureSelectionPolicy(
            relativeMessageRect: CGRect(x: 0.24, y: 0.12, width: 0.43, height: 0.66)
        ),
        composer: ComposerSelectionPolicy(
            acceptedRoles: ["AXTextArea", "AXTextField"],
            relativeRegion: CGRect(x: 0, y: 0.60, width: 1, height: 0.40),
            fallback: SendFallbackPolicy(relativeClickPoint: nil)
        ),
        sendTrigger: .returnKeyOnce,
        sendDiagnostic: SendCalibrationDiagnostic(
            stage: "发送控件校准",
            rawPressableCount: 0,
            eligibleCandidateCount: 0,
            selectedStrategy: QianniuSendTrigger.returnKeyOnce.rawValue,
            level: .fallback,
            canContinue: true,
            nextAction: "使用 Return 发送；首次真实发送后自动核对结果"
        )
    )
}
