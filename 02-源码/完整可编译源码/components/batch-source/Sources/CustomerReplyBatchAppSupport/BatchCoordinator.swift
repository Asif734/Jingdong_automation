import Foundation
import CustomerReplyBatchCore

public struct BatchSummary: Equatable, Sendable {
    public var total = 0
    public var autoSend = 0
    public var humanReview = 0
    public var noAction = 0
    public var failed = 0

    public init() {}
}

public protocol BatchRunning: Sendable {
    func runOnce() async -> BatchSummary
}

public final class BatchCoordinator: BatchRunning, @unchecked Sendable {
    private let store: QueueStore
    private let generator: any ReplyGenerating
    private let fileManager: FileManager
    private let knowledgeBasePaths: [String]
    private let onProgress: @Sendable (String, Int, Int) -> Void
    private let onTiming: @Sendable (BatchTimingRecord) -> Void
    private let senderTrigger: any SenderTriggering
    private let imageUsageRecorder: any PromptImageUsageRecording
    private let concurrencyPolicy: AdaptiveConcurrencyPolicy
    private let availableMemoryBytes: @Sendable () -> UInt64
    private let now: @Sendable () -> Date

    public init(
        store: QueueStore,
        generator: any ReplyGenerating,
        fileManager: FileManager = .default,
        knowledgeBasePaths: [String] = [],
        onProgress: @escaping @Sendable (String, Int, Int) -> Void = { _, _, _ in },
        onTiming: @escaping @Sendable (BatchTimingRecord) -> Void = { _ in },
        senderTrigger: any SenderTriggering = NoopSenderTrigger(),
        imageUsageRecorder: (any PromptImageUsageRecording)? = nil,
        concurrencyPolicy: AdaptiveConcurrencyPolicy? = nil,
        availableMemoryBytes: (@Sendable () -> UInt64)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.generator = generator
        self.fileManager = fileManager
        self.knowledgeBasePaths = knowledgeBasePaths
        self.onProgress = onProgress
        self.onTiming = onTiming
        self.senderTrigger = senderTrigger
        self.imageUsageRecorder = imageUsageRecorder ?? PromptImageUsageLogger(
            runtimeDirectory: store.layout.runtime,
            fileManager: fileManager
        )
        self.concurrencyPolicy = concurrencyPolicy ?? AdaptiveConcurrencyPolicy()
        self.availableMemoryBytes = availableMemoryBytes ?? {
            SystemMemoryProbe.availableBytes()
        }
        self.now = now
    }

    public func runOnce() async -> BatchSummary {
        var summary = BatchSummary()
        do {
            let lock = try await acquireBatchLockWaitingForActiveRun()
            withExtendedLifetime(lock) {}
            try store.recoverStaleClaims(olderThan: 30 * 60)
            repeat {
                try store.consumeRunRequest()
                let snapshot = try QueueSnapshot.load(
                    from: store.layout.pending,
                    fileManager: fileManager
                )
                summary.total += snapshot.count
                let passSummary = await process(snapshot: snapshot)
                summary.merge(passSummary)
            } while store.hasRunRequest()
            withExtendedLifetime(lock) {}
        } catch {
            summary.failed = max(1, summary.failed)
        }
        return summary
    }

    private func process(snapshot: [QueuePointer]) async -> BatchSummary {
        var summary = BatchSummary()
        await withTaskGroup(of: GenerationOutcome.self) { group in
            var nextIndex = 0
            var activeSlots = 0
            while nextIndex < snapshot.count || activeSlots > 0 {
                while nextIndex < snapshot.count {
                    guard concurrencyPolicy.decision(
                        availableMemoryBytes: availableMemoryBytes(),
                        now: now()
                    ) == .admit else { break }
                    let index = nextIndex
                    nextIndex += 1
                    let pointer = snapshot[index]
                    onProgress(pointer.uid, index + 1, snapshot.count)
                    let taskStart = ContinuousClock().now
                    do {
                        let task = try store.claim(pointer)
                        if store.outputExists(taskID: task.taskID) {
                            try store.removeClaim(task)
                            summary.noAction += 1
                        } else {
                            let prepared = PreparedTask(task: task, taskStart: taskStart)
                            activeSlots += 1
                            group.addTask { await self.generate(prepared) }
                        }
                    } catch {
                        summary.failed += 1
                    }
                }
                // Hard resource pressure/backpressure leaves untouched pointers in
                // pending. They are not claimed, failed, or assigned a fake slot.
                if activeSlots == 0 { break }
                if let outcome = await group.next() {
                    summary.merge(await finalize(outcome))
                    if case .success(_, let generated, _, _) = outcome,
                       let cleanupTask = generated.cleanupTask {
                        // Publish immediately, but keep the live CLI in its slot
                        // until process cleanup finishes, including before runOnce returns.
                        group.addTask {
                            await cleanupTask.value
                            return .cleanupFinished
                        }
                    } else {
                        activeSlots -= 1
                    }
                }
            }
        }
        return summary
    }

    private func generate(_ prepared: PreparedTask) async -> GenerationOutcome {
        let clock = ContinuousClock()
        do {
            let promptStart = clock.now
            let input = try loadPromptInput(for: prepared.task)
            let promptLoadMilliseconds = elapsedMilliseconds(promptStart, clock.now)
            await imageUsageRecorder.record(
                uid: prepared.task.pointer.uid,
                taskID: prepared.task.taskID,
                imagePaths: input.imagePaths
            )
            let generated = try await generator.generate(for: input)
            return .success(
                prepared,
                generated,
                promptLoadMilliseconds,
                elapsedMilliseconds(prepared.taskStart, clock.now)
            )
        } catch {
            return .failure(prepared.task, error.localizedDescription)
        }
    }

