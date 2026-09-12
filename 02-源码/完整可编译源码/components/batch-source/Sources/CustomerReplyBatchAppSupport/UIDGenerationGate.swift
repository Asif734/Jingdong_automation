import Foundation

public actor UIDGenerationGate {
    private var activeUIDs: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    public init() {}

    public func withPermit<T: Sendable>(
        for uid: String,
        operation: @Sendable () async throws -> T
    ) async rethrows -> T {
        await acquire(uid)
        defer { release(uid) }
        return try await operation()
    }

    private func acquire(_ uid: String) async {
        guard activeUIDs.contains(uid) else {
            activeUIDs.insert(uid)
            return
        }
        await withCheckedContinuation { continuation in
            waiters[uid, default: []].append(continuation)
        }
    }

    private func release(_ uid: String) {
        guard var queue = waiters[uid], !queue.isEmpty else {
            activeUIDs.remove(uid)
            waiters.removeValue(forKey: uid)
            return
        }
        let next = queue.removeFirst()
        if queue.isEmpty {
            waiters.removeValue(forKey: uid)
        } else {
            waiters[uid] = queue
        }
        next.resume()
    }
}
