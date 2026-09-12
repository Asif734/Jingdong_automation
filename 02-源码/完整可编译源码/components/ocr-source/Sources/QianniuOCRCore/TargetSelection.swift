import CoreGraphics
import Foundation

public struct WindowCandidate: Equatable, Sendable {
    public let id: UInt32
    public let ownerPID: Int32
    public let bundleID: String?
    public let title: String
    public let frame: CGRect
    public let isVisible: Bool

    public init(
        id: UInt32,
        ownerPID: Int32,
        bundleID: String?,
        title: String,
        frame: CGRect,
        isVisible: Bool
    ) {
        self.id = id
        self.ownerPID = ownerPID
        self.bundleID = bundleID
        self.title = title
        self.frame = frame
        self.isVisible = isVisible
    }
}

public struct AXCandidate: Equatable, Sendable {
    public let role: String
    public let title: String?
    public let description: String?
    public let value: String?
    public let frame: CGRect

    public init(
        role: String,
        title: String?,
        description: String?,
        value: String?,
        frame: CGRect
    ) {
        self.role = role
        self.title = title
        self.description = description
        self.value = value
        self.frame = frame
    }
}

public enum TargetSelection {
    public static func messagePanelFrame(
        policy: CaptureSelectionPolicy,
        inside window: CGRect
    ) -> CGRect? {
        let proposed = policy.absoluteMessageRect(in: window)
        guard proposed.width > 0, proposed.height > 0,
              window.contains(proposed) else { return nil }
        return proposed
    }

    public static func qianniuWindow(
        from candidates: [WindowCandidate],
        policy: WindowSelectionPolicy
    ) -> WindowCandidate? {
        candidates
            .filter { candidate in
                candidate.bundleID == "com.taobao.Aliworkbench"
                    && candidate.isVisible
                    && candidate.frame.width >= policy.minimumRelativeSize.width
                    && candidate.frame.height >= policy.minimumRelativeSize.height
                    && policy.requiredTitleTokens.allSatisfy { candidate.title.contains($0) }
            }
            .max { lhs, rhs in windowScore(lhs) < windowScore(rhs) }
    }

    public static func qianniuWindow(from candidates: [WindowCandidate]) -> WindowCandidate? {
        candidates
            .filter {
                $0.bundleID == "com.taobao.Aliworkbench"
                    && $0.isVisible
                    && $0.frame.width > 0
                    && $0.frame.height > 0
            }
            .max { lhs, rhs in windowScore(lhs) < windowScore(rhs) }
    }

    public static func messagePanel(
        from candidates: [AXCandidate],
        inside window: CGRect
    ) -> AXCandidate? {
        let containerRoles = Set(["AXGroup", "AXScrollArea", "AXList", "AXWebArea"])
        return candidates
            .filter { candidate in
                let labels = [candidate.title, candidate.description, candidate.value]
                    .compactMap { $0 }
                let matchesLabel = labels.contains { $0.contains("消息记录") }
                let visibleIntersection = candidate.frame.intersection(window)
                return containerRoles.contains(candidate.role)
                    && matchesLabel
                    && !visibleIntersection.isNull
                    && visibleIntersection.width > 0
                    && visibleIntersection.height > 0
            }
            .max { lhs, rhs in
                let leftArea = lhs.frame.intersection(window).area
                let rightArea = rhs.frame.intersection(window).area
                return leftArea < rightArea
            }
    }

    public static func relativeCrop(panel: CGRect, window: CGRect) -> CGRect? {
        let intersection = panel.intersection(window)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
            return nil
        }
        return CGRect(
            x: intersection.minX - window.minX,
            y: intersection.minY - window.minY,
            width: intersection.width,
            height: intersection.height
        )
    }

    public static func expandedMessagePanelFrame(anchor: CGRect, window: CGRect) -> CGRect? {
        let visibleAnchor = anchor.intersection(window)
        guard !visibleAnchor.isNull,
              visibleAnchor.width > 0,
              visibleAnchor.height > 0,
              visibleAnchor.minX < window.maxX,
              visibleAnchor.minY < window.maxY else {
            return nil
        }
        return CGRect(
            x: visibleAnchor.minX,
            y: visibleAnchor.minY,
            width: window.maxX - visibleAnchor.minX,
            height: window.maxY - visibleAnchor.minY
        )
    }

    public static func refreshButton(
        from candidates: [AXCandidate],
        nextTo tab: AXCandidate,
        inside window: CGRect
    ) -> AXCandidate? {
        candidates
            .filter { candidate in
                let labels = [candidate.title, candidate.description, candidate.value]
                    .compactMap { $0 }
                let visibleIntersection = candidate.frame.intersection(window)
                return candidate.role == "AXButton"
                    && labels.contains("刷新")
                    && !visibleIntersection.isNull
                    && visibleIntersection.width > 0
                    && visibleIntersection.height > 0
                    && candidate.frame.midX > tab.frame.midX
                    && abs(candidate.frame.midY - tab.frame.midY) <= max(44, tab.frame.height)
            }
            .min { lhs, rhs in
                hypot(lhs.frame.midX - tab.frame.maxX, lhs.frame.midY - tab.frame.midY)
                    < hypot(rhs.frame.midX - tab.frame.maxX, rhs.frame.midY - tab.frame.midY)
            }
    }

    private static func windowScore(_ candidate: WindowCandidate) -> Int {
        var score = 0
        if candidate.title.contains("接待中心") { score += 100 }
        if candidate.title.contains("-") { score += 10 }
        return score
    }
}

private extension CGRect {
    var area: CGFloat { width * height }
}
