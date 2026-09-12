import Foundation
import QianniuVideoProbeCore

public struct VideoTransferFreshAddressRequest: Equatable, Sendable {
    public let customerUID: String
    public let messageHash: String

    public init(customerUID: String, messageHash: String) {
        self.customerUID = customerUID
        self.messageHash = messageHash
    }
}

public struct VideoTransferFailureNotice: Equatable, Sendable {
    public let customerUID: String
    public let messageHash: String
    public let category: VideoTransferFailureCategory

    public init(
        customerUID: String,
        messageHash: String,
        category: VideoTransferFailureCategory
    ) {
        self.customerUID = customerUID
        self.messageHash = messageHash
        self.category = category
    }
}

public struct VideoTransferPublicStatus: Equatable, Sendable {
    public let customerUID: String
    public let messageHash: String
    public let phase: DurableVideoTransferPhase
    public let attempt: Int

    public init(
        customerUID: String,
        messageHash: String,
        phase: DurableVideoTransferPhase,
        attempt: Int
    ) {
        self.customerUID = customerUID
        self.messageHash = messageHash
        self.phase = phase
        self.attempt = attempt
    }
}

public enum VideoTransferEvent: Sendable {
    case downloaded(DownloadedCustomerVideo)
    case immediateRoutesExhausted(VideoTransferFailureNotice)
    case freshAddressNeeded(VideoTransferFreshAddressRequest)
    case stateChanged(VideoTransferPublicStatus)
}

