import Foundation

public enum IdentityPendingDisposition: Equatable, Sendable {
    case retry(attempt: Int)
    case park
    case suppressed
}

public struct IdentityPendingObservation: Equatable, Sendable {
    public let candidate: ConversationCandidate
    public let disposition: IdentityPendingDisposition
}

public struct IdentityPendingTracker: Sendable {
    private struct Entry: Sendable {
        var attempts: Int
        let firstSeenAt: Date
        var parked: Bool
    }

    private let maximumAttempts: Int
    private let maximumAge: TimeInterval
    private var entries: [String: Entry] = [:]

    public init(maximumAttempts: Int = 2, maximumAge: TimeInterval = 10) {
        self.maximumAttempts = max(1, maximumAttempts)
        self.maximumAge = max(0, maximumAge)
    }

    public mutating func observe(dotted: [ConversationCandidate], now: Date = Date()) -> [IdentityPendingObservation] {
        let unresolved = dotted.filter { $0.identity.resolved == nil }
        let activeKeys = Set(unresolved.map(fingerprint))
        entries = entries.filter { activeKeys.contains($0.key) }

        return unresolved.map { candidate in
            let key = fingerprint(candidate)
            guard var entry = entries[key] else {
                entries[key] = Entry(attempts: 1, firstSeenAt: now, parked: false)
                return IdentityPendingObservation(candidate: candidate, disposition: .retry(attempt: 1))
            }
            if entry.parked {
                return IdentityPendingObservation(candidate: candidate, disposition: .suppressed)
            }
            if now.timeIntervalSince(entry.firstSeenAt) >= maximumAge || entry.attempts >= maximumAttempts {
                entry.parked = true
                entries[key] = entry
                return IdentityPendingObservation(candidate: candidate, disposition: .park)
            }
            entry.attempts += 1
            entries[key] = entry
            return IdentityPendingObservation(candidate: candidate, disposition: .retry(attempt: entry.attempts))
        }
    }

    private func fingerprint(_ candidate: ConversationCandidate) -> String {
        let frame = candidate.frame
        let geometry = [frame.minX, frame.minY, frame.width, frame.height]
            .map { String(format: "%.2f", Double($0)) }
            .joined(separator: ",")
        return "\(candidate.nodeID)|\(geometry)|\(candidate.identity.diagnosticLabels.sorted().joined(separator: "\u{1F}"))"
    }
}