    private func finalize(_ outcome: GenerationOutcome) async -> BatchSummary {
        var summary = BatchSummary()
        switch outcome {
        case .cleanupFinished:
            break
        case .failure(let task, let message):
            if isExplicitBackpressure(message) {
                concurrencyPolicy.recordBackpressure(now: now())
            }
            summary.failed = 1
            try? store.recordFailure(for: task, error: BatchTaskError(message: message))
        case .success(let prepared, let generated, let promptLoadMilliseconds, let prePublishMilliseconds):
            concurrencyPolicy.recordSuccess(now: now())
            let clock = ContinuousClock()
            let publishStart = clock.now
            do {
                let reply = try ReplyRoutingPolicy.normalize(generated.reply)
                try store.publish(reply, for: prepared.task)
                let publishMilliseconds = elapsedMilliseconds(publishStart, clock.now)
                let taskProcessingMilliseconds = prePublishMilliseconds + publishMilliseconds
                let completedAt = Date()
                onTiming(
                    BatchTimingRecord(
                        createdAt: ISO8601DateFormatter().string(from: completedAt),
                        uid: prepared.task.pointer.uid,
                        taskID: prepared.task.taskID,
                        decision: reply.decision.rawValue,
                        model: generated.timing.model,
                        reasoningEffort: generated.timing.reasoningEffort,
                        queueWaitMilliseconds: queueWaitMilliseconds(
                            queuedAt: prepared.task.pointer.queuedAt,
                            completedAt: completedAt,
                            taskProcessingMilliseconds: taskProcessingMilliseconds
                        ),
                        promptLoadMilliseconds: promptLoadMilliseconds,
                        loginCheckMilliseconds: generated.timing.loginCheckMilliseconds,
                        codexExecMilliseconds: generated.timing.codexExecMilliseconds,
                        decodeMilliseconds: generated.timing.decodeMilliseconds,
                        publishMilliseconds: publishMilliseconds,
                        taskProcessingMilliseconds: taskProcessingMilliseconds,
                        cliTraceReportPath: generated.timing.cliTraceReportPath,
                        sessionMode: generated.timing.sessionMode,
                        submittedHistoryBytes: generated.timing.submittedHistoryBytes,
                        submittedImageCount: generated.timing.submittedImageCount,
                        sessionLeaseAgeMilliseconds: generated.timing.sessionLeaseAgeMilliseconds,
                        sessionRecoveryCount: generated.timing.sessionRecoveryCount
                    )
                )
                switch reply.decision {
                case .autoSend:
                    summary.autoSend = 1
                    await senderTrigger.trigger()
                case .humanReview: summary.humanReview = 1
                case .noAction: summary.noAction = 1
                }
            } catch {
                summary.failed = 1
                try? store.recordFailure(for: prepared.task, error: error)
            }
        }
        return summary
    }

    private func isExplicitBackpressure(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("rate limit")
            || normalized.contains("too many requests")
            || normalized.contains("http 429")
            || normalized.contains("resource temporarily unavailable")
            || normalized.contains("cannot allocate memory")
    }

    private func elapsedMilliseconds(
        _ start: ContinuousClock.Instant,
        _ end: ContinuousClock.Instant
    ) -> Double {
        let components = start.duration(to: end).components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private func queueWaitMilliseconds(
        queuedAt: String?,
        completedAt: Date,
        taskProcessingMilliseconds: Double
    ) -> Double? {
        guard let queuedAt, let queued = ISO8601DateFormatter().date(from: queuedAt) else { return nil }
        return max(0, completedAt.timeIntervalSince(queued) * 1_000 - taskProcessingMilliseconds)
    }

    private func acquireBatchLockWaitingForActiveRun() async throws -> BatchLock {
        while true {
            do {
                return try store.acquireBatchLock()
            } catch QueueStoreError.batchAlreadyRunning {
                try await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func loadPromptInput(for task: ClaimedTask) throws -> PromptInput {
        let user = URL(fileURLWithPath: task.pointer.userDirectory, isDirectory: true)
        let jsonlURL = user.appendingPathComponent("history.jsonl")
        let textURL = user.appendingPathComponent("history.txt")
        let historyJSONL = try String(contentsOf: jsonlURL, encoding: .utf8)
        let historyText = (try? String(contentsOf: textURL, encoding: .utf8)) ?? ""
        let imagesURL = user.appendingPathComponent("images", isDirectory: true)
        let imagePaths = ((try? fileManager.contentsOfDirectory(at: imagesURL, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["jpg", "jpeg", "png", "heic"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map(\.path)
        return PromptInput(
            uid: task.pointer.uid,
            historyVersion: task.pointer.historyVersion,
            historyJSONL: historyJSONL,
            historyText: historyText,
            imagePaths: imagePaths,
            knowledgeBasePaths: knowledgeBasePaths
        )
    }
}

private struct PreparedTask: Sendable {
    let task: ClaimedTask
    let taskStart: ContinuousClock.Instant
}

private enum GenerationOutcome: Sendable {
    case success(PreparedTask, GeneratedReply, Double, Double)
    case failure(ClaimedTask, String)
    case cleanupFinished
}

private struct BatchTaskError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

private extension BatchSummary {
    mutating func merge(_ other: BatchSummary) {
        total += other.total
        autoSend += other.autoSend
        humanReview += other.humanReview
        noAction += other.noAction
        failed += other.failed
    }
}
