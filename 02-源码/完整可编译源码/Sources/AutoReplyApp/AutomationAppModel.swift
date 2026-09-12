import Foundation
import Combine
import AutoReplyCore
import CustomerReplyBatchAppSupport
import QianniuOCRAppSupport

enum StorageStartPreflight {
    static let minimumAvailableBytes: Int64 = 512 << 20

    static func check(
        root: URL,
        availableBytes: (URL) throws -> Int64 = { url in
            let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            guard let available = values.volumeAvailableCapacityForImportantUsage else {
                throw AutomationDriverError.unsafeUI("无法读取客服记录磁盘剩余空间")
            }
            return available
        }
    ) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let probe = root.appendingPathComponent(".scheduler-write-probe-\(UUID().uuidString)")
        do {
            try Data("ok".utf8).write(to: probe, options: .atomic)
            let handle = try FileHandle(forWritingTo: probe)
            try handle.synchronize()
            try handle.close()
        } catch {
            throw AutomationDriverError.unsafeUI("调度器目录不可写：\(error.localizedDescription)")
        }
        try? FileManager.default.removeItem(at: probe)
        let available = try availableBytes(root)
        guard available >= minimumAvailableBytes else {
            throw AutomationDriverError.unsafeUI("客服记录磁盘可用空间不足 512 MiB")
        }
    }
}

