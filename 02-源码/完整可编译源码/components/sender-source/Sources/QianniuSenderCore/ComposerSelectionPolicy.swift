import CoreGraphics
import Foundation

public struct SendFallbackPolicy: Codable, Equatable, Sendable {
    public let relativeClickPoint: CGPoint?

    public init(relativeClickPoint: CGPoint?) {
        self.relativeClickPoint = relativeClickPoint
    }

    public func absoluteClickPoint(in window: CGRect, allowedRegion: CGRect) -> CGPoint? {
        guard let relativeClickPoint else { return nil }
        let point = CGPoint(
            x: window.minX + relativeClickPoint.x * window.width,
            y: window.minY + relativeClickPoint.y * window.height
        )
        return allowedRegion.contains(point) ? point : nil
    }
}

public struct ComposerSelectionPolicy: Codable, Equatable, Sendable {
    public let acceptedRoles: [String]
    public let relativeRegion: CGRect
    public let fallback: SendFallbackPolicy

    public init(
        acceptedRoles: [String],
        relativeRegion: CGRect,
        fallback: SendFallbackPolicy
    ) {
        self.acceptedRoles = Array(Set(acceptedRoles)).sorted()
        self.relativeRegion = relativeRegion
        self.fallback = fallback
    }

    public func absoluteRegion(in chatRegion: CGRect) -> CGRect {
        CGRect(
            x: chatRegion.minX + relativeRegion.minX * chatRegion.width,
            y: chatRegion.minY + relativeRegion.minY * chatRegion.height,
            width: relativeRegion.width * chatRegion.width,
            height: relativeRegion.height * chatRegion.height
        )
    }

    public static func resolveSendTrigger(
        role: String,
        actions: [String]
    ) -> QianniuSendTrigger? {
        switch role {
        case "AXButton" where actions.contains("AXPress"):
            return .accessibilityPress
        case "AXMenuButton":
            return .returnKeyOnce
        default:
            return nil
        }
    }
}
