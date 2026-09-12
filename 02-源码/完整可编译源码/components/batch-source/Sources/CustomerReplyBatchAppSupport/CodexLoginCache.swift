import Foundation

public actor CodexLoginCache {
    private let ttl: TimeInterval
    private var lastSuccessfulCheck: Date?
    private var inFlightCheck: Task<Void, Error>?

    public init(ttl: TimeInterval = 60) {
        self.ttl = ttl
    }

    public func ensureLoggedIn(
        now: Date = Date(),
        check: @escaping @Sendable () async throws -> Void
    ) async throws {
        if let lastSuccessfulCheck,
           now.timeIntervalSince(lastSuccessfulCheck) < ttl {
            return
        }
        if let inFlightCheck {
            try await inFlightCheck.value
            return
        }

        let task = Task { try await check() }
        inFlightCheck = task
        do {
            try await task.value
            lastSuccessfulCheck = now
            inFlightCheck = nil
        } catch {
            inFlightCheck = nil
            throw error
        }
    }
}
