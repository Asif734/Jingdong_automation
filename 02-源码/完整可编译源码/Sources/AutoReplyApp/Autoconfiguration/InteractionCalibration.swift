import CoreGraphics
import Foundation
import QianniuOCRCore
import QianniuSenderCore

struct InteractionPolicies: Equatable, Sendable {
    let capture: CaptureSelectionPolicy
    let composer: ComposerSelectionPolicy
    let sendTrigger: QianniuSendTrigger?
    let sendDiagnostic: SendCalibrationDiagnostic
}

enum InteractionCalibrationError: Error, Equatable {
    case missingUniqueChatRegion
    case missingUniqueComposer
}

enum InteractionCalibration {
    static func calibrate(snapshot: CalibrationSnapshot) throws -> InteractionPolicies {
        let chatNodes = snapshot.nodes.filter { $0.labelCategory == "chat-region" }
        guard chatNodes.count == 1, let chat = chatNodes.first else {
            throw InteractionCalibrationError.missingUniqueChatRegion
        }
        let composerNodes = snapshot.nodes.filter { $0.labelCategory == "input-control" }
        guard !composerNodes.isEmpty else {
            throw InteractionCalibrationError.missingUniqueComposer
        }
        let roles = composerNodes.map(\.role)
        let absoluteComposerRegion = composerNodes.map(\.relativeFrame).reduce(CGRect.null) { $0.union($1) }
        let composerRegion = CGRect(
            x: (absoluteComposerRegion.minX - chat.relativeFrame.minX) / max(chat.relativeFrame.width, 0.0001),
            y: (absoluteComposerRegion.minY - chat.relativeFrame.minY) / max(chat.relativeFrame.height, 0.0001),
            width: absoluteComposerRegion.width / max(chat.relativeFrame.width, 0.0001),
            height: absoluteComposerRegion.height / max(chat.relativeFrame.height, 0.0001)
        )
        let send = SendCandidateCalibration.decide(
            nodes: snapshot.nodes,
            composerFrame: absoluteComposerRegion
        )
        return InteractionPolicies(
            capture: CaptureSelectionPolicy(relativeMessageRect: chat.relativeFrame),
            composer: ComposerSelectionPolicy(
                acceptedRoles: roles,
                relativeRegion: composerRegion,
                fallback: SendFallbackPolicy(relativeClickPoint: send.fallbackPoint)
            ),
            sendTrigger: send.trigger,
            sendDiagnostic: send.diagnostic
        )
    }
}