@MainActor final class AutomationAppModel: ObservableObject {
    @Published private(set) var serviceAliasesText = ""
    @Published var message = "已停止：默认处理全部可见客户"
    @Published private(set) var nativeEvents: [SchedulerEvent] = []
    @Published private(set) var stages: [String: String] = [:]
    @Published private(set) var accessibility = false
    @Published private(set) var screenCapture = false
    @Published private(set) var knowledgeRetrievalStatusText = "知识库：未配置"
    @Published private(set) var autoStartWhenReady = true
    @Published private(set) var diagnosticExportStatusText = ""
    @Published private(set) var videoStatus = "视频下载待机"
    let videoDetectionNotice: VideoDetectionNoticeController
    let scheduler: AutoReplyScheduler
    let driver: NativeAutomationDriver
    let firstRun: FirstRunCoordinator?
    let firstRunViewModel: FirstRunViewModel?
    private let sessionLock: SessionLock
    private let startCheck: () throws -> Void
    private let storagePreflight: () throws -> Void
    private let history: CapturedHistory
    private let stageURL: URL
    private let pendingDirectory: URL
    private let serviceAliasesURL: URL
    private let runIntentStore: AutomationRunIntentStore
    private let operatorConfigStore: AtomicJSONStore<OperatorConfig>
    private let compatibilityProfileStore: AtomicJSONStore<MachineCompatibilityProfile>
    private let retrySleep: @Sendable (TimeInterval) async -> Void
    private let knowledgePrewarmer: (any KnowledgePrewarming)?
    private let knowledgeBasePaths: [String]
    private let diagnosticSnapshotProvider: (@Sendable () async throws -> CalibrationSnapshot)?
    private var retryTask: Task<Void, Never>?
    private var knowledgePreparationTask: Task<Void, Never>?
    private var readinessTask: Task<Void, Never>?
    private var videoRecoveryTask: Task<Void, Never>?
    private var knowledgeShutdownPending = false
    private var activeServiceAliases: [String] = []
    private var refreshing = false
    private var automaticStartConsumed = false
    private var readinessProfilePersisted = false
    private(set) var automaticStartInvocationCountForTesting = 0
    private var lastStageTime: [String: Date] = [:]
    private var lastStage: [String: String] = [:]
    var quitRequested = false
    init(root: URL, ui: any NativeUIAutomation, generator: any ReplyGenerating,
         knowledgeBasePaths: [String] = [],
         runIntentStore: AutomationRunIntentStore? = nil,
         autoResume: Bool = true,
         retrySleep: @escaping @Sendable (TimeInterval) async -> Void = { delay in
             try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
         },
         knowledgePrewarmer: (any KnowledgePrewarming)? = nil,
         firstRun: FirstRunCoordinator? = nil,
         firstRunViewModel: FirstRunViewModel? = nil,
         onConfirmedDelivery: @escaping @Sendable (Date) async -> Void = { _ in },
         onTerminalDelivery: @escaping @MainActor @Sendable (
             String, String, SchedulerDeliveryOutcome
         ) async -> Void = { _, _, _ in },
         videoRecoveryStart: @escaping @Sendable () async -> Void = {},
         videoDetectionNotice: VideoDetectionNoticeController? = nil,
         diagnosticSnapshotProvider: (@Sendable () async throws -> CalibrationSnapshot)? = nil,
         storagePreflight: @escaping () throws -> Void = {},
         startCheck: @escaping () throws -> Void = {}) throws {
        sessionLock = try SessionLock(url: root.appendingPathComponent("运行状态/session.lock"))
        self.startCheck = startCheck
        self.storagePreflight = storagePreflight
        self.runIntentStore = runIntentStore ?? AutomationRunIntentStore(
            url: root.appendingPathComponent("运行状态/运行意图.json")
        )
        self.retrySleep = retrySleep
        self.knowledgePrewarmer = knowledgePrewarmer
        self.knowledgeBasePaths = knowledgeBasePaths
        self.firstRun = firstRun
        self.firstRunViewModel = firstRunViewModel
        self.videoDetectionNotice = videoDetectionNotice ?? VideoDetectionNoticeController()
        self.diagnosticSnapshotProvider = diagnosticSnapshotProvider
        operatorConfigStore = AtomicJSONStore(
            root: root.appendingPathComponent("运行状态/自动配置", isDirectory: true),
            stem: "operator"
        )
        compatibilityProfileStore = AtomicJSONStore(
            root: root.appendingPathComponent("运行状态/自动配置", isDirectory: true),
            stem: "machine-compatibility"
        )
        let migratedOperator = try UniversalInstallMigration.applyIfNeeded(
            root: root,
            operatorStore: operatorConfigStore
        )
        if let storedOperator = migratedOperator ?? (try? operatorConfigStore.load()) {
            autoStartWhenReady = storedOperator.autoStartWhenReady
        }
        let restoredIntent = try self.runIntentStore.load()
        let capturedHistory = CapturedHistory(root: root, knowledgeBasePaths: knowledgeBasePaths)
        history = capturedHistory
        stageURL = root.appendingPathComponent("运行状态/native-stages.jsonl")
        pendingDirectory = root.appendingPathComponent("待处理")
        serviceAliasesURL = root.appendingPathComponent("运行状态/客服名称.txt")
        driver = NativeAutomationDriver(
            ui: ui,
            root: root,
            knowledgeBasePaths: knowledgeBasePaths,
            onConfirmedDelivery: onConfirmedDelivery
        )
        let storedAliases = FileManager.default.fileExists(atPath: serviceAliasesURL.path)
            ? ((try? String(contentsOf: serviceAliasesURL, encoding: .utf8)) ?? "") : ""
        let operatorAliases = (try? operatorConfigStore.load())?.serviceAliases ?? []
        let normalizedAliases = !restoredIntent.aliases.isEmpty
            ? restoredIntent.aliases
            : (!operatorAliases.isEmpty ? operatorAliases : Self.normalizedAliases(storedAliases))
        serviceAliasesText = normalizedAliases.joined(separator: "，")
        activeServiceAliases = normalizedAliases
        driver.serviceAliases = Set(normalizedAliases)
        scheduler = try AutoReplyScheduler(driver: driver, generator: generator,
            store: SchedulerStore(
                rootURL: root.appendingPathComponent("运行状态/调度器"),
                idleCursorResolver: { try capturedHistory.migrationBaselineCursor(uid: $0) },
                legacySnapshotCursorResolver: {
                    try capturedHistory.cursor(uid: $0, historyJSONL: $1)
                },
                legacyPendingResolver: { try capturedHistory.hasPendingCommit(uid: $0) }
            ),
            onTerminalDelivery: onTerminalDelivery)
        scheduler.onChange = { [weak self] in self?.refresh() }
        driver.onStage = { [weak self] uid, stage in self?.recordStage(uid: uid, stage: stage) }
        refresh()
        videoRecoveryTask = Task { await videoRecoveryStart() }
        scheduleKnowledgePreparationIfNeeded()
        scheduleFirstRunIfNeeded()
        if firstRun == nil, autoResume, restoredIntent.desiredState == .running {
            Task { @MainActor [weak self] in await self?.resumeIfRequested() }
        }
    }
    func start() {
        guard !quitRequested, mayQuit else { message = "等待当前 UI 操作和 CLI 清理完成"; return }
        if let firstRun, firstRun.phase != .readOnlyReady, firstRun.phase != .running {
            message = "首次配置尚未完成：\(firstRun.blockingReason ?? "正在自检")"
            return
        }
        do {
            scheduleKnowledgePreparationIfNeeded()
            try validateStartConfiguration()
            try persistIntent(.running)
            try attemptStartOnce()
        } catch {
            message = "\(error.localizedDescription)；将自动重试"
            if (try? runIntentStore.load().desiredState) == .running { scheduleRetryLoop(startingFailureCount: 0) }
        }
        refresh()
    }
    func stop() {
        retryTask?.cancel(); retryTask = nil
        knowledgePreparationTask?.cancel(); knowledgePreparationTask = nil
        scheduler.stop()
        do {
            try persistIntent(.stopped)
            message = "已停止 UI；已运行的 CLI 会完成并保留结果"
        } catch { message = "已停止 UI，但停止状态保存失败：\(error.localizedDescription)" }
        refresh()
    }
    func exportDiagnosticBundle(includeRawEvidence: Bool = false) {
        guard let diagnosticSnapshotProvider else {
            diagnosticExportStatusText = "当前构建未启用诊断导出"
            return
        }
        diagnosticExportStatusText = "正在导出脱敏诊断包…"
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await diagnosticSnapshotProvider()
                let profile = (try compatibilityProfileStore.loadRecoveringLastKnownGood())
                    ?? firstRun?.profile
                    ?? .empty
                let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
                let root = desktop.appendingPathComponent(
                    "千牛诊断导出-\(Int(Date().timeIntervalSince1970))",
                    isDirectory: true
                )
                let output = try DiagnosticBundleExporter(
                    snapshot: snapshot,
                    profile: profile,
                    errors: [],
                    rawEvidenceURLs: [],
                    readiness: firstRun?.readinessStateExport()
                ).export(to: root, includeRawEvidence: includeRawEvidence)
                diagnosticExportStatusText = "已导出：\(output.path)"
            } catch {
                diagnosticExportStatusText = "诊断导出失败：\(error.localizedDescription)"
            }
        }
    }

    /// Stops only this process. The persisted desired state is intentionally
    /// unchanged so a service that was running resumes when the app is opened.
    func prepareForTermination() {
        retryTask?.cancel(); retryTask = nil
        knowledgePreparationTask?.cancel(); knowledgePreparationTask = nil
        readinessTask?.cancel(); readinessTask = nil
        scheduler.stop()
        if let knowledgePrewarmer {
            knowledgeShutdownPending = true
            Task { @MainActor [weak self] in
                await knowledgePrewarmer.shutdown()
                self?.knowledgeShutdownPending = false
                self?.refresh()
            }
        }
        message = "正在安全退出；下次打开将恢复当前运行意图"
        refresh()
    }

    func resumeIfRequested() async {
        guard !quitRequested, !scheduler.isRunning,
              let intent = try? runIntentStore.load(), intent.desiredState == .running else { return }
        if !intent.aliases.isEmpty {
            activeServiceAliases = intent.aliases
            serviceAliasesText = intent.aliases.joined(separator: "，")
            driver.serviceAliases = Set(intent.aliases)
        }
        do { try attemptStartOnce() }
        catch {
            message = "恢复运行等待环境：\(error.localizedDescription)"
            scheduleRetryLoop(startingFailureCount: 0)
        }
        refresh()
    }

    func stopRetryLoopForTesting() { retryTask?.cancel(); retryTask = nil }

    func waitForKnowledgePreparationForTesting() async {
        await knowledgePreparationTask?.value
    }

    func waitForVideoRecoveryStartForTesting() async {
        await videoRecoveryTask?.value
    }

    func consumeVideoTransferStatus(_ status: VideoTransferPublicStatus) {
        switch status.phase {
        case .waitingForRetry:
            videoStatus = "CDN线路不可达，正在换线路"
        case .addressCaptured:
            videoStatus = "发起下载成功"
        case .downloading:
            videoStatus = "正在下载中"
        case .validating:
            videoStatus = "视频已下载，正在校验"
        case .downloaded:
            videoStatus = "下载完成"
        case .preparingEvidence, .readyForAI, .admittedToAI:
            videoStatus = "视频已下载，正在准备回答"
        case .completed:
            videoStatus = "视频处理完成"
        case .terminalFailure:
            videoStatus = "视频暂时无法下载，已继续处理其他客户"
        case .discovered, .opening:
            videoStatus = "正在打开客户视频"
        }
        recordStage(uid: status.customerUID, stage: videoStatus)
    }

    private func scheduleKnowledgePreparationIfNeeded() {
        guard firstRun == nil, knowledgePreparationTask == nil, let knowledgePrewarmer,
              !knowledgeRetrievalStatusText.contains("已就绪"),
              !knowledgeRetrievalStatusText.contains("降级模式") else { return }
        knowledgeRetrievalStatusText = "知识库：预热中"
        knowledgePreparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var failures = 0
            while !Task.isCancelled {
                do {
                    let result = try await knowledgePrewarmer.prepare(
                        knowledgeBasePaths: self.knowledgeBasePaths
                    )
                    self.knowledgeRetrievalStatusText = result.version == "v2-top12"
                        ? "知识库：已就绪（Top-12）"
                        : "知识库：关键词降级模式（仍可回复）"
                    self.knowledgePreparationTask = nil
                    self.refresh()
                    return
                } catch {
                    failures += 1
                    let delay = Self.knowledgeRetryDelay(afterFailureCount: failures)
                    self.knowledgeRetrievalStatusText = "知识库：恢复中（\(Int(delay)) 秒后重试）· \(error.localizedDescription)"
                    self.refresh()
                    await self.retrySleep(delay)
                }
            }
            self.knowledgePreparationTask = nil
        }
    }

    func consumeReadinessChange() async {
        guard let firstRun, firstRun.phase == .readOnlyReady else { return }
        if !readinessProfilePersisted, let profile = firstRun.profile {
            do {
                try compatibilityProfileStore.saveCandidate(profile) {
                    $0.readOnlyPassedAt != nil && !$0.capabilities.isEmpty
                }
                readinessProfilePersisted = true
            } catch {
                message = "本机兼容配置保存失败：\(error.localizedDescription)"
            }
        }
        guard firstRun.shouldAutoStart,
              !automaticStartConsumed else { return }
        automaticStartConsumed = true
        automaticStartInvocationCountForTesting += 1
        start()
        if scheduler.isRunning { firstRun.markRunning() }
    }

    func setAutoStartWhenReady(_ enabled: Bool) {
        autoStartWhenReady = enabled
        persistOperatorConfigIfPossible()
    }

    private func scheduleFirstRunIfNeeded() {
        guard readinessTask == nil, let firstRun else { return }
        readinessTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let config = self.currentOperatorConfig()
                await firstRun.advance(operatorConfig: config)
                if let v2 = firstRun.capabilities["v2"] {
                    self.knowledgeRetrievalStatusText = v2.level == .fallback
                        ? "知识库：关键词降级模式（仍可回复）"
                        : "知识库：已就绪（Top-12）"
                }
                await self.consumeReadinessChange()
                if firstRun.phase == .readOnlyReady || firstRun.phase == .running {
                    self.readinessTask = nil
                    self.refresh()
                    return
                }
                self.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
            self.readinessTask = nil
        }
    }

    private func currentOperatorConfig() -> OperatorConfig {
        OperatorConfig(
            serviceAliases: Self.normalizedAliases(serviceAliasesText),
            autoStartWhenReady: autoStartWhenReady
        )
    }

    private func persistOperatorConfigIfPossible() {
        let config = currentOperatorConfig()
        try? operatorConfigStore.saveCandidate(config) { candidate in
            !candidate.serviceAliases.isEmpty
        }
    }

    static func knowledgeRetryDelay(afterFailureCount failures: Int) -> TimeInterval {
        [1, 2, 5, 10, 30, 60][min(max(1, failures) - 1, 5)]
    }

    private func validateStartConfiguration() throws {
        guard !serviceAliases.isEmpty else {
            throw AutomationDriverError.unsafeUI("请先填写至少一个客服名称，例如：小丹")
        }
    }

    private func attemptStartOnce() throws {
        try validateStartConfiguration()
        try storagePreflight()
        try startCheck()
        scheduler.start()
        retryTask?.cancel(); retryTask = nil
        message = "运行中 · 全部客户"
    }

    private func persistIntent(_ desiredState: AutomationDesiredState) throws {
        try runIntentStore.save(AutomationRunIntent(
            desiredState: desiredState,
            aliases: activeServiceAliases
        ))
    }

    private func scheduleRetryLoop(startingFailureCount: Int) {
        guard retryTask == nil else { return }
        retryTask = Task { @MainActor [weak self] in
            var failures = startingFailureCount
            while !Task.isCancelled, let self,
                  (try? self.runIntentStore.load().desiredState) == .running,
                  !self.scheduler.isRunning {
                let delay = StartRetryPolicy.delay(afterFailureCount: failures)
                self.message = "等待运行环境，\(Int(delay)) 秒后重试"
                await self.retrySleep(delay)
                guard !Task.isCancelled else { return }
                do { try self.attemptStartOnce(); return }
                catch {
                    failures += 1
                    self.message = "恢复运行等待环境：\(error.localizedDescription)"
                    self.refresh()
                }
            }
            self?.retryTask = nil
        }
    }
    func refresh() {
        guard !refreshing else { return }
        refreshing = true; defer { refreshing = false }
        accessibility = AutomationPermissions.accessibility
        screenCapture = AutomationPermissions.screenCapture
        if !scheduler.isRunning, scheduler.status != "Stopped" {
            message = scheduler.status
        }
        do {
            // A read-status-only export can recreate a pointer after the scheduler
            // coalesces into an existing completed record ID. Inspect current
            // pointer presence, never a once-per-record completion flag.
            if FileManager.default.fileExists(atPath: pendingDirectory.path) {
                let pointers = try FileManager.default.contentsOfDirectory(at: pendingDirectory, includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "json" }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                for pointer in pointers {
                    do {
                        let uid = pointer.deletingPathExtension().lastPathComponent
                        let completedRevisions = Set(scheduler.records.lazy
                            .filter { $0.uid == uid && $0.state == .completed }
                            .compactMap(\.customerRevision))
                        try history.complete(uid: uid, completedRevisions: completedRevisions)
                    } catch {
                        appendOptionalWarning("待处理指针清理失败（不影响其他客户）：\(error.localizedDescription)")
                    }
                }
            }
        } catch {
            message = "运行中；待处理确认失败，将继续重试：\(error.localizedDescription)"
        }
        objectWillChange.send()
    }

    private func appendOptionalWarning(_ text: String) {
        let event = SchedulerEvent(date: Date(), uid: nil, message: "可选诊断警告：\(text)")
        nativeEvents.append(event)
        if nativeEvents.count > 200 { nativeEvents.removeFirst(nativeEvents.count - 200) }
    }
    var mayQuit: Bool {
        !knowledgeShutdownPending && QuitPolicy.mayTerminate(
            uiActive: scheduler.hasActiveUIOperation,
            liveGenerations: scheduler.liveGenerationCount
        )
    }
    var canChangeMode: Bool { !scheduler.isRunning && mayQuit && !quitRequested }
    var serviceAliases: [String] { activeServiceAliases }
    func setServiceAliasesText(_ text: String) {
        guard !quitRequested else { return }
        serviceAliasesText = text
        guard canChangeMode else {
            message = "客服名称已编辑，点击“应用名称”后生效"
            return
        }
        applyServiceAliases()
    }
    func applyServiceAliases() {
        guard !quitRequested else { return }
        let aliases = Self.normalizedAliases(serviceAliasesText)
        guard !aliases.isEmpty else {
            message = "客服名称不能为空；仍使用：\(activeServiceAliases.joined(separator: "、"))"
            return
        }
        do {
            try FileManager.default.createDirectory(at: serviceAliasesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(serviceAliasesText.utf8)
                .write(to: serviceAliasesURL, options: .atomic)
            activeServiceAliases = aliases
            driver.serviceAliases = Set(aliases)
            try operatorConfigStore.saveCandidate(
                OperatorConfig(
                    serviceAliases: aliases,
                    autoStartWhenReady: autoStartWhenReady
                ),
                validate: { !$0.serviceAliases.isEmpty }
            )
            let desired = (try? runIntentStore.load().desiredState) ?? .stopped
            try persistIntent(desired)
            message = "已应用客服名称：\(aliases.joined(separator: "、"))"
        } catch { message = "客服名称保存失败：\(error.localizedDescription)" }
    }
    private static func normalizedAliases(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.components(separatedBy: CharacterSet(charactersIn: ",，\n\r"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
    private func recordStage(uid: String?, stage: String) {
        let key = uid ?? "发现", date = Date()
        // Cheap scheduler idle ticks should not write a journal line every 200ms.
        if uid == nil { objectWillChange.send(); return }
        let elapsed = lastStageTime[key].map { date.timeIntervalSince($0) } ?? 0
        let previous = lastStage[key] ?? "开始"
        let event = SchedulerEvent(date: date, uid: uid, message: "\(stage) · 上阶段 \(previous): \(String(format: "%.2f", elapsed))s")
        lastStageTime[key] = date; lastStage[key] = stage
        stages[key] = stage; nativeEvents.append(event)
        if nativeEvents.count > 200 { nativeEvents.removeFirst(nativeEvents.count - 200) }
        do {
            let data = try JSONEncoder().encode(event) + Data([0x0A])
            if !FileManager.default.fileExists(atPath: stageURL.path) { try Data().write(to: stageURL, options: .atomic) }
            let handle = try FileHandle(forWritingTo: stageURL); defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: data); try handle.synchronize()
        } catch { message = "运行中；阶段日志写入失败：\(error.localizedDescription)" }
        objectWillChange.send()
    }

    static func live() throws -> AutomationAppModel {
        let root = RecordStorageLocation().runtimeRoot
        let schema = root.appendingPathComponent("运行状态/automatic-output.schema.json")
        let portable = try PortableRuntimeResources.live()
        let defaults = CodexReplyGenerator()
        let safety = NativeSafety(schemaPath: schema.path)
        let qianniuLogRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Aliworkbench/System/log", isDirectory: true)
        let mediaRoutingRoot = root.appendingPathComponent("运行状态/媒体路由", isDirectory: true)
        let videoDetectionNotice = VideoDetectionNoticeController()
        let videoTransferStore = DurableVideoTransferStore(
            url: mediaRoutingRoot.appendingPathComponent("video-transfer-state-v2.json")
        )
        let videoTransferCoordinator = VideoTransferCoordinator(
            store: videoTransferStore,
            outputDirectory: root.appendingPathComponent("收到的视频", isDirectory: true)
        )
        let videoAnalysisInbox = VideoAnalysisInbox(
            stateURL: mediaRoutingRoot.appendingPathComponent("video-analysis-inbox.json")
        )
        let senseVoice = SenseVoiceSpeechTranscriber(
            pythonURL: portable.pythonURL,
            workerScriptURL: portable.senseVoiceWorkerScriptURL,
            sitePackagesURL: portable.senseVoiceSitePackagesURL,
            modelURL: portable.senseVoiceModelURL,
            tokensURL: portable.senseVoiceTokensURL
        )
        let videoEvidenceRoot = root.appendingPathComponent("收到的视频帧和音轨", isDirectory: true)
        let videoEvidencePreparer = makeLiveVideoEvidencePreparer(
            rootURL: videoEvidenceRoot,
            fallback: senseVoice
        )
        let ocrRunner = LiveOCRRunner(
            videoAttemptStoreURL: mediaRoutingRoot.appendingPathComponent("video-open-attempts.json"),
            videoLogURLs: [
                qianniuLogRoot.appendingPathComponent("app.log"),
                qianniuLogRoot.appendingPathComponent("app.log.old"),
            ],
            videoTransferStore: videoTransferStore,
            videoTransferCoordinator: videoTransferCoordinator,
            onVideoProgress: { phase in
                videoDetectionNotice.advanceVideoFlow(phase)
            }
        )
        let compatibilityProfileStore = AtomicJSONStore<MachineCompatibilityProfile>(
            root: root.appendingPathComponent("运行状态/自动配置", isDirectory: true),
            stem: "machine-compatibility"
        )
        let storedProfile = (try? compatibilityProfileStore.loadRecoveringLastKnownGood()) ?? nil
        let runtimeAdapter = AdaptiveRuntimeAdapter(profile: storedProfile ?? .empty)
        let mediaTypeResolver = QianniuMediaLogResolver(
            logURLs: [
                qianniuLogRoot.appendingPathComponent("app.log"),
                qianniuLogRoot.appendingPathComponent("app.log.old"),
            ],
            processedStoreURL: mediaRoutingRoot.appendingPathComponent("processed-events.json"),
            videoTransferStore: videoTransferStore,
            onVideoDetected: { messageID in
                await MainActor.run {
                    videoDetectionNotice.advanceVideoFlow(.detected)
                    videoDetectionNotice.show(messageID: messageID)
                }
            }
        )
        let ui = LiveNativeUI(
            root: root,
            safety: safety,
            preferStructuralUID: preferStructuralUID(arguments: ProcessInfo.processInfo.arguments),
            ocrRunner: ocrRunner,
            runtimeAdapter: runtimeAdapter,
            mediaTypeResolver: mediaTypeResolver
        )
        let runtime = root.appendingPathComponent("运行状态", isDirectory: true)
        let codexIsolation = try CodexRuntimeIsolation.prepare(runtimeDirectory: runtime)
        let retriever = V2KnowledgeRetriever(
            pythonURL: portable.pythonURL,
            scriptURL: portable.retrievalScriptURL,
            workerScriptURL: portable.retrievalWorkerScriptURL,
            sitePackagesURL: portable.sitePackagesURL,
            seedCacheURL: portable.seedCacheURL,
            writableCacheURL: portable.writableCacheURL,
            knowledgeBaseSHA256: portable.knowledgeBaseSHA256,
            indexRootURL: portable.indexRootURL,
            indexAlgorithmVersion: portable.indexAlgorithmVersion
        )
        let generator = CodexReplyGenerator(
            executableURL: portable.codexURL,
            schemaURL: schema,
            traceDirectory: runtime.appendingPathComponent("CLI轨迹", isDirectory: true),
            codexHomeURL: codexIsolation.codexHomeURL,
            workingDirectoryURL: codexIsolation.workingDirectoryURL,
            sessionRegistry: CodexSessionRegistry(
                storageURL: runtime.appendingPathComponent("Codex客户会话.json")
            ),
            knowledgeRetriever: retriever,
            retrievalFailurePolicy: liveKnowledgeRetrievalFailurePolicy
        )
        let codexLogin = CodexLoginCoordinator(
            codexURL: portable.codexURL,
            codexHomeURL: codexIsolation.codexHomeURL
        )
        let codexReadiness = LiveCodexReadinessProbe(
            login: codexLogin,
            codexURL: portable.codexURL,
            codexHomeURL: codexIsolation.codexHomeURL,
            workingDirectoryURL: codexIsolation.workingDirectoryURL
        )
        let readinessPrewarmer = ReadinessPrewarmer(
            ocr: ocrRunner,
            knowledge: retriever,
            knowledgeBasePaths: [portable.knowledgeBaseURL.path],
            speech: senseVoice,
            codex: codexReadiness
        )
        let snapshotProvider: @Sendable () async throws -> CalibrationSnapshot = {
            try await MainActor.run { try ui.calibrationSnapshot() }
        }
        let adaptiveEngine = AdaptiveCalibrationEngine(
            snapshotProvider: snapshotProvider,
            ocrAvailable: { true },
            videoCapabilities: { await VideoTransferCapabilityProbe().probe() }
        )
        let profileLifecycle = ProfileLifecycle(
            store: compatibilityProfileStore,
            current: storedProfile ?? .empty,
            calibrate: { try await adaptiveEngine.calibrate() }
        )
        let firstRun = FirstRunCoordinator(
            checks: LiveFirstRunChecks(codex: codexLogin),
            calibration: LifecycleCalibrationProvider(
                snapshotProvider: snapshotProvider,
                lifecycle: profileLifecycle
            ),
            prewarmer: readinessPrewarmer,
            onProfileReady: { profile in
                ui.apply(profile: profile)
                Task { await profileLifecycle.adopt(profile) }
            }
        )
        let firstRunViewModel = FirstRunViewModel(
            settings: LiveSystemSettingsOpener(),
            deviceLogin: { try await codexLogin.startDeviceLogin() }
        )
        let model = try AutomationAppModel(
            root: root,
            ui: ui,
            generator: generator,
            knowledgeBasePaths: [portable.knowledgeBaseURL.path],
            knowledgePrewarmer: retriever,
            firstRun: firstRun,
            firstRunViewModel: firstRunViewModel,
            onConfirmedDelivery: { date in
                try? await profileLifecycle.recordEndToEndDelivery(at: date)
            },
            onTerminalDelivery: { _, revision, outcome in
                guard outcome == .sent || outcome == .uncertain,
                      revision.hasPrefix("video-analysis:") else { return }
                let hash = String(revision.dropFirst("video-analysis:".count))
                guard !hash.isEmpty else { return }
                try? await videoAnalysisInbox.markCompleted(hash)
                try? await videoTransferStore.markAnalysisCompleted(messageHash: hash)
            },
            videoDetectionNotice: videoDetectionNotice,
            diagnosticSnapshotProvider: snapshotProvider,
            storagePreflight: {
                try StorageStartPreflight.check(root: root.appendingPathComponent("运行状态/调度器"))
            },
            startCheck: {
            try safety.check(includeOwnedCLI: true)
            ui.prepareForStart()
        })
        let videoAnalysisCoordinator = VideoAnalysisCoordinator(
            inbox: videoAnalysisInbox,
            preparer: videoEvidencePreparer,
            evidenceRoot: videoEvidenceRoot,
            knowledgeBasePaths: [portable.knowledgeBaseURL.path],
            admit: { snapshot in await model.scheduler.admitExternalSnapshot(snapshot) }
        )
        let videoEventBridge = VideoTransferEventBridge(
            transferStore: videoTransferStore,
            admitPrepared: { _, _, _, _ in .rejected },
            admitDiscovery: { [weak model] uid, revision in
                guard let model else { return false }
                return await model.scheduler.admitExternalDiscovery(
                    uid: uid,
                    sourceRevision: revision
                )
            },
            receiveDownloaded: { receipt in
                await videoAnalysisCoordinator.receive(receipt)
                let entry = try? await videoAnalysisInbox.entries().first {
                    $0.messageHash == receipt.messageHash
                }
                guard entry?.phase == .admitted else {
                    await MainActor.run {
                        videoDetectionNotice.showFrameExtractionFailed(messageID: receipt.messageHash)
                    }
                    return
                }
                let manifestURL = videoEvidenceRoot
                    .appendingPathComponent(receipt.messageHash, isDirectory: true)
                    .appendingPathComponent("manifest.json")
                if let data = try? Data(contentsOf: manifestURL),
                   let manifest = try? JSONDecoder().decode(CustomerVideoEvidenceManifest.self, from: data) {
                    await MainActor.run {
                        videoDetectionNotice.showFrameExtractionCompleted(
                            messageID: receipt.messageHash,
                            frameCount: manifest.frames.count,
                            audioSaved: manifest.audioFileName != nil,
                            transcriptSegmentCount: manifest.transcript.count
                        )
                        videoDetectionNotice.showVideoReplyQueued(messageID: receipt.messageHash)
                    }
                } else {
                    await MainActor.run {
                        videoDetectionNotice.showVideoReplyQueued(messageID: receipt.messageHash)
                    }
                }
            },
            receiveStatus: { [weak model] status in
                model?.consumeVideoTransferStatus(status)
            }
        )
        Task {
            await videoTransferCoordinator.observe { event in
                await videoEventBridge.receive(event)
            }
            try? await videoTransferStore.migrateLegacyJournals(
                downloadURL: mediaRoutingRoot.appendingPathComponent("video-downloads.json"),
                processedURL: mediaRoutingRoot.appendingPathComponent("processed-events.json")
            )
            await videoTransferCoordinator.start()
            await videoAnalysisCoordinator.resumePending()
        }
        // This unique, stable absolute schema path identifies only this app's
        // orphan CLI processes across relaunches. A contract upgrade replaces
        // the bytes atomically while preserving that stable ownership path.
        try synchronizeOutputSchema(sourceURL: defaults.schemaURL, destinationURL: schema)
        return model
    }

    static func makeLiveVideoEvidencePreparer(
        rootURL: URL,
        fallback: any VideoSpeechTranscribing
    ) -> CustomerVideoEvidencePreparer {
        CustomerVideoEvidencePreparer(
            rootURL: rootURL,
            transcriber: AppleThenFallbackVideoSpeechTranscriber(
                primary: AppleVideoSpeechTranscriber(),
                fallback: fallback
            ),
            maximumFrames: 20
        )
    }

    static let liveKnowledgeRetrievalFailurePolicy: KnowledgeRetrievalFailurePolicy = .failClosed

    static func synchronizeOutputSchema(sourceURL: URL, destinationURL: URL) throws {
        let data = try Data(contentsOf: sourceURL)
        if (try? Data(contentsOf: destinationURL)) != data {
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destinationURL, options: .atomic)
        }
    }

    /// Hidden test seam only. Production launches contain no such argument and
    /// therefore keep the strongest structural UID source enabled.
    static func preferStructuralUID(arguments: [String]) -> Bool {
        !arguments.contains("--test-ignore-structural-uid")
    }
}
