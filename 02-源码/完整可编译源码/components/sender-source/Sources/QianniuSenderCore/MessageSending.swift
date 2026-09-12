import Foundation

public enum SendOutcome: Equatable, Sendable {
    case sent
    case failedBeforeSend(String)
    case uncertainAfterSend(String)
}

public protocol MessageSending: Sendable {
    func send(uid: String, text: String, attemptMarkerURL: URL?) async -> SendOutcome
}
