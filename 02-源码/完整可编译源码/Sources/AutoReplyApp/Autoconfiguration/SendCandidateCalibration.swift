import CoreGraphics
import Foundation
import QianniuSenderCore

enum SendCandidateCalibration {
    private struct ScoredCandidate {
        let node: CalibrationAXNode
        let score: Int
    }

    static func decide(
        nodes: [CalibrationAXNode],
        composerFrame: CGRect
    ) -> SendCalibrationDecision {
        let composerParentIDs = Set(nodes.lazy
            .filter { $0.labelCategory == "input-control" }
            .compactMap(\.parentID))
        let pressable = nodes.filter { node in
            node.labelCategory == "send-control"
                || node.labelCategory == "press-control"
                || node.role == "AXMenuButton"
        }
        let eligible = pressable.compactMap { node -> ScoredCandidate? in
            var score = 0
            if node.labelCategory == "send-control" { score += 100 }
            if node.role == "AXButton", node.actionNames.contains("AXPress") { score += 20 }
            if node.role == "AXMenuButton" { score += 10 }

            let center = CGPoint(x: node.relativeFrame.midX, y: node.relativeFrame.midY)
            let besideComposer = center.x >= composerFrame.maxX
                && center.x <= composerFrame.maxX + 0.15
                && center.y >= composerFrame.minY - 0.06
                && center.y <= composerFrame.maxY + 0.06
            if besideComposer { score += 40 }
            if node.parentID.map(composerParentIDs.contains) == true { score += 20 }
            if center.y < composerFrame.minY - 0.10 { score -= 100 }
            return score >= 80 ? ScoredCandidate(node: node, score: score) : nil
        }.sorted {
            $0.score == $1.score ? $0.node.id < $1.node.id : $0.score > $1.score
        }

        let winner: CalibrationAXNode? = {
            guard let first = eligible.first else { return nil }
            guard eligible.count == 1 || first.score - eligible[1].score >= 20 else { return nil }
            return first.node
        }()
        let resolved = winner.flatMap {
            ComposerSelectionPolicy.resolveSendTrigger(role: $0.role, actions: $0.actionNames)
        }
        let trigger = resolved ?? .returnKeyOnce
        let verified = winner != nil && resolved != nil
        let strategy = trigger.rawValue
        let nextAction = verified
            ? "首次真实发送后核对输入框清空或客服气泡"
            : "使用 Return 发送；首次真实发送后自动核对结果"
        return SendCalibrationDecision(
            trigger: trigger,
            fallbackPoint: resolved == nil ? winner.map {
                CGPoint(x: $0.relativeFrame.midX, y: $0.relativeFrame.midY)
            } : nil,
            diagnostic: SendCalibrationDiagnostic(
                stage: "发送控件校准",
                rawPressableCount: pressable.count,
                eligibleCandidateCount: eligible.count,
                selectedStrategy: strategy,
                level: verified ? .verified : .fallback,
                canContinue: true,
                nextAction: nextAction
            )
        )
    }
}
