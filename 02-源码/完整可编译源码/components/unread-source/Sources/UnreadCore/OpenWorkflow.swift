import CoreGraphics
import Foundation

public struct SceneSnapshot: Sendable, Equatable {
    public let windowID: UInt32
    public let frame: CGRect
    public let rows: [ConversationRow]
    public let candidates: [ConversationCandidate]
    public init(windowID: UInt32, frame: CGRect, rows: [ConversationRow]) {
        self.windowID = windowID
        self.frame = frame
        self.rows = rows
        candidates = rows.map {
            ConversationCandidate(nodeID: $0.nodeID, frame: $0.frame,
                                  identity: .full(uid: $0.uid, nickname: $0.nickname),
                                  latestPreviewIsImage: $0.latestPreviewIsImage)
        }
    }
    public init(windowID: UInt32, frame: CGRect, candidates: [ConversationCandidate]) {
        self.windowID = windowID
        self.frame = frame
        self.candidates = candidates
        rows = candidates.compactMap(\.row)
    }
}

public enum SceneFreshness {
    public static func confirmed(
        dotted: [ConversationCandidate],
        captured: SceneSnapshot,
        fresh: SceneSnapshot,
        tolerance: CGFloat = 3
    ) -> [ConversationCandidate]? {
        guard captured.windowID == fresh.windowID,
              approximatelyEqual(captured.frame, fresh.frame, tolerance: tolerance) else { return nil }
        return dotted.compactMap { target in
            let matches = fresh.candidates.filter { candidate in
                approximatelyEqual(target.frame, candidate.frame, tolerance: tolerance)
                    && sameIdentity(target.identity, candidate.identity)
            }
            return matches.count == 1 ? matches[0] : nil
        }
    }

    private static func sameIdentity(
        _ lhs: ConversationIdentityEvidence,
        _ rhs: ConversationIdentityEvidence
    ) -> Bool {
        if let identity = lhs.resolved { return rhs.resolved == identity }
        return rhs.resolved == nil
    }

    private static func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }
}
@MainActor public protocol UnreadSession {
    func check() throws
    func snapshot() throws -> SceneSnapshot
    func capture(_ snapshot: SceneSnapshot) async throws -> PixelImage
    func activate() async throws
    func click(_ row: ConversationRow, scene: SceneSnapshot) throws
    func header() async throws -> String?
}
public struct OpenOutcome: Equatable, Sendable {
    public let found: [String]
    public let verifiedUID: String?
}
@MainActor public enum OpenWorkflow {
    public static func run(session: any UnreadSession, pending: PendingHandoff? = nil, captureTimeout: Duration = .seconds(5), status: (String) -> Void = { _ in }, beforeClick: () throws -> Void = {}, afterVerified: (String) async throws -> Void = { _ in }) async throws -> OpenOutcome {
        status("检查权限与可见列表…")
        try session.check()
        let saved = try pending?.load()
        guard saved?.attempted != true else { throw AssistantError.unsafe("上次已尝试触发一期版，结果待核对；请查看一期版后清除标记，避免重复触发。") }
        func observed() async throws -> (SceneSnapshot, [ConversationRow]) {
            let before = try session.snapshot()
            let image = try await CaptureDeadline.run(timeout: captureTimeout) { try await session.capture(before) }
            try Task.checkCancellation()
            let after = try session.snapshot()
            guard before == after else { throw AssistantError.unsafe("截图期间窗口或列表已变化；未点击，请重试。") }
            return (after, RedDotDetector.targets(image: image, window: after.frame, rows: after.rows))
        }
        let (initial, unread) = try await observed()
        let targets: [ConversationRow]
        if let saved {
            guard let row = ConversationLocator.fresh(uid: saved.uid, rows: initial.rows) else { throw AssistantError.unsafe("待处理客户不在可见列表：\(saved.uid)；记录已保留，请显示该客户后重试。") }
            targets = [row]
        } else { targets = unread }
        guard let target = targets.first else { return OpenOutcome(found: [], verifiedUID: nil) }
        status("发现：" + targets.map(\.uid).joined(separator: "、"))
        let (refreshedScene, refreshedDots) = try await observed()
        let refreshed = saved == nil ? refreshedDots : refreshedScene.rows
        guard ConversationLocator.fresh(uid: target.uid, rows: refreshed) != nil else { throw AssistantError.unsafe("目标已消失或红点已改变；未点击。") }
        try await session.activate()
        status("打开并核对：" + target.uid)
        let (scene, finalDots) = try await observed()
        let finalTargets = saved == nil ? finalDots : scene.rows
        guard let fresh = ConversationLocator.fresh(uid: target.uid, rows: finalTargets) else { throw AssistantError.unsafe("激活后目标或红点已变化；未点击。") }
        try beforeClick()
        try pending?.save(uid: target.uid, attempted: false)
        try session.click(fresh, scene: scene)
        for attempt in 0..<8 {
            if ConversationLocator.verified(expected: target.uid, actual: try await session.header()) {
                try await afterVerified(target.uid)
                try pending?.clear()
                return OpenOutcome(found: targets.map(\.uid), verifiedUID: target.uid)
            }
            if attempt < 7 { try await Task.sleep(for: .milliseconds(150)) }
        }
        throw AssistantError.unsafe("聊天顶部完整 ID 与目标不一致；未确认打开，已停止。")
    }
}
