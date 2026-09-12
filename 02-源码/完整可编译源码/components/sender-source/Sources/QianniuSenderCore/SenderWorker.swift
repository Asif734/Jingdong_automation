import Foundation

public struct SenderRunSummary: Equatable, Sendable {
    public var total = 0
    public var sent = 0
    public var failedBeforeSend = 0
    public var uncertainAfterSend = 0
    public var requiresConfirmationTaskID: String?
    public var skippedBecauseAlreadyRunning = false

    public init() {}
}

private final class SenderRunLock {
    private let url: URL
    deinit { try? FileManager.default.removeItem(at: url) }
    init(url: URL) { self.url = url }
}

public final class SenderWorker: @unchecked Sendable {
    private let store: SenderQueueStore
    private let sender: any MessageSending
    private let now: @Sendable () -> String

    public init(
        store: SenderQueueStore,
        sender: any MessageSending,
        now: @escaping @Sendable () -> String = { ISO8601DateFormatter().string(from: Date()) }
    ) {
        self.store = store
        self.sender = sender
        self.now = now
    }

    public func runUntilDrained() async -> SenderRunSummary {
        var summary = SenderRunSummary()
        guard let lock = acquireLock() else {
            summary.skippedBecauseAlreadyRunning = true
            return summary
        }
        withExtendedLifetime(lock) {}

        while true {
            let tasks: [OutgoingTask]
            do {
                tasks = try store.snapshot()
            } catch {
                summary.failedBeforeSend += 1
                break
            }
            guard !tasks.isEmpty else { break }
            for task in tasks {
                let claimed: ClaimedOutgoingTask
                do {
                    claimed = try store.claim(task)
                } catch {
                    continue
                }
                summary.total += 1
                let marker = store.layout.runtime
                    .appendingPathComponent("发送尝试", isDirectory: true)
                    .appendingPathComponent("\(task.taskID).json")
                let outcome = await sender.send(uid: task.uid, text: task.replyText, attemptMarkerURL: marker)
                do {
                    switch outcome {
                    case .sent:
                        try store.complete(claimed, sentAt: now())
                        summary.sent += 1
                    case .failedBeforeSend(let reason):
                        try store.failBeforeSend(claimed, reason: reason, failedAt: now())
                        summary.failedBeforeSend += 1
                    case .uncertainAfterSend(let reason):
                        try store.markUncertain(claimed, reason: reason, attemptedAt: now())
                        summary.uncertainAfterSend += 1
                        summary.requiresConfirmationTaskID = task.taskID
                        return summary
                    }
                } catch {
                    summary.uncertainAfterSend += 1
                    summary.requiresConfirmationTaskID = task.taskID
                    return summary
                }
            }
        }
        withExtendedLifetime(lock) {}
        return summary
    }

    private func acquireLock() -> SenderRunLock? {
        let url = store.layout.runtime.appendingPathComponent("sender.lock", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            return SenderRunLock(url: url)
        } catch {
            return nil
        }
    }
}
