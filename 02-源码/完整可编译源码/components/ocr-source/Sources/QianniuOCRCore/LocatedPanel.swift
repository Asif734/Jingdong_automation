import CoreGraphics
import Foundation

public struct LocatedPanel: Equatable, Sendable {
    public let ownerPID: Int32
    public let windowTitle: String
    public let windowFrame: CGRect
    public let panelFrame: CGRect
    public let identityCandidates: CustomerIdentityCandidates

    public init(
        ownerPID: Int32,
        windowTitle: String,
        windowFrame: CGRect,
        panelFrame: CGRect,
        identityCandidates: CustomerIdentityCandidates = .empty
    ) {
        self.ownerPID = ownerPID
        self.windowTitle = windowTitle
        self.windowFrame = windowFrame
        self.panelFrame = panelFrame
        self.identityCandidates = identityCandidates
    }
}
