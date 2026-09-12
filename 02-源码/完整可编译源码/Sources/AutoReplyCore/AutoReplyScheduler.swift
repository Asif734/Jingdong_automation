import Foundation
import CustomerReplyBatchAppSupport
import CustomerReplyBatchCore

public struct SchedulerStageDeadlines: Sendable {
    public let discovery: Duration
    public let capture: Duration
    public let supplementCapture: Duration
    public let delivery: Duration

    public init(discovery: Duration, capture: Duration, supplementCapture: Duration, delivery: Duration) {
        self.discovery = discovery
        self.capture = capture
        self.supplementCapture = supplementCapture
        self.delivery = delivery
    }

    /// Outer scheduler deadlines are deliberately a little wider than the
    /// component deadlines. They are the final circuit breaker if a driver or
    /// test double never returns at all.
    public static let production = SchedulerStageDeadlines(
        discovery: .seconds(8),
        capture: .seconds(75),
        supplementCapture: .seconds(75),
        delivery: .seconds(25)
    )
}

@MainActor public final class AutoReplyScheduler {
    public private(set) var isRunning = false
    public var records: [SchedulerRecord] { persistent.records }
    public var events: [SchedulerEvent] { persistent.events }
    public private(set) var status = "Stopped"
    public var onChange: (() -> Void)?
    public var liveGenerationCount: Int { live.count }
    public var queuedGenerationCount: Int { records.filter { $0.state == .queued }.count }
    public var generationCapacity: Int {
        let queued = records.filter { $0.state == .queued && $0.nextAttemptAt <= now() }.count
        return concurrencyPolicy.decision(
            availableMemoryBytes: availableMemoryBytes(), now: now()
        ) == .admit ? live.count + queued : live.count
    }
    public var hasActiveUIOperation: Bool { activeUIWork != nil }
    private let driver: any AutomationDriver
    private let generator: any ReplyGenerating
    private let storage: SchedulerStorage
    private let concurrencyPolicy: AdaptiveConcurrencyPolicy
    private let availableMemoryBytes: () -> UInt64
    private let now: () -> Date
    private let stageDeadlines: SchedulerStageDeadlines
    private let onTerminalDelivery: @MainActor @Sendable (
        String, String, SchedulerDeliveryOutcome
    ) async -> Void
    // The exact cursor-tail capture already spends several seconds proving whether
    // the customer added anything during delivery. Keep only a short UI-settle
    // rearm after that proof instead of imposing another blind five-second wait.
    private let terminalRearmDelay: TimeInterval = 0.5
    private var persistent: SchedulerPersistentState
    private struct ActiveUIWork {
        let operationID: UUID
        let recordID: UUID?
        let uid: String?
        let stage: String
        let runID: UUID
    }
    private var activeUIWork: ActiveUIWork?
    private var activeUITask: Task<Void, Never>?
    /// Protects only the short selection/checkpoint transaction. It is released
    /// immediately after child UI work is dispatched and is not the old
    /// long-lived `pumping` gate.
    private var dispatching = false
    private let readySendBurstLimit = 3
    private var consecutiveReadyDispatches = 0
    private var persistenceFailed = false
    private var lastRuntimeIssue: String?
    private var runID = UUID()
    private var pumpTask: Task<Void, Never>?
    private struct LiveGeneration {
        let recordID: UUID
        let uid: String
        let task: Task<Void, Never>
    }
    // Process ownership outlives the ready/completed record until CLI cleanup finishes.
    private var live: [UUID: LiveGeneration] = [:]

    public init(driver: any AutomationDriver, generator: any ReplyGenerating, store: SchedulerStore,
                availableMemoryBytes: @escaping () -> UInt64 = { SystemMemoryProbe.availableBytes() },
                now: @escaping () -> Date = Date.init,
                stageDeadlines: SchedulerStageDeadlines = .production,
                onTerminalDelivery: @escaping @MainActor @Sendable (
                    String, String, SchedulerDeliveryOutcome
                ) async -> Void = { _, _, _ in }) throws {
        self.driver = driver; self.generator = generator; self.storage = SchedulerStorage(store: store); self.now = now
        self.stageDeadlines = stageDeadlines
        self.onTerminalDelivery = onTerminalDelivery
        self.concurrencyPolicy = AdaptiveConcurrencyPolicy()
        self.availableMemoryBytes = availableMemoryBytes
        persistent = try store.load()
        var recovered = persistent
        for index in recovered.records.indices {
            if recovered.records[index].automaticFollowUpCount != nil,
               ![.completed, .superseded].contains(recovered.records[index].state) {
                recovered.records[index].state = .superseded
                recovered.records[index].reply = nil
                recovered.records[index].pendingSupplement = nil
                recovered.records[index].supplementCapturePending = nil
                recovered.records[index].stageAttempt = nil
                recovered.records[index].lastError = "Legacy no-dot follow-up discarded; waiting for fresh unread discovery"
                recovered.records[index].updatedAt = now()
                recovered.records[index].nextAttemptAt = now()
                recovered.events.append(SchedulerEvent(
                    date: now(), uid: recovered.records[index].uid,
                    message: "Legacy no-dot follow-up superseded"
                ))
                continue
            }
            switch recovered.records[index].state {
            case .sending where recovered.records[index].sendWasInvoked == false:
                recovered.records[index].state = .ready
                recovered.records[index].deliveryOutcome = nil
                recovered.records[index].lastError = "Interrupted before send driver invocation; reply safely requeued"
                recovered.records[index].stageAttempt = nil
            case .sending, .uncertain:
                recovered.records[index].state = .completed
                recovered.records[index].deliveryOutcome = .uncertain
                recovered.records[index].lastError = "Interrupted or unverified send released without automatic resend"
                if let end = recovered.records[index].snapshot?.endCursor {
                    recovered.answeredCursors[recovered.records[index].uid] = end
                }
            case .capturing:
                recovered.records[index].state = .discovered
            case .generating:
                recovered.records[index].state = .queued
                recovered.records[index].attemptID = nil
            case .queued where recovered.records[index].attemptID != nil:
                recovered.records[index].attemptID = nil
            default: continue
            }
            recovered.records[index].updatedAt = now()
            recovered.records[index].nextAttemptAt = now()
            recovered.events.append(SchedulerEvent(date: now(), uid: recovered.records[index].uid,
                                                   message: "Recovered as \(recovered.records[index].state.rawValue)"))
        }
        if recovered != persistent { try store.save(recovered); persistent = try store.load() }
    }

