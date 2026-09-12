import CoreGraphics
import Foundation

public struct ConversationIdentityEvidence: Equatable, Sendable {
    private enum Resolution: Equatable, Sendable {
        case full(uid: String, nickname: String?)
        case uniquePrefix(String)
        case unresolved(labels: [String])
    }

    private let resolution: Resolution
    public let source: ConversationIdentitySource?

    public static func full(
        uid: String,
        nickname: String?,
        source: ConversationIdentitySource? = nil
    ) -> ConversationIdentityEvidence {
        ConversationIdentityEvidence(resolution: .full(uid: uid, nickname: nickname), source: source)
    }

    public static func uniquePrefix(
        _ prefix: String,
        source: ConversationIdentitySource = .uniquePrefix
    ) -> ConversationIdentityEvidence {
        ConversationIdentityEvidence(resolution: .uniquePrefix(prefix), source: source)
    }

    public static func unresolved(labels: [String]) -> ConversationIdentityEvidence {
        ConversationIdentityEvidence(resolution: .unresolved(labels: labels), source: nil)
    }

    public var resolved: String? {
        switch resolution {
        case .full(let uid, _): uid
        case .uniquePrefix(let prefix): prefix
        case .unresolved: nil
        }
    }

    public var nickname: String? {
        switch resolution {
        case .full(_, let nickname): nickname
        case .uniquePrefix(let prefix): prefix
        case .unresolved: nil
        }
    }

    var diagnosticLabels: [String] {
        switch resolution {
        case .full(let uid, let nickname): [uid, nickname].compactMap { $0 }
        case .uniquePrefix(let prefix): [prefix]
        case .unresolved(let labels): labels
        }
    }
}

public struct ConversationCandidate: Equatable, Sendable {
    public let nodeID: Int
    public let frame: CGRect
    public let identity: ConversationIdentityEvidence
    public let latestPreviewIsImage: Bool

    public init(nodeID: Int, frame: CGRect, identity: ConversationIdentityEvidence,
                latestPreviewIsImage: Bool = false) {
        self.nodeID = nodeID
        self.frame = frame
        self.identity = identity
        self.latestPreviewIsImage = latestPreviewIsImage
    }

    public var row: ConversationRow? {
        guard let uid = identity.resolved else { return nil }
        return ConversationRow(nodeID: nodeID, uid: uid, nickname: identity.nickname,
                               frame: frame, latestPreviewIsImage: latestPreviewIsImage)
    }
}