public actor VideoTransferCoordinator {
    public typealias Inspect = @Sendable (URL) async throws -> VideoTransferInspection
    public typealias EventHandler = @Sendable (VideoTransferEvent) async -> Void
    public typealias Now = @Sendable () -> Date
    public typealias Jitter = @Sendable (TimeInterval) -> TimeInterval
    public typealias Sleep = @Sendable (Duration) async -> Void

    private enum AttemptOutcome: Sendable {
        case downloaded(DownloadedCustomerVideo)
        case failed(VideoTransferAttemptError)
    }

    private let store: DurableVideoTransferStore
    private let systemDownloader: any VideoDownloadAttempting
    private let routeProvider: any AlternateVideoRouteProviding
    private let alternateDownloader: any AlternateRouteDownloading
    private let inspect: Inspect
    private let outputDirectory: URL
    private let now: Now
    private let jitter: Jitter
    private let sleep: Sleep
    private let immediateBudget: Duration
    private var handlers: [EventHandler] = []
    private var fallbackEmitted = Set<VideoTransferKey>()
    private var freshAddressEmitted = Set<VideoTransferKey>()
    private var wakeTasks: [VideoTransferKey: Task<Void, Never>] = [:]

    public init(
        store: DurableVideoTransferStore,
        systemDownloader: any VideoDownloadAttempting = SystemRouteVideoDownloader(),
        routeProvider: any AlternateVideoRouteProviding = AlternateVideoRouteProvider(),
        alternateDownloader: any AlternateRouteDownloading = AlternateRouteRace(
            downloader: CurlResolvedVideoDownloader(),
            validate: { url in _ = try await VideoFileInspector.inspect(url) }
        ),
        inspect: @escaping Inspect = { url in
            let value = try await VideoFileInspector.inspect(url)
            return VideoTransferInspection(
                bytes: value.bytes,
                sha256: value.sha256,
                durationSeconds: value.durationSeconds,
                width: value.width,
                height: value.height,
                videoCodec: value.videoCodec,
                audioCodec: value.audioCodec
            )
        },
        outputDirectory: URL,
        now: @escaping Now = { Date() },
        jitter: @escaping Jitter = { delay in
            Double.random(in: (-0.1 * delay)...(0.1 * delay))
        },
        sleep: @escaping Sleep = { duration in try? await Task.sleep(for: duration) },
        immediateBudget: Duration = .seconds(30)
    ) {
        self.store = store
        self.systemDownloader = systemDownloader
        self.routeProvider = routeProvider
        self.alternateDownloader = alternateDownloader
        self.inspect = inspect
        self.outputDirectory = outputDirectory
        self.now = now
        self.jitter = jitter
        self.sleep = sleep
        self.immediateBudget = immediateBudget
    }

    deinit {
        for task in wakeTasks.values { task.cancel() }
    }

    public func observe(_ handler: @escaping EventHandler) {
        handlers.append(handler)
    }

    public func start() async {
        await resume()
    }

    public func submitCapturedAddress(
        key: VideoTransferKey,
        source: URL,
        customerUID: String
    ) async {
        guard VideoURLPolicy.accepts(source) else { return }
        freshAddressEmitted.remove(key)
        do {
            let existing = try await store.beginOrRead(key: key, customerUID: customerUID)
            guard !Self.isTerminal(existing.phase) else { return }
            guard case .needsOpen = try await store.disposition(for: key) else { return }
            guard try await store.claimLease(key, duration: 45) else { return }
            try await store.transition(key, to: .addressCaptured)
            try await store.recordAttempt(key)
            let record = try await store.record(key)
            await publishStatus(record)

            try await store.transition(key, to: .downloading)
            await publishStatus(try await store.record(key))

            let outcome = await Self.runWithDeadline(
                immediateBudget,
                operation: {
                    await Self.performImmediateAttempt(
                        key: key,
                        customerUID: customerUID,
                        source: source,
                        store: self.store,
                        systemDownloader: self.systemDownloader,
                        routeProvider: self.routeProvider,
                        alternateDownloader: self.alternateDownloader,
                        inspect: self.inspect,
                        outputDirectory: self.outputDirectory,
                        now: self.now
                    )
                }
            )
            switch outcome {
            case .downloaded(let receipt):
                wakeTasks.removeValue(forKey: key)?.cancel()
                freshAddressEmitted.remove(key)
                await emit(.downloaded(receipt))
                await publishStatus(try await store.record(key))
            case .failed(let failure):
                await handleFailure(
                    key: key,
                    customerUID: customerUID,
                    failure: failure
                )
            }
        } catch {
            try? await store.releaseLease(key)
        }
    }

    public func reportAddressCaptureFailure(
        key: VideoTransferKey,
        customerUID: String
    ) async {
        do {
            let existing = try await store.beginOrRead(key: key, customerUID: customerUID)
            guard !Self.isTerminal(existing.phase) else { return }
            try await store.recordAttempt(key)
            await handleFailure(
                key: key,
                customerUID: customerUID,
                failure: VideoTransferAttemptError(
                    category: .addressUnavailable,
                    isRetryable: true,
                    sanitizedDescription: "未能从千牛新增日志取得视频地址"
                )
            )
        } catch {
            try? await store.releaseLease(key)
        }
    }

    public func resume() async {
        do {
            let records = try await store.allRecords()
            for record in records where Self.needsFallbackReplay(record) {
                guard let customerUID = record.customerUID,
                      fallbackEmitted.insert(record.key).inserted else { continue }
                await emit(.immediateRoutesExhausted(VideoTransferFailureNotice(
                    customerUID: customerUID,
                    messageHash: record.key.messageHash,
                    category: record.failure ?? .legacyUnknown
                )))
            }

            for record in try await store.dueRecords() {
                guard let customerUID = record.customerUID else { continue }
                guard try await store.claimLease(record.key, duration: 60) else { continue }
                guard freshAddressEmitted.insert(record.key).inserted else { continue }
                await emit(.freshAddressNeeded(VideoTransferFreshAddressRequest(
                    customerUID: customerUID,
                    messageHash: record.key.messageHash
                )))
                await publishStatus(try await store.record(record.key))
            }
        } catch {
            return
        }
    }

    private func handleFailure(
        key: VideoTransferKey,
        customerUID: String,
        failure: VideoTransferAttemptError
    ) async {
        let record = try? await store.record(key)
        let retryIndex = record?.scheduledRetryIndex ?? 0
        if failure.isRetryable && retryIndex < Self.retryDelays.count {
            let baseDelay = Self.retryDelays[retryIndex]
            let delay = max(1, baseDelay + jitter(baseDelay))
            let due = now().addingTimeInterval(delay)
            try? await store.scheduleRetry(
                key,
                failure: failure.category,
                nextAttemptAt: due,
                needsFreshAddress: true
            )
            scheduleWake(for: key, after: delay)
        } else {
            try? await store.transition(
                key,
                to: .terminalFailure,
                failure: failure.isRetryable ? .retryBudgetExhausted : failure.category
            )
        }
        if fallbackEmitted.insert(key).inserted {
            await emit(.immediateRoutesExhausted(VideoTransferFailureNotice(
                customerUID: customerUID,
                messageHash: key.messageHash,
                category: failure.category
            )))
        }
        await publishStatus(try? await store.record(key))
    }

    private func scheduleWake(for key: VideoTransferKey, after delay: TimeInterval) {
        wakeTasks.removeValue(forKey: key)?.cancel()
        let sleeper = sleep
        wakeTasks[key] = Task { [weak self] in
            await sleeper(.seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.resume()
        }
    }

    private func emit(_ event: VideoTransferEvent) async {
        for handler in handlers { await handler(event) }
    }

    private func publishStatus(_ record: DurableVideoTransferRecord?) async {
        guard let record, let customerUID = record.customerUID else { return }
        await emit(.stateChanged(VideoTransferPublicStatus(
            customerUID: customerUID,
            messageHash: record.key.messageHash,
            phase: record.phase,
            attempt: record.attemptCount
        )))
    }

    private static func performImmediateAttempt(
        key: VideoTransferKey,
        customerUID: String,
        source: URL,
        store: DurableVideoTransferStore,
        systemDownloader: any VideoDownloadAttempting,
        routeProvider: any AlternateVideoRouteProviding,
        alternateDownloader: any AlternateRouteDownloading,
        inspect: @escaping Inspect,
        outputDirectory: URL,
        now: @escaping Now
    ) async -> AttemptOutcome {
        let finalURL = outputDirectory.appendingPathComponent("\(key.messageHash).mp4")
        let systemPartial = outputDirectory.appendingPathComponent(
            ".\(key.messageHash).\(UUID().uuidString).system.partial.mp4"
        )
        defer { try? FileManager.default.removeItem(at: systemPartial) }
        do {
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: finalURL.path) {
                let inspection = try await inspect(finalURL)
                try await store.markDownloaded(key, fileName: finalURL.lastPathComponent)
                return .downloaded(Self.receipt(
                    key: key,
                    customerUID: customerUID,
                    url: finalURL,
                    bytes: inspection.bytes,
                    now: now
                ))
            }
            do {
                _ = try await systemDownloader.download(source, to: systemPartial)
                try await store.transition(key, to: .validating)
                let inspection = try await inspect(systemPartial)
                try FileManager.default.moveItem(at: systemPartial, to: finalURL)
                try await store.markDownloaded(key, fileName: finalURL.lastPathComponent)
                return .downloaded(Self.receipt(
                    key: key,
                    customerUID: customerUID,
                    url: finalURL,
                    bytes: inspection.bytes,
                    now: now
                ))
            } catch let failure as VideoTransferAttemptError where failure.isRetryable {
                try? FileManager.default.removeItem(at: systemPartial)
            } catch {
                return .failed(Self.classify(error))
            }

            let host = source.host?.lowercased() ?? ""
            let routes = try await routeProvider.candidates(for: host)
            let alternate = try await alternateDownloader.downloadFirstValid(
                source: source,
                candidates: routes,
                destination: finalURL
            )
            try await store.transition(key, to: .validating)
            let inspection = try await inspect(alternate.fileURL)
            try await store.markDownloaded(key, fileName: finalURL.lastPathComponent)
            return .downloaded(Self.receipt(
                key: key,
                customerUID: customerUID,
                url: finalURL,
                bytes: inspection.bytes,
                now: now
            ))
        } catch {
            try? FileManager.default.removeItem(at: finalURL)
            return .failed(Self.classify(error))
        }
    }

    private static func runWithDeadline(
        _ duration: Duration,
        operation: @escaping @Sendable () async -> AttemptOutcome
    ) async -> AttemptOutcome {
        await withTaskGroup(of: AttemptOutcome.self) { group in
            group.addTask { await operation() }
            group.addTask {
                do {
                    try await Task.sleep(for: duration)
                    return .failed(VideoTransferAttemptError(
                        category: .responseTimeout,
                        isRetryable: true,
                        sanitizedDescription: "视频即时恢复超过总时限"
                    ))
                } catch {
                    return .failed(VideoTransferAttemptError(
                        category: .connectionReset,
                        isRetryable: true,
                        sanitizedDescription: "视频即时恢复已取消"
                    ))
                }
            }
            let first = await group.next() ?? .failed(VideoTransferAttemptError(
                category: .responseTimeout,
                isRetryable: true,
                sanitizedDescription: "视频即时恢复没有结果"
            ))
            group.cancelAll()
            return first
        }
    }

    private static func receipt(
        key: VideoTransferKey,
        customerUID: String,
        url: URL,
        bytes: Int64,
        now: Now
    ) -> DownloadedCustomerVideo {
        DownloadedCustomerVideo(
            customerUID: customerUID,
            messageHash: key.messageHash,
            fileURL: url,
            bytes: bytes,
            completedAt: now()
        )
    }

    private static func classify(_ error: Error) -> VideoTransferAttemptError {
        if let typed = error as? VideoTransferAttemptError { return typed }
        if error is CancellationError {
            return VideoTransferAttemptError(
                category: .responseTimeout,
                isRetryable: true,
                sanitizedDescription: "视频下载已取消"
            )
        }
        return VideoTransferAttemptError(
            category: .invalidVideo,
            isRetryable: false,
            sanitizedDescription: "视频下载或校验失败"
        )
    }

    private static func isTerminal(_ phase: DurableVideoTransferPhase) -> Bool {
        switch phase {
        case .downloaded, .preparingEvidence, .readyForAI, .admittedToAI, .completed, .terminalFailure:
            return true
        default:
            return false
        }
    }

    private static func needsFallbackReplay(_ record: DurableVideoTransferRecord) -> Bool {
        !record.fallbackAdmitted
            && (record.phase == .waitingForRetry || record.phase == .terminalFailure)
    }

    private static let retryDelays: [TimeInterval] = [60, 180, 600]
}