    public func start() {
        guard !isRunning, !persistenceFailed else { return }
        isRunning = true; runID = UUID(); status = "Running"; lastRuntimeIssue = nil; onChange?()
        let token = runID
        pumpTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let scheduler = self, scheduler.isRunning, scheduler.runID == token else { return }
                await scheduler.tick()
                // Bound polling and relinquish actor ownership between safe UI boundaries.
                do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
            }
        }
    }

    public func stop() {
        driver.revokeUIOperations()
        isRunning = false; runID = UUID(); pumpTask?.cancel(); pumpTask = nil
        activeUITask?.cancel()
        if !persistenceFailed { status = "Stopped" }
        onChange?()
        // Do not cancel live processes: their replies and cleanup still need durable accounting.
    }

    /// Admits evidence prepared outside the shared Qianniu UI lane (for example,
    /// frames extracted from a downloaded customer video).
    public func admitExternalSnapshot(_ snapshot: CaptureSnapshot) async {
        guard !snapshot.uid.isEmpty,
              snapshot.shouldGenerate,
              snapshot.hasUnansweredCustomer else { return }
        guard !records.contains(where: {
            $0.uid == snapshot.uid && $0.customerRevision == snapshot.customerRevision
        }) else { return }
        let inserted = await commit("External customer evidence queued", uid: snapshot.uid) { state in
            state.records.append(SchedulerRecord(
                uid: snapshot.uid,
                sequence: state.nextSequence,
                state: .queued,
                snapshot: snapshot,
                createdAt: now(),
                updatedAt: now(),
                nextAttemptAt: now()
            ))
            state.nextSequence += 1
        }
        if inserted, isRunning { await refillSlots() }
    }

    public func admitPreparedReply(
        uid: String,
        customerRevision: String,
        historyJSONL: String,
        reply: ReplyEnvelope
    ) async -> PreparedReplyAdmission {
        guard !uid.isEmpty,
              !customerRevision.isEmpty,
              !historyJSONL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              reply.decision == .autoSend,
              !reply.replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .rejected
        }
        guard !records.contains(where: {
            $0.uid == uid && $0.customerRevision == customerRevision
        }) else { return .alreadyPresent }
        let snapshot = CaptureSnapshot(
            uid: uid,
            customerRevision: customerRevision,
            historyJSONL: historyJSONL,
            hasUnansweredCustomer: true,
            shouldGenerate: false,
            targetCustomerJSONL: historyJSONL
        )
        let inserted = await commit("Prepared customer reply queued", uid: uid) { state in
            state.records.append(SchedulerRecord(
                uid: uid,
                sequence: state.nextSequence,
                state: .ready,
                snapshot: snapshot,
                reply: reply,
                createdAt: now(),
                updatedAt: now(),
                nextAttemptAt: now()
            ))
            state.nextSequence += 1
        }
        if inserted, isRunning { await refillSlots() }
        return inserted ? .inserted : .rejected
    }

    @discardableResult
    public func admitExternalDiscovery(uid: String, sourceRevision: String) async -> Bool {
        guard !uid.isEmpty, !sourceRevision.isEmpty else { return false }
        guard !records.contains(where: {
            $0.uid == uid && $0.sourceRevision == sourceRevision
        }) else { return false }
        return await commit("External customer discovery queued", uid: uid) { state in
            state.records.append(SchedulerRecord(
                uid: uid,
                sequence: state.nextSequence,
                state: .discovered,
                createdAt: now(),
                updatedAt: now(),
                nextAttemptAt: now(),
                sourceRevision: sourceRevision
            ))
            state.nextSequence += 1
        }
    }

    /// One serialized UI unit. MainActor alone is insufficient because driver awaits are reentrant.
    public func tick() async {
        guard isRunning, !persistenceFailed, !dispatching else { return }
        dispatching = true
        defer { dispatching = false }
        let token = runID
        // Discovery can also navigate the UI. Detect vanished/corrupt state before even that read.
        do { _ = try await storage.load() }
        catch {
            persistenceFailed = true
            pause("Persistence failure; automation stopped: \(error.localizedDescription)")
            return
        }
        guard isCurrent(token) else { return }
        await refillSlots()
        // UI work is launched as a bounded child task. Ticks stay responsive,
        // but no second UI operation may start until that child publishes a
        // terminal result (success, failure, or timeout).
        guard activeUIWork == nil else { return }
        if consecutiveReadyDispatches >= readySendBurstLimit,
           records.contains(where: {
               $0.state == .ready && $0.nextAttemptAt <= now() && isHeadOfLine($0)
           }) {
            dispatchDiscovery(token: token)
            return
        }
        if let ready = records.filter({
            $0.state == .ready && $0.nextAttemptAt <= now() && $0.sendRetryDeferred != true
                && isHeadOfLine($0)
        }).min(by: { $0.sequence < $1.sequence }) {
            dispatchReadyTask(ready, token: token)
            return
        }
        if let pendingCapture = records.filter({
            $0.supplementCapturePending == true && $0.nextAttemptAt <= now()
                && [.queued, .generating, .ready].contains($0.state)
                && ($0.stageAttempt?.stage != "supplement-capture" || ($0.stageAttempt?.failures ?? 0) == 0)
                && isHeadOfLine($0)
        }).min(by: { $0.sequence < $1.sequence }) {
            dispatchSupplementCapture(pendingCapture, token: token)
            return
        }
        if let discovered = nextDiscoveredRecord(retry: false) {
            dispatchCapture(discovered, token: token)
        } else if let pendingRetry = records.filter({
            $0.supplementCapturePending == true && $0.nextAttemptAt <= now()
                && [.queued, .generating, .ready].contains($0.state)
                && $0.stageAttempt?.stage == "supplement-capture"
                && ($0.stageAttempt?.failures ?? 0) > 0
                && isHeadOfLine($0)
        }).min(by: { $0.sequence < $1.sequence }) {
            dispatchSupplementCapture(pendingRetry, token: token)
        } else if let discoveredRetry = nextDiscoveredRecord(retry: true) {
            dispatchCapture(discoveredRetry, token: token)
        } else if let deferredSend = records.filter({
            $0.state == .ready && $0.sendRetryDeferred == true
                && $0.nextAttemptAt <= now()
                && ($0.sendRetryNeedsDiscovery != true || $0.updatedAt.addingTimeInterval(10) <= now())
                && isHeadOfLine($0)
        }).min(by: { $0.sequence < $1.sequence }) {
            dispatchDelivery(deferredSend, token: token)
        } else {
            dispatchDiscovery(token: token)
        }
    }

    private func nextDiscoveredRecord(retry: Bool) -> SchedulerRecord? {
        records.filter { $0.state == .discovered && $0.nextAttemptAt <= now() }
            .filter { isHeadOfLine($0) }
            .filter {
                let failures = $0.stageAttempt?.stage == "capture" ? ($0.stageAttempt?.failures ?? 0) : 0
                return retry ? failures > 0 : failures == 0
            }
            .min(by: { $0.sequence < $1.sequence })
    }

    /// Multiple pieces of frozen work may wait for one customer, but only the
    /// oldest non-terminal record may advance. This keeps video evidence in
    /// the ordinary per-customer queue without allowing two UI/generation
    /// transactions for the same conversation to overlap.
    private func isHeadOfLine(_ record: SchedulerRecord) -> Bool {
        !records.contains {
            $0.uid == record.uid && !$0.state.isTerminal && $0.sequence < record.sequence
        }
    }

    private static func videoHash(in revision: String, prefix: String) -> String? {
        guard revision.hasPrefix(prefix) else { return nil }
        let hash = String(revision.dropFirst(prefix.count))
        return hash.isEmpty ? nil : hash
    }

    /// Visual capture reports `video:<hash>` while completed video analysis
    /// reports `video-analysis:<hash>`. The visual marker is not new customer
    /// work when an analysis record with the same content hash already exists.
    private func isVideoMarkerCoveredByAnalysis(_ revision: String, uid: String) -> Bool {
        guard let markerHash = Self.videoHash(in: revision, prefix: "video:") else { return false }
        return records.contains { record in
            guard record.uid == uid,
                  let analyzedHash = record.customerRevision.flatMap({
                      Self.videoHash(in: $0, prefix: "video-analysis:")
                  }) else { return false }
            return analyzedHash == markerHash
        }
    }

    private func installUIWork(
        recordID: UUID?, uid: String?, stage: String, token: UUID,
        operation: @escaping @MainActor () async -> Void
    ) {
        guard activeUIWork == nil, isCurrent(token) else { return }
        let operationID = UUID()
        activeUIWork = ActiveUIWork(
            operationID: operationID, recordID: recordID, uid: uid, stage: stage, runID: token
        )
        activeUITask = Task { [weak self] in
            await operation()
            self?.finishUIWork(operationID: operationID)
        }
        onChange?()
    }

    private func finishUIWork(operationID: UUID) {
        guard activeUIWork?.operationID == operationID else { return }
        activeUIWork = nil
        activeUITask = nil
        onChange?()
    }

    private func dispatchDiscovery(token: UUID) {
        let driver = self.driver
        let deadline = stageDeadlines.discovery
        installUIWork(recordID: nil, uid: nil, stage: "discovery", token: token) { [weak self] in
            guard let self else { return }
            do {
                let uids = try await withOperationDeadline(deadline, stage: "scheduler-discovery") {
                    try await driver.discover()
                }
                guard self.isCurrent(token) else { return }
                await self.admit(uids)
                let deferredIDs = self.records.filter {
                    $0.state == .ready && $0.sendRetryDeferred == true && $0.sendRetryNeedsDiscovery == true
                }.map(\.id)
                if !deferredIDs.isEmpty {
                    await self.commit("Deferred sends moved behind the latest discovery pass") { state in
                        for index in state.records.indices where deferredIDs.contains(state.records[index].id) {
                            state.records[index].sendRetryNeedsDiscovery = false
                        }
                    }
                }
                for uid in uids {
                    guard let generating = self.records.first(where: {
                        $0.uid == uid && $0.state == .generating && $0.pendingSupplement == nil
                            && $0.supplementCapturePending != true
                            && $0.supplementCaptureAbandoned != true
                    }) else { continue }
                    _ = await self.update(generating.id, message: "Customer supplement capture scheduled") {
                        $0.supplementCapturePending = true
                        $0.imageCaptureAttempted = false
                        $0.nextAttemptAt = self.now()
                    }
                }
                await self.markRuntimeHealthy(recovering: "发现会话")
                self.consecutiveReadyDispatches = 0
            } catch {
                guard self.isCurrent(token) else { return }
                await self.reportRuntimeIssue("发现会话失败，正在自动重试：\(error.localizedDescription)")
                self.consecutiveReadyDispatches = 0
            }
        }
    }

    private func isCurrent(_ token: UUID) -> Bool { isRunning && runID == token && !persistenceFailed }

    @discardableResult private func commit(_ message: String, uid: String? = nil,
                                           _ change: (inout SchedulerPersistentState) -> Void) async -> Bool {
        guard !persistenceFailed else { return false }
        do {
            let committed = try await storage.commit(date: now(), message: message, uid: uid, change: change)
            if committed.nextEventSequence >= persistent.nextEventSequence {
                persistent = committed
            }
            onChange?()
            return true
        } catch {
            persistenceFailed = true
            pause("Persistence failure; automation stopped: \(error.localizedDescription)")
            return false
        }
    }

    private func pause(_ message: String) {
        driver.revokeUIOperations()
        isRunning = false; runID = UUID(); pumpTask?.cancel(); pumpTask = nil
        activeUITask?.cancel()
        status = message; onChange?()
    }

    /// A single UI/job failure must never stop the 24-hour scheduler. The
    /// unsafe action itself remains blocked by its caller; this only keeps the
    /// global loop alive and leaves durable evidence for diagnosis.
    private func reportRuntimeIssue(_ message: String, uid: String? = nil) async {
        guard isRunning, !persistenceFailed else { return }
        status = "Running · \(message)"
        guard lastRuntimeIssue != message else { onChange?(); return }
        lastRuntimeIssue = message
        guard !persistenceFailed else { onChange?(); return }
        _ = await commit("Scheduler continuing after error: \(message)", uid: uid) { _ in }
    }

    private func markRuntimeHealthy(recovering expectedIssueFragment: String? = nil) async {
        guard isRunning, !persistenceFailed, let issue = lastRuntimeIssue else { return }
        if let expectedIssueFragment, !issue.contains(expectedIssueFragment) { return }
        lastRuntimeIssue = nil
        status = "Running"
        _ = await commit("Scheduler recovered; automatic scanning continues") { _ in }
    }

    private func admit(_ uids: [String]) async {
        var seen = Set(records.filter { !$0.state.isTerminal }.map(\.uid))
        let eligible = uids.filter { uid in
            guard !uid.isEmpty, seen.insert(uid).inserted else { return false }
            // Repeated red dots may be observed again, but never spin a capture loop.
            return !records.contains { $0.uid == uid && $0.state.isTerminal && $0.nextAttemptAt > now() }
        }
        guard !eligible.isEmpty else { return }
        await commit("Discovered \(eligible.count) customer(s)") { state in
            for uid in eligible {
                state.records.append(SchedulerRecord(uid: uid, sequence: state.nextSequence,
                    createdAt: now(), updatedAt: now(), nextAttemptAt: now()))
                state.nextSequence += 1
            }
        }
    }

    private func update(
        _ id: UUID,
        message: String,
        expected: (SchedulerRecord) -> Bool = { _ in true },
        _ change: (inout SchedulerRecord) -> Void
    ) async -> Bool {
        guard persistent.records.contains(where: { $0.id == id }) else { return false }
        let updatedAt = now()
        do {
            let result = try await storage.updateRecord(
                date: updatedAt,
                message: message,
                id: id,
                expected: expected,
                change: change
            )
            if result.state.nextEventSequence >= persistent.nextEventSequence {
                persistent = result.state
            }
            if result.applied { onChange?() }
            return result.applied
        } catch {
            persistenceFailed = true
            pause("Persistence failure; automation stopped: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    private func finish(
        _ id: UUID,
        message: String,
        deliveryOutcome: SchedulerDeliveryOutcome? = nil
    ) async -> Bool {
        await update(id, message: message) { record in
            record.state = .completed; record.nextAttemptAt = now().addingTimeInterval(terminalRearmDelay)
            record.deliveryOutcome = deliveryOutcome; record.pendingSupplement = nil
            record.supplementCapturePending = nil
        }
    }

    private func dispatchCapture(_ record: SchedulerRecord, token: UUID) {
        installUIWork(recordID: record.id, uid: record.uid, stage: "capture", token: token) { [weak self] in
            await self?.capture(record, token: token)
        }
    }

    private func dispatchSupplementCapture(_ record: SchedulerRecord, token: UUID) {
        installUIWork(recordID: record.id, uid: record.uid, stage: "supplement-capture", token: token) { [weak self] in
            guard let self else { return }
            if await self.captureSupplement(for: record, token: token) {
                await self.markRuntimeHealthy(recovering: "补充消息")
            }
        }
    }

    private func dispatchDelivery(_ record: SchedulerRecord, token: UUID) {
        consecutiveReadyDispatches += 1
        installUIWork(recordID: record.id, uid: record.uid, stage: "delivery", token: token) { [weak self] in
            await self?.deliver(record, token: token)
        }
    }

    private func dispatchReadyTask(_ record: SchedulerRecord, token: UUID) {
        switch record.effectiveTaskKind {
        case .customerReply:
            dispatchDelivery(record, token: token)
        case .transfer:
            dispatchTransfer(record, token: token)
        }
    }

    private func dispatchTransfer(_ record: SchedulerRecord, token: UUID) {
        consecutiveReadyDispatches += 1
        installUIWork(recordID: record.id, uid: record.uid, stage: "transfer", token: token) { [weak self] in
            await self?.transfer(record, token: token)
        }
    }

    private func reserveStageAttempt(
        _ id: UUID,
        stage: String,
        deadline: Duration,
        message: String,
        expected: (SchedulerRecord) -> Bool = { _ in true },
        change: (inout SchedulerRecord) -> Void = { _ in }
    ) async -> Bool {
        guard let operationID = activeUIWork?.operationID else { return false }
        return await update(id, message: message, expected: expected) { record in
            let failures = record.stageAttempt?.stage == stage ? (record.stageAttempt?.failures ?? 0) : 0
            record.stageAttempt = StageAttempt(
                stage: stage,
                failures: failures,
                operationID: operationID,
                startedAt: now(),
                deadlineAt: now().addingTimeInterval(deadline.timeInterval)
            )
            change(&record)
        }
    }

    private func captureSupplement(for record: SchedulerRecord, token: UUID) async -> Bool {
        guard isCurrent(token) else { return false }
        do {
            guard let currentBeforeCapture = records.first(where: { $0.id == record.id }) else { return false }
            let includeImages = currentBeforeCapture.imageCaptureAttempted != true
            if includeImages {
                guard await update(record.id, message: "Image capture attempt reserved", {
                    $0.imageCaptureAttempted = true
                }) else { return false }
            }
            let boundary = record.snapshot?.endCursor
                ?? persistent.answeredCursors[record.uid]
                ?? .empty
            let driver = self.driver
            let deadline = stageDeadlines.supplementCapture
            guard await reserveStageAttempt(
                record.id,
                stage: "supplement-capture",
                deadline: deadline,
                message: "Supplement capture attempt started",
                expected: { $0.supplementCapturePending == true }
            ) else { return false }
            let snapshot = try await withOperationDeadline(
                deadline,
                stage: "scheduler-supplement-capture"
            ) {
                try await driver.capture(uid: record.uid, after: boundary, includeImages: includeImages)
            }
            guard isCurrent(token) else { return false }
            guard await validate(snapshot, for: record, expectedStart: boundary), isCurrent(token) else { return false }
            if isVideoMarkerCoveredByAnalysis(snapshot.customerRevision, uid: record.uid) {
                _ = await update(record.id, message: "Duplicate video marker ignored by hash") {
                    if $0.pendingSupplement?.customerRevision == snapshot.customerRevision {
                        $0.pendingSupplement = nil
                    }
                    $0.supplementCapturePending = nil
                    $0.stageAttempt = nil
                    $0.nextAttemptAt = now()
                }
                return true
            }
            guard snapshot.customerRevision != record.customerRevision else {
                _ = await update(record.id, message: "Supplement observation unchanged") {
                    $0.supplementCapturePending = nil
                    $0.stageAttempt = nil
                    $0.nextAttemptAt = now()
                }
                return true
            }
            guard let current = records.first(where: { $0.id == record.id }) else { return false }
            switch current.state {
            case .generating:
                _ = await update(record.id, message: "Customer supplement captured during generation") {
                    $0.pendingSupplement = snapshot
                    $0.supplementCapturePending = nil
                    $0.stageAttempt = nil
                    $0.nextAttemptAt = now()
                }
            case .ready:
                _ = await update(record.id, message: "Customer supplement retained behind ready reply") {
                    $0.pendingSupplement = snapshot
                    $0.supplementCapturePending = nil
                    $0.stageAttempt = nil
                    $0.nextAttemptAt = now()
                }
            case .queued:
                _ = await update(record.id, message: "Customer supplement retained behind frozen queued input") {
                    $0.pendingSupplement = snapshot
                    $0.supplementCapturePending = nil
                    $0.stageAttempt = nil
                    $0.nextAttemptAt = now()
                }
                await refillSlots()
            default:
                return false
            }
            return true
        } catch {
            await failSupplementCapture(
                record.id,
                error: error.localizedDescription,
                resetImageCaptureAttempt: Self.failedBeforeMedia(error)
            )
            await reportRuntimeIssue("补充消息采集失败，生成任务继续：\(error.localizedDescription)", uid: record.uid)
            return false
        }
    }

    private func capture(_ record: SchedulerRecord, token: UUID) async {
        let includeImages = record.imageCaptureAttempted != true
        let deadline = stageDeadlines.capture
        guard await reserveStageAttempt(
            record.id,
            stage: "capture",
            deadline: deadline,
            message: "Capture started",
            expected: { $0.state == .discovered },
            change: {
            $0.state = .capturing
            if includeImages { $0.imageCaptureAttempted = true }
        }) else { return }
        // Persistence publishes synchronously: an observer may have stopped/restarted us.
        guard isCurrent(token) else {
            _ = await update(record.id, message: "Capture deferred before UI action") { $0.state = .discovered }
            return
        }
        do {
            let boundary = persistent.answeredCursors[record.uid] ?? .empty
            let driver = self.driver
            let snapshot = try await withOperationDeadline(deadline, stage: "scheduler-capture") {
                try await driver.capture(uid: record.uid, after: boundary, includeImages: includeImages)
            }
            guard isCurrent(token) else {
                _ = await update(record.id, message: "Late capture discarded after run changed") { current in
                    current.state = .discovered
                    current.nextAttemptAt = now()
                }
                return
            }
            guard await validate(snapshot, for: record, expectedStart: boundary) else { return }
            let handled = records.first {
                $0.id != record.id && $0.uid == record.uid && [.completed, .superseded].contains($0.state)
                    && $0.customerRevision == snapshot.customerRevision
            }
            if let handled {
                // Coalesce a repeated observation, not a new customer task. Preserve frozen history/reply.
                await commit("Observation unchanged; no duplicate job", uid: record.uid) { state in
                    state.records.removeAll { $0.id == record.id }
                    if let index = state.records.firstIndex(where: { $0.id == handled.id }) {
                        state.records[index].updatedAt = now()
                        state.records[index].nextAttemptAt = now().addingTimeInterval(terminalRearmDelay)
                    }
                }
                return
            }
            let eligible = snapshot.shouldGenerate && snapshot.hasUnansweredCustomer
            guard await update(record.id, message: eligible ? "Frozen input queued" : "Observation completed", { current in
                current.snapshot = snapshot; current.state = eligible ? .queued : .completed
                current.stageAttempt = nil
                current.nextAttemptAt = eligible ? now() : now().addingTimeInterval(terminalRearmDelay)
            }) else { return }
            if isCurrent(token) { await refillSlots() }
        } catch {
            await handleStageUIFailure(
                record.id,
                state: .discovered,
                stage: "capture",
                error: error,
                resetImageCaptureAttempt: Self.failedBeforeMedia(error)
            )
        }
    }

    private static func failedBeforeMedia(_ error: Error) -> Bool {
        guard let automationError = error as? AutomationDriverError else { return false }
        if case .captureFailedBeforeMedia = automationError { return true }
        return false
    }

    private func validate(
        _ snapshot: CaptureSnapshot,
        for record: SchedulerRecord,
        expectedStart: CustomerCursor? = nil
    ) async -> Bool {
        guard snapshot.uid == record.uid else {
            let message = "Capture UID mismatch (expected \(record.uid), received \(snapshot.uid)); verify UI"
            await retry(record.id, state: .discovered, error: message)
            await reportRuntimeIssue("身份核对失败；该任务已隔离：\(message)", uid: record.uid)
            return false
        }
        if let start = snapshot.startCursor, let expectedStart, start != expectedStart {
            let message = "Capture cursor mismatch (expected \(expectedStart.count), received \(start.count)); retrying exact batch"
            await retry(record.id, state: record.state == .capturing ? .discovered : record.state, error: message)
            await reportRuntimeIssue("客户消息批次核对失败；该任务稍后重试", uid: record.uid)
            return false
        }
        if let start = snapshot.startCursor, let end = snapshot.endCursor, end.count < start.count {
            await retry(record.id, state: record.state == .capturing ? .discovered : record.state,
                  error: "Capture cursor end precedes start")
            return false
        }
        return true
    }

    private func refillSlots() async {
        guard isRunning, !persistenceFailed else { return }
        let token = runID
        while concurrencyPolicy.decision(
            availableMemoryBytes: availableMemoryBytes(), now: now()
        ) == .admit {
            let ownedUIDs = Set(live.values.map(\.uid))
            guard let record = records.filter({
                $0.state == .queued && $0.nextAttemptAt <= now() && !ownedUIDs.contains($0.uid)
                    && $0.supplementCapturePending != true
                    && isHeadOfLine($0)
            })
                .min(by: { $0.sequence < $1.sequence }), let snapshot = record.snapshot else { return }
            let attempt = UUID()
            guard await update(
                record.id,
                message: "Generation started",
                expected: { $0.state == .queued && $0.attemptID == nil },
                { $0.state = .generating; $0.attemptID = attempt }
            ) else { return }
            guard isCurrent(token) else {
                _ = await update(record.id, message: "Generation deferred before dispatch") { $0.state = .queued; $0.attemptID = nil }
                return
            }
            let generator = self.generator
            let task = Task { [weak self] in
                do {
                    let generated = try await generator.generate(for: snapshot.promptInput)
                    await self?.received(generated, recordID: record.id, attempt: attempt)
                    // Publish the reply above, but do not release the process or its UID yet.
                    if let cleanup = generated.cleanupTask { await cleanup.value }
                } catch { await self?.generationFailed(recordID: record.id, attempt: attempt, error: error) }
                await self?.release(attempt: attempt, recordID: record.id)
            }
            live[attempt] = LiveGeneration(recordID: record.id, uid: record.uid, task: task)
            onChange?()
            guard isCurrent(token) else { return }
        }
    }

    private func received(_ generated: GeneratedReply, recordID: UUID, attempt: UUID) async {
        guard live[attempt]?.recordID == recordID,
              let record = records.first(where: { $0.id == recordID }),
              record.attemptID == attempt, record.state == .generating else { return }
        guard !generated.reply.replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            await generationFailed(
                recordID: recordID,
                attempt: attempt,
                error: CodexGeneratorError.invalidReply("Empty generated reply")
            )
            return
        }
        concurrencyPolicy.recordSuccess(now: now())
        let lifecycle = sessionLifecycleStage(generated.timing)
        if let supplement = record.pendingSupplement,
           supplement.customerRevision != record.customerRevision,
           !isVideoMarkerCoveredByAnalysis(supplement.customerRevision, uid: record.uid) {
            _ = await publishGeneratedReply(recordID: recordID, attempt: attempt, generated: generated, message: lifecycle.map {
                "Reply ready · newer customer batch retained · \($0)"
            } ?? "Reply ready · newer customer batch retained", sessionStage: lifecycle,
                clearSupplementCapture: true)
            return
        }
        _ = await publishGeneratedReply(recordID: recordID, attempt: attempt, generated: generated,
            message: lifecycle.map { "Reply ready · \($0)" } ?? "Reply ready",
            sessionStage: lifecycle, clearSupplementCapture: false)
    }

    private func publishGeneratedReply(
        recordID: UUID,
        attempt: UUID,
        generated: GeneratedReply,
        message: String,
        sessionStage: String?,
        clearSupplementCapture: Bool
    ) async -> Bool {
        await commit(message, uid: records.first(where: { $0.id == recordID })?.uid) { state in
            guard let index = state.records.firstIndex(where: { $0.id == recordID }),
                  state.records[index].state == .generating,
                  state.records[index].attemptID == attempt else { return }
            state.records[index].state = .ready
            state.records[index].reply = generated.reply
            state.records[index].sessionStage = sessionStage
            state.records[index].nextAttemptAt = now()
            if clearSupplementCapture { state.records[index].supplementCapturePending = nil }

            guard generated.reply.action == .replyThenTransfer,
                  let snapshot = state.records[index].snapshot else { return }
            let sourceRevision = "transfer:\(recordID.uuidString)"
            guard !state.records.contains(where: {
                $0.effectiveTaskKind == .transfer && $0.sourceRevision == sourceRevision
            }) else { return }
            state.records.append(SchedulerRecord(
                uid: state.records[index].uid,
                sequence: state.nextSequence,
                state: .ready,
                snapshot: snapshot,
                reply: generated.reply,
                createdAt: now(),
                updatedAt: now(),
                nextAttemptAt: now(),
                sourceRevision: sourceRevision,
                taskKind: .transfer
            ))
            state.nextSequence += 1
        }
    }

    private func generationFailed(recordID: UUID, attempt: UUID, error: Error) async {
        guard live[attempt]?.recordID == recordID,
              let record = records.first(where: { $0.id == recordID }),
              record.attemptID == attempt, record.state == .generating else { return }
        let message = error.localizedDescription
        if isExplicitBackpressure(message) {
            concurrencyPolicy.recordBackpressure(now: now())
        }
        switch CodexFailureRoutingPolicy.disposition(for: error) {
        case .unrelated:
            await retry(recordID, state: .queued, error: message)
        case .transferImmediately:
            await publishCodexFailureTransfer(
                recordID: recordID,
                attempt: attempt,
                error: message
            )
        case .retryOnce:
            if CodexFailureRoutingPolicy.isStoredCodexFailure(record.lastError) {
                await publishCodexFailureTransfer(
                    recordID: recordID,
                    attempt: attempt,
                    error: message
                )
            } else {
                await retry(recordID, state: .queued, error: message)
            }
        }
    }

    private func publishCodexFailureTransfer(
        recordID: UUID,
        attempt: UUID,
        error: String
    ) async {
        let fallback = ReplyEnvelope(
            action: .replyThenTransfer,
            replyText: "亲亲，这边系统暂时繁忙，我帮您转接人工客服处理～",
            transferReason: .aiServiceUnavailable,
            reason: "Codex 无法生成回复：\(String(error.prefix(500)))"
        )
        _ = await publishGeneratedReply(
            recordID: recordID,
            attempt: attempt,
            generated: GeneratedReply(reply: fallback),
            message: "Codex 失败已转为客套回复和独立转人工任务",
            sessionStage: "Codex 错误转人工",
            clearSupplementCapture: false
        )
    }

    private func release(attempt: UUID, recordID: UUID) async {
        guard live[attempt]?.recordID == recordID else { return }
        live.removeValue(forKey: attempt)
        await refillSlots(); onChange?()
    }

    private func sessionLifecycleStage(_ timing: ReplyGenerationTiming) -> String? {
        switch timing.sessionMode {
        case "new": return "新建客户会话"
        case "resumed":
            return "恢复客户会话 · 增量提交 \(timing.submittedHistoryBytes) bytes · 图片 \(timing.submittedImageCount)"
        case "rehydrated": return "会话过期或历史变化，重载历史"
        case "recovered": return "恢复失败，重建会话"
        default: return nil
        }
    }

    private func isExplicitBackpressure(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("rate limit")
            || normalized.contains("too many requests")
            || normalized.contains("http 429")
            || normalized.contains("resource temporarily unavailable")
            || normalized.contains("cannot allocate memory")
    }

    private func retry(_ id: UUID, state: SchedulerJobState, error: String) async {
        _ = await update(id, message: "Retry deferred: \(error)") { record in
            record.retries += 1; record.lastError = error
            if state == .queued { record.attemptID = nil }
            let staleConversation = error.contains("打开聊天后完整 UID 核对失败")
                || error.contains("Capture UID mismatch")
            if staleConversation && record.retries >= 2 {
                record.state = .failed
                record.nextAttemptAt = now().addingTimeInterval(terminalRearmDelay)
                return
            }
            record.state = state
            let foregroundFailure = [
                "千牛未成功置前", "千牛未能切到前台", "无法置前千牛接待中心窗口",
                "千牛尚未成为前台应用"
            ].contains { error.contains($0) }
            let delay = foregroundFailure ? 1 : min(60, pow(2, Double(record.retries)))
            record.nextAttemptAt = now().addingTimeInterval(delay)
        }
    }

    private func handleStageUIFailure(
        _ id: UUID,
        state: SchedulerJobState,
        stage: String,
        error: Error,
        resetImageCaptureAttempt: Bool = false
    ) async {
        let message = error.localizedDescription
        guard let before = records.first(where: { $0.id == id }) else { return }
        let previousFailures = before.stageAttempt?.stage == stage ? (before.stageAttempt?.failures ?? 0) : 0
        let disposition = TaskFailurePolicy.uiDisposition(previousFailures: previousFailures)
        _ = await update(id, message: disposition == .park
            ? "UI attempt parked after second failure: \(message)"
            : "UI attempt moved behind fresh work: \(message)") { record in
            record.retries += 1
            record.lastError = message
            record.stageAttempt = StageAttempt(
                stage: stage,
                failures: previousFailures + 1,
                operationID: nil,
                startedAt: nil,
                deadlineAt: nil
            )
            if resetImageCaptureAttempt { record.imageCaptureAttempted = false }
            switch disposition {
            case .requeueTail:
                record.state = state
                // Prevent the same broken UI task from reacquiring the only
                // UI turn on the very next 200 ms poll. Fresh ready/capture
                // work can pass it before this single bounded retry.
                record.nextAttemptAt = now().addingTimeInterval(1)
            case .park:
                record.state = .parked
                record.parkedReason = message
                record.deliveryOutcome = record.reply == nil ? nil : .notSent
                // A later genuinely new red dot may create a new attempt for
                // this UID; only this failed attempt leaves the normal queue.
                record.nextAttemptAt = now()
            }
        }
        if !persistenceFailed {
            switch disposition {
            case .requeueTail:
                await reportRuntimeIssue("UI 任务失败一次，已移到新任务后面：\(message)", uid: before.uid)
            case .park:
                await reportRuntimeIssue("UI 任务连续失败两次，本次已移入失败区：\(message)", uid: before.uid)
            }
        }
    }

    private func failSupplementCapture(
        _ id: UUID,
        error: String,
        resetImageCaptureAttempt: Bool = false
    ) async {
        guard let before = records.first(where: { $0.id == id }) else { return }
        let previousFailures = before.stageAttempt?.stage == "supplement-capture"
            ? (before.stageAttempt?.failures ?? 0) : 0
        let disposition = TaskFailurePolicy.uiDisposition(previousFailures: previousFailures)
        _ = await update(id, message: disposition == .park
            ? "Supplement capture abandoned after bounded retry: \(error)"
            : "Supplement capture moved behind fresh work: \(error)") { record in
            record.retries += 1
            record.lastError = error
            if resetImageCaptureAttempt { record.imageCaptureAttempted = false }
            if disposition == .requeueTail {
                record.supplementCapturePending = true
                record.stageAttempt = StageAttempt(stage: "supplement-capture", failures: previousFailures + 1)
            } else {
                // The supplement probe is optional to the already frozen
                // generation/reply. Abandoning it must not park that base job.
                record.supplementCapturePending = nil
                record.supplementCaptureAbandoned = true
                record.stageAttempt = nil
            }
            record.nextAttemptAt = disposition == .requeueTail
                ? now().addingTimeInterval(1)
                : now()
        }
    }

    private func deliver(_ record: SchedulerRecord, token: UUID) async {
        guard record.effectiveTaskKind == .customerReply else { return }
        guard let original = record.snapshot, let reply = record.reply else { return }
        let deadline = stageDeadlines.delivery
        guard isCurrent(token), await reserveStageAttempt(
            record.id,
            stage: "delivery",
            deadline: deadline,
            message: "Sending (durable before UI action)",
            expected: { $0.state == .ready },
            change: {
                $0.state = .sending
                $0.sendWasInvoked = false
            }
        ) else { return }
        guard isCurrent(token) else {
            _ = await update(record.id, message: "Send deferred before UI action") { $0.state = .ready }
            return
        }
        guard await update(
            record.id,
            message: "Send driver invocation durably marked",
            expected: { $0.state == .sending && $0.sendWasInvoked == false },
            { $0.sendWasInvoked = true }
        ), isCurrent(token) else { return }
        let result: DeliveryResult
        let driver = self.driver
        do {
            result = try await withOperationDeadline(deadline, stage: "scheduler-delivery") {
                try await driver.send(uid: record.uid, text: reply.replyText)
            }
        }
        catch { result = .uncertain("Send threw after action began: \(error.localizedDescription)") }
        switch result {
        case .sent:
            await completeDelivery(record, original: original, outcome: .sent, message: "Sent")
        case .failedBeforeSend(let reason):
            if reply.action == .replyThenTransfer {
                await completeDelivery(
                    record,
                    original: original,
                    outcome: .notSent,
                    message: "转人工客套回复发送前失败；不重试文字，继续独立转人工任务：\(reason)"
                )
            } else {
                await deferSafeSendFailure(record.id, reason: reason)
            }
        case .uncertain(let reason):
            await completeDelivery(
                record,
                original: original,
                outcome: .uncertain,
                message: "已点击发送但结果无法确认；不自动重发并继续后续任务：\(reason)"
            )
        }
    }

    private func transfer(_ record: SchedulerRecord, token: UUID) async {
        guard record.effectiveTaskKind == .transfer,
              let original = record.snapshot,
              let reply = record.reply,
              reply.action == .replyThenTransfer else { return }
        let deadline = stageDeadlines.delivery
        guard isCurrent(token), await reserveStageAttempt(
            record.id,
            stage: "transfer",
            deadline: deadline,
            message: "Transfer task started",
            expected: { $0.state == .ready },
            change: { $0.state = .sending }
        ) else { return }
        do {
            let driver = self.driver
            try await withOperationDeadline(deadline, stage: "scheduler-transfer") {
                try await driver.recordTransferPlaceholder(
                    uid: record.uid,
                    customerRevision: original.customerRevision,
                    reply: reply
                )
            }
            _ = await finish(record.id, message: "Transfer task completed")
        } catch {
            await handleStageUIFailure(
                record.id,
                state: .ready,
                stage: "transfer",
                error: error
            )
        }
    }

    private func deferSafeSendFailure(_ id: UUID, reason: String) async {
        guard let before = records.first(where: { $0.id == id }) else { return }
        let failures = (before.safeSendFailureCount ?? 0) + 1
        let delay = min(30.0, pow(2.0, Double(min(failures, 5))))
        _ = await update(id, message: "Safe send retained and moved behind fresh work") {
            $0.safeSendFailureCount = failures
            $0.retries += 1
            $0.lastError = reason
            $0.state = .ready
            $0.deliveryOutcome = nil
            $0.sendRetryDeferred = true
            $0.sendRetryNeedsDiscovery = true
            $0.nextAttemptAt = now().addingTimeInterval(delay)
        }
        if !persistenceFailed {
            await reportRuntimeIssue("发送前失败；回复已保留并移到队尾，\(Int(delay)) 秒后可重试：\(reason)", uid: before.uid)
        }
    }

    private func completeDelivery(
        _ record: SchedulerRecord,
        original: CaptureSnapshot,
        outcome: SchedulerDeliveryOutcome,
        message: String
    ) async {
        let pendingSupplement = records.first(where: { $0.id == record.id })?.pendingSupplement
        let hasUnreadQualifiedSupplement = pendingSupplement.map {
            $0.customerRevision != original.customerRevision
                && !isVideoMarkerCoveredByAnalysis($0.customerRevision, uid: record.uid)
        } ?? false
        let committed: Bool
        if original.endCursor != nil || hasUnreadQualifiedSupplement {
            committed = await commit(
                hasUnreadQualifiedSupplement
                    ? "\(message); scheduled red-dot-qualified supplement capture"
                    : "\(message); waiting for fresh unread discovery",
                uid: record.uid
            ) { state in
                guard let index = state.records.firstIndex(where: { $0.id == record.id }) else { return }
                state.records[index].state = .completed
                state.records[index].nextAttemptAt = now().addingTimeInterval(terminalRearmDelay)
                state.records[index].deliveryOutcome = outcome
                state.records[index].pendingSupplement = nil
                state.records[index].supplementCapturePending = nil
                if let end = original.endCursor {
                    state.answeredCursors[record.uid] = end
                }
                if hasUnreadQualifiedSupplement {
                    state.records.append(SchedulerRecord(
                        uid: record.uid,
                        sequence: state.nextSequence,
                        state: .discovered,
                        createdAt: now(),
                        updatedAt: now(),
                        nextAttemptAt: now(),
                        imageCaptureAttempted: record.imageCaptureAttempted
                    ))
                    state.nextSequence += 1
                }
            }
        } else {
            committed = await finish(record.id, message: message, deliveryOutcome: outcome)
        }
        if committed {
            await onTerminalDelivery(record.uid, original.customerRevision, outcome)
        }
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
