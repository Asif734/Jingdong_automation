import XCTest
import AutoReplyCore
import QianniuOCRAppSupport
import CustomerReplyBatchAppSupport
import CryptoKit
@testable import AutoReplyApp

private struct UnusedGenerator: ReplyGenerating {
    func generate(for input: PromptInput) async throws -> GeneratedReply { throw CancellationError() }
}
private enum FakePrewarmError: Error { case unavailable }
private actor ScriptedPrewarmer: KnowledgePrewarming {
    private var failuresRemaining: Int
    private(set) var prepareCalls = 0
    private(set) var shutdownCalls = 0
    private let version: String

    init(failuresBeforeSuccess: Int = 0, version: String = "v2-top12") {
        failuresRemaining = failuresBeforeSuccess
        self.version = version
    }
    func prepare(knowledgeBasePaths: [String]) async throws -> KnowledgePreparation {
        prepareCalls += 1
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw FakePrewarmError.unavailable
        }
        return KnowledgePreparation(version: version)
    }
    func shutdown() async { shutdownCalls += 1 }
    func prepareCallCount() -> Int { prepareCalls }
}
private actor DelayRecorder {
    private(set) var values: [TimeInterval] = []
    func record(_ value: TimeInterval) { values.append(value) }
    func snapshot() -> [TimeInterval] { values }
}
private actor AsyncCallCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}
@MainActor private final class IdleUI: NativeUIAutomation {
    let leaseRegistry = UIOperationLeaseRegistry()
    func checkSafety() throws {}
    func discover(eligibleUIDs: Set<String>?, lease: UIOperationLease) async throws -> [String] { [] }
    func open(uid: String, lease: UIOperationLease) async throws {}
    func header(lease: UIOperationLease) async throws -> String? { nil }
    func observeUnread(uid: String, lease: UIOperationLease) async throws -> (hasUnread: Bool, latestPreviewIsImage: Bool) { (false, false) }
    func recognize(includeImages: Bool, lease: UIOperationLease, stage: @escaping (OCRStage) -> Void) async throws -> OCRRunResult { OCRRunResult(lines: []) }
    func activateForValidation(lease: UIOperationLease) async throws {}
    func send(uid: String, text: String, lease: UIOperationLease) async throws -> DeliveryResult { .sent }
    func openTransferMenu(uid: String, lease: UIOperationLease) async throws {}
}

@MainActor final class AutomationAppModelTests: XCTestCase {
    func testOutputSchemaUpgradeAtomicallyReplacesPreviousContract() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("new-schema.json")
        let destination = root.appendingPathComponent("runtime/automatic-output.schema.json")
        try Data("new-two-action-schema".utf8).write(to: source)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("old-schema".utf8).write(to: destination)

        try AutomationAppModel.synchronizeOutputSchema(
            sourceURL: source, destinationURL: destination
        )

        XCTAssertEqual(
            try Data(contentsOf: destination), Data("new-two-action-schema".utf8)
        )
    }
    func testVideoRecoveryStartsExactlyOnceAndReportsRetryStatus() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("video-recovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let counter = AsyncCallCounter()
        let model = try AutomationAppModel(
            root: root,
            ui: IdleUI(),
            generator: UnusedGenerator(),
            autoResume: false,
            videoRecoveryStart: { await counter.increment() }
        )

        await model.waitForVideoRecoveryStartForTesting()
        model.consumeVideoTransferStatus(VideoTransferPublicStatus(
            customerUID: "buyer", messageHash: "safe-hash",
            phase: .waitingForRetry, attempt: 1
        ))

        let recoveryStarts = await counter.count
        XCTAssertEqual(recoveryStarts, 1)
        XCTAssertEqual(model.videoStatus, "CDN线路不可达，正在换线路")
    }

    func testVideoDownloadStatusUsesThreeUserVisibleStages() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("video-status-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try AutomationAppModel(
            root: root,
            ui: IdleUI(),
            generator: UnusedGenerator(),
            autoResume: false
        )

        model.consumeVideoTransferStatus(VideoTransferPublicStatus(
            customerUID: "buyer", messageHash: "video", phase: .addressCaptured, attempt: 1
        ))
        XCTAssertEqual(model.videoStatus, "发起下载成功")

        model.consumeVideoTransferStatus(VideoTransferPublicStatus(
            customerUID: "buyer", messageHash: "video", phase: .downloading, attempt: 1
        ))
        XCTAssertEqual(model.videoStatus, "正在下载中")

        model.consumeVideoTransferStatus(VideoTransferPublicStatus(
            customerUID: "buyer", messageHash: "video", phase: .downloaded, attempt: 1
        ))
        XCTAssertEqual(model.videoStatus, "下载完成")
    }
    func testReadyCoordinatorStartsSchedulerExactlyOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ready-autostart-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let firstRun = FirstRunCoordinator(
            checks: ReadyFirstRunChecks(),
            calibration: ReadyCalibration(),
            prewarmer: ReadyPrewarmer()
        )
        await firstRun.advance(
            operatorConfig: OperatorConfig(serviceAliases: ["小甘"], autoStartWhenReady: true)
        )
        let model = try AutomationAppModel(
            root: root,
            ui: IdleUI(),
            generator: UnusedGenerator(),
            autoResume: false,
            firstRun: firstRun
        )
        model.setServiceAliasesText("小甘")
        model.applyServiceAliases()

        await model.consumeReadinessChange()
        await model.consumeReadinessChange()

        XCTAssertTrue(model.scheduler.isRunning)
        XCTAssertEqual(model.automaticStartInvocationCountForTesting, 1)
        model.stop()
    }

    func testSendFallbackCoordinatorStartsSchedulerExactlyOnce() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ready-send-fallback-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = try AdaptiveCalibrationEngine.calibrate(
            snapshot: .colleagueB40Controls(exactSendLabel: false)
        )
        let firstRun = FirstRunCoordinator(
            checks: ReadyFirstRunChecks(),
            calibration: ReadyCalibration(profile: profile),
            prewarmer: ReadyPrewarmer()
        )
        await firstRun.advance(
            operatorConfig: OperatorConfig(serviceAliases: ["小甘"], autoStartWhenReady: true)
        )
        let model = try AutomationAppModel(
            root: root,
            ui: IdleUI(),
            generator: UnusedGenerator(),
            autoResume: false,
            firstRun: firstRun
        )
        model.setServiceAliasesText("小甘")
        model.applyServiceAliases()

        await model.consumeReadinessChange()
        await model.consumeReadinessChange()

        XCTAssertTrue(model.scheduler.isRunning)
        XCTAssertEqual(model.automaticStartInvocationCountForTesting, 1)
        model.stop()
    }

    func testKnowledgePrewarmRetriesInBackgroundThenReportsReady() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("prewarm-model-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let prewarmer = ScriptedPrewarmer(failuresBeforeSuccess: 1)
        let delays = DelayRecorder()
        let model = try AutomationAppModel(
            root: root, ui: IdleUI(), generator: UnusedGenerator(),
            knowledgeBasePaths: ["/fixture/kb.zip"], autoResume: false,
            retrySleep: { delay in await delays.record(delay) },
            knowledgePrewarmer: prewarmer
        )

        await model.waitForKnowledgePreparationForTesting()

        XCTAssertEqual(model.knowledgeRetrievalStatusText, "知识库：已就绪（Top-12）")
        let prepareCalls = await prewarmer.prepareCallCount()
        let recordedDelays = await delays.snapshot()
        XCTAssertEqual(prepareCalls, 2)
        XCTAssertEqual(recordedDelays, [1])
    }

    func testKnowledgePrewarmShowsLexicalDegradedMode() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("prewarm-lexical-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let prewarmer = ScriptedPrewarmer(version: "v2-lexical-only")
        let model = try AutomationAppModel(
            root: root, ui: IdleUI(), generator: UnusedGenerator(),
            knowledgeBasePaths: ["/fixture/kb.zip"], autoResume: false,
            knowledgePrewarmer: prewarmer
        )

        await model.waitForKnowledgePreparationForTesting()

        XCTAssertEqual(model.knowledgeRetrievalStatusText, "知识库：关键词降级模式（仍可回复）")
    }

    func testStoragePreflightRequiresWritableDirectoryAndAtLeast512MiB() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("storage-preflight-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(try StorageStartPreflight.check(root: root, availableBytes: { _ in (512 << 20) - 1 }))
        XCTAssertNoThrow(try StorageStartPreflight.check(root: root, availableBytes: { _ in 512 << 20 }))
    }

    func testStoragePreflightFailureStopsBeforeSchedulerStarts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("storage-start-stop-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try AutomationAppModel(
            root: root, ui: IdleUI(), generator: UnusedGenerator(), autoResume: false,
            storagePreflight: { throw AutomationDriverError.unsafeUI("可用空间不足 512 MiB") }
        )
        model.setServiceAliasesText("小丹")

        model.start()

        XCTAssertFalse(model.scheduler.isRunning)
        XCTAssertTrue(model.message.contains("512 MiB"))
        model.stopRetryLoopForTesting()
    }

    func testRecordStorageUsesApplicationSupportInsteadOfDesktop() {
        let home = URL(fileURLWithPath: "/tmp/example-home", isDirectory: true)

        let location = RecordStorageLocation(homeDirectory: home)

        XCTAssertEqual(
            location.runtimeRoot.path,
            "/tmp/example-home/Library/Application Support/QianniuAutoReplyTaskIsolationCandidate/AI客服记录-任务隔离候选版"
        )
        XCTAssertEqual(
            location.desktopEntry.path,
            "/tmp/example-home/Desktop/AI客服记录-任务隔离候选版"
        )
    }

    func testRecordStorageMigrationPreservesLegacyFilesAndCreatesDesktopEntry() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("record-storage-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let location = RecordStorageLocation(homeDirectory: home)
        try FileManager.default.createDirectory(at: location.desktopEntry, withIntermediateDirectories: true)
        let legacy = location.desktopEntry.appendingPathComponent("用户/u1/history.jsonl")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: legacy)

        try location.migrateLegacyDesktopRecords()

        let migrated = location.runtimeRoot.appendingPathComponent("用户/u1/history.jsonl")
        XCTAssertEqual(try String(contentsOf: migrated, encoding: .utf8), "legacy")
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: location.desktopEntry.path),
            location.runtimeRoot.path
        )
        XCTAssertEqual(location.desktopEntry.resolvingSymlinksInPath(), location.runtimeRoot.resolvingSymlinksInPath())

        try location.migrateLegacyDesktopRecords()
        XCTAssertEqual(try String(contentsOf: migrated, encoding: .utf8), "legacy")
    }

    func testUniversalFirstInstallOverridesLegacyStoppedPreferenceButKeepsAliases() throws {
        let root = temporaryModelRoot("universal-first-install")
        let store = AtomicJSONStore<OperatorConfig>(
            root: root.appendingPathComponent("运行状态/自动配置"),
            stem: "operator"
        )
        try store.saveCandidate(
            OperatorConfig(serviceAliases: ["小甘"], autoStartWhenReady: false),
            validate: { _ in true }
        )

        let model = try AutomationAppModel(
            root: root,
            ui: IdleUI(),
            generator: UnusedGenerator(),
            autoResume: false
        )

        XCTAssertEqual(model.serviceAliases, ["小甘"])
        XCTAssertTrue(model.autoStartWhenReady)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(
                "运行状态/自动配置/universal-install-v1.json"
            ).path
        ))
    }

    func testUniversalMigrationDoesNotTouchHistoryOrImageFingerprints() throws {
        let root = temporaryModelRoot("universal-preserves-history")
        let historyURL = root.appendingPathComponent("用户/u1/history.jsonl")
        let fingerprintURL = root.appendingPathComponent("运行状态/图片指纹/u1.json")
        try FileManager.default.createDirectory(
            at: historyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: fingerprintURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("keep-history".utf8).write(to: historyURL)
        try Data("keep-image-fingerprint".utf8).write(to: fingerprintURL)

        _ = try AutomationAppModel(
            root: root,
            ui: IdleUI(),
            generator: UnusedGenerator(),
            autoResume: false
        )

        XCTAssertEqual(try Data(contentsOf: historyURL), Data("keep-history".utf8))
        XCTAssertEqual(
            try Data(contentsOf: fingerprintURL),
            Data("keep-image-fingerprint".utf8)
        )
    }

    func testUserDisablingAutostartAfterMigrationRemainsDisabledOnRelaunch() throws {
        let root = temporaryModelRoot("universal-user-preference")
        var first: AutomationAppModel? = try AutomationAppModel(
            root: root,
            ui: IdleUI(),
            generator: UnusedGenerator(),
            autoResume: false
        )
        first?.setServiceAliasesText("小甘")
        first?.applyServiceAliases()
        first?.setAutoStartWhenReady(false)
        first = nil

        let reopened = try AutomationAppModel(
            root: root,
            ui: IdleUI(),
            generator: UnusedGenerator(),
            autoResume: false
        )

        XCTAssertFalse(reopened.autoStartWhenReady)
    }

    func testDesktopRecordAccessPrimesExistingRootWithoutChangingItsContents() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("desktop-record-access-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let marker = root.appendingPathComponent("existing.txt")
        try Data("keep".utf8).write(to: marker)

        try DesktopRecordAccess.prime(root: root)

        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "keep")
    }

    func testLiveConfigurationNeverFallsBackToFullKnowledgeBase() {
        switch AutomationAppModel.liveKnowledgeRetrievalFailurePolicy {
        case .failClosed:
            break
        case .fallbackToFullInput:
            XCTFail("生产自动回复不得把完整知识库 ZIP 交给 Codex")
        }
    }
    func testStructuralUIDIsDefaultAndCanOnlyBeDisabledByExplicitTestArgument() {
        XCTAssertTrue(AutomationAppModel.preferStructuralUID(arguments: ["app"]))
        XCTAssertFalse(AutomationAppModel.preferStructuralUID(arguments: ["app", "--test-ignore-structural-uid"]))
        XCTAssertTrue(AutomationAppModel.preferStructuralUID(arguments: ["app", "--ignore-something-else"]))
    }
    func testFailedStartPersistsRunningIntentAndRelaunchCanResume() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("model-resume-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AutomationRunIntentStore(url: root.appendingPathComponent("运行状态/运行意图.json"))
        let first = try AutomationAppModel(root: root, ui: IdleUI(), generator: UnusedGenerator(),
                                           autoResume: false, startCheck: {
            throw AutomationDriverError.unsafeUI("千牛尚未准备好")
        })
        first.setServiceAliasesText("小丹")
        first.start()
        XCTAssertFalse(first.scheduler.isRunning)
        XCTAssertEqual(try store.load().desiredState, .running)

        first.stopRetryLoopForTesting()
        XCTAssertEqual(try store.load().desiredState, .running,
                       "取消测试中的重试任务不能伪装成用户点击停止")
        let reopened = try AutomationAppModel(root: root.appendingPathComponent("second"), ui: IdleUI(),
                                              generator: UnusedGenerator(), runIntentStore: store,
                                              autoResume: false)
        await reopened.resumeIfRequested()
        XCTAssertTrue(reopened.scheduler.isRunning)
        XCTAssertEqual(reopened.serviceAliases, ["小丹"])
        reopened.stop()
    }

    func testExplicitStopPersistsStoppedAndPreventsRelaunchResume() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("model-stop-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try AutomationAppModel(root: root, ui: IdleUI(), generator: UnusedGenerator(), autoResume: false)
        model.setServiceAliasesText("小丹")
        model.start()
        model.stop()

        XCTAssertEqual(try AutomationRunIntentStore(url: root.appendingPathComponent("运行状态/运行意图.json")).load().desiredState, .stopped)
        await model.resumeIfRequested()
        XCTAssertFalse(model.scheduler.isRunning)
    }
    func testProcessTerminationPreservesRunningIntentForNextLaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("model-quit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AutomationRunIntentStore(url: root.appendingPathComponent("运行状态/运行意图.json"))
        let model = try AutomationAppModel(root: root, ui: IdleUI(), generator: UnusedGenerator(), autoResume: false)
        model.setServiceAliasesText("小丹")
        model.start()

        model.prepareForTermination()

        XCTAssertFalse(model.scheduler.isRunning)
        XCTAssertEqual(try store.load().desiredState, .running)
    }
    func testDefaultsStoppedAndAllCustomersAndKeepsSingletonWhileStopped() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try AutomationAppModel(root: root, ui: IdleUI(), generator: UnusedGenerator())
        XCTAssertFalse(model.scheduler.isRunning)
        XCTAssertTrue(model.serviceAliases.isEmpty)
        XCTAssertThrowsError(try AutomationAppModel(root: root, ui: IdleUI(), generator: UnusedGenerator()))
        model.start(); XCTAssertFalse(model.scheduler.isRunning)
        XCTAssertTrue(model.message.contains("客服名称"))
        model.setServiceAliasesText("小丹，小秦\n小艳")
        XCTAssertEqual(model.serviceAliases, ["小丹", "小秦", "小艳"])
        XCTAssertEqual(model.driver.serviceAliases, ["小丹", "小秦", "小艳"])
        model.start(); XCTAssertTrue(model.scheduler.isRunning)
        model.stop(); XCTAssertFalse(model.scheduler.isRunning)
        XCTAssertThrowsError(try AutomationAppModel(root: root, ui: IdleUI(), generator: UnusedGenerator()))
    }

    func testServiceAliasesPersistLocallyAcrossRelaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let model = try AutomationAppModel(root: root, ui: IdleUI(), generator: UnusedGenerator())
            model.setServiceAliasesText(" 小丹, 小秦， 小丹 \n小艳 ")
            XCTAssertEqual(model.serviceAliases, ["小丹", "小秦", "小艳"])
        }
        let reopened = try AutomationAppModel(root: root, ui: IdleUI(), generator: UnusedGenerator())
        XCTAssertEqual(reopened.serviceAliases, ["小丹", "小秦", "小艳"])
        XCTAssertEqual(reopened.serviceAliasesText, "小丹，小秦，小艳")
        XCTAssertEqual(reopened.driver.serviceAliases, Set(reopened.serviceAliases))
    }
    func testServiceAliasFieldPreservesDelimiterDuringIncrementalTyping() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try AutomationAppModel(root: root, ui: IdleUI(), generator: UnusedGenerator())
        model.setServiceAliasesText("小丹,")
        XCTAssertEqual(model.serviceAliasesText, "小丹,")
        model.setServiceAliasesText(model.serviceAliasesText + "小秦")
        XCTAssertEqual(model.serviceAliases, ["小丹", "小秦"])
    }
    func testRunningServiceAliasEditChangesDraftWithoutChangingActiveAliases() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try AutomationAppModel(root: root, ui: IdleUI(), generator: UnusedGenerator())
        model.setServiceAliasesText("小丹")
        model.start()

        model.setServiceAliasesText("小秦，小艳")

        XCTAssertEqual(model.serviceAliasesText, "小秦，小艳")
        XCTAssertEqual(model.serviceAliases, ["小丹"])
        XCTAssertEqual(model.driver.serviceAliases, ["小丹"])
        model.stop()
    }
    func testApplyingServiceAliasDraftWhileRunningUpdatesNextCaptureConfiguration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try AutomationAppModel(root: root, ui: IdleUI(), generator: UnusedGenerator())
        model.setServiceAliasesText("小丹")
        model.start()
        model.setServiceAliasesText("小秦，小艳")

        model.applyServiceAliases()

        XCTAssertTrue(model.scheduler.isRunning)
        XCTAssertEqual(model.serviceAliases, ["小秦", "小艳"])
        XCTAssertEqual(model.driver.serviceAliases, ["小秦", "小艳"])
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("运行状态/客服名称.txt"), encoding: .utf8), "小秦，小艳")
        model.stop()
    }
    func testFailedOrphanCheckKeepsRestoredJobsStoppedAndShowsReason() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try AutomationAppModel(root: root, ui: IdleUI(), generator: UnusedGenerator(), startCheck: {
            throw AutomationDriverError.unsafeUI("orphan remains")
        })
        model.setServiceAliasesText("小丹")
        model.start()
        XCTAssertFalse(model.scheduler.isRunning)
        XCTAssertTrue(model.message.contains("orphan remains"))
    }
    func testCompletedRevisionClearsReappearingPointerWithoutLosingNewerPointer() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let user = root.appendingPathComponent("用户/tb263147182")
        let pending = root.appendingPathComponent("待处理/tb263147182.json")
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pending.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = "{\"request_id\":\"c1\",\"sender\":\"customer\",\"t\":\"text\",\"v\":\"问\",\"timestamp\":\"2026-8-26 11:00:00\"}\n"
        try Data(text.utf8).write(to: user.appendingPathComponent("history.jsonl"))
        let frozen = try CapturedHistory(root: root).snapshot(uid: "tb263147182", latestSpeaker: "customer", newlyQueued: true)
        let store = try SchedulerStore(rootURL: root.appendingPathComponent("运行状态/调度器"))
        try store.save(SchedulerPersistentState(nextSequence: 1, records: [SchedulerRecord(uid: "tb263147182", sequence: 0, state: .completed, snapshot: frozen)]))
        let model = try AutomationAppModel(root: root, ui: IdleUI(), generator: UnusedGenerator())
        func writePointer(_ history: String) throws {
            try Data(history.utf8).write(to: user.appendingPathComponent("history.jsonl"))
            let hash = SHA256.hash(data: Data(history.utf8)).map { String(format: "%02x", $0) }.joined()
            try JSONSerialization.data(withJSONObject: ["uid": "tb263147182", "user_directory": user.path, "history_version": hash]).write(to: pending)
        }
        try writePointer(text); model.refresh()
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
        try writePointer(text); model.refresh()
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
        try writePointer(text + text.replacingOccurrences(of: "c1", with: "c2")); model.refresh()
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path))
    }
    func testBrokenStalePointerDoesNotPreventAnotherCustomersCleanup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pointer-isolation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let goodUID = "zz-good"
        let user = root.appendingPathComponent("用户/\(goodUID)")
        let pending = root.appendingPathComponent("待处理/\(goodUID).json")
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pending.deletingLastPathComponent(), withIntermediateDirectories: true)
        let historyText = "{\"request_id\":\"c1\",\"sender\":\"customer\",\"t\":\"text\",\"v\":\"问\",\"timestamp\":\"2026-8-26 11:00:00\"}\n"
        try Data(historyText.utf8).write(to: user.appendingPathComponent("history.jsonl"))
        let frozen = try CapturedHistory(root: root).snapshot(uid: goodUID, latestSpeaker: "customer", newlyQueued: true)
        let digest = SHA256.hash(data: Data(historyText.utf8)).map { String(format: "%02x", $0) }.joined()
        try JSONSerialization.data(withJSONObject: [
            "uid": goodUID, "user_directory": user.path, "history_version": digest
        ]).write(to: pending)
        let badUID = "00..."
        try Data("broken".utf8).write(to: root.appendingPathComponent("待处理/\(badUID).json"))
        let store = try SchedulerStore(rootURL: root.appendingPathComponent("运行状态/调度器"))
        try store.save(SchedulerPersistentState(nextSequence: 2, records: [
            SchedulerRecord(
                uid: badUID, sequence: 0, state: .completed,
                snapshot: CaptureSnapshot(uid: badUID, customerRevision: "bad-revision", historyJSONL: "",
                                          hasUnansweredCustomer: true, shouldGenerate: true)
            ),
            SchedulerRecord(uid: goodUID, sequence: 1, state: .completed, snapshot: frozen)
        ]))

        let model = try AutomationAppModel(root: root, ui: IdleUI(), generator: UnusedGenerator(), autoResume: false)
        model.refresh()

        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("待处理/\(badUID).json").path))
        XCTAssertTrue(model.nativeEvents.contains { $0.message.contains("不影响其他客户") })
    }
    func testStageJournalFailureRemainsVisibleWithoutStoppingScheduler() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try AutomationAppModel(root: root, ui: IdleUI(), generator: UnusedGenerator())
        let journal = root.appendingPathComponent("运行状态/native-stages.jsonl")
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
        model.setServiceAliasesText("小丹")
        model.start()
        model.driver.onStage?("tb263147182", "测试阶段")
        XCTAssertTrue(model.scheduler.isRunning)
        XCTAssertTrue(model.message.contains("阶段日志写入失败"))
    }

    func testFatalPersistencePauseCannotLeaveDisplayedStateClaimingRunning() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try AutomationAppModel(root: root, ui: IdleUI(), generator: UnusedGenerator())
        model.setServiceAliasesText("小丹")
        model.start()
        let checkpoint = root.appendingPathComponent("运行状态/调度器/state.json")
        try FileManager.default.removeItem(at: checkpoint)
        try FileManager.default.createDirectory(at: checkpoint, withIntermediateDirectories: false)
        await model.scheduler.tick()
        XCTAssertFalse(model.scheduler.isRunning)
        XCTAssertFalse(model.message.contains("运行中"))
        XCTAssertTrue(model.message.lowercased().contains("persistence"))
    }

    private func temporaryModelRoot(_ prefix: String) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID())", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}

private struct ReadyFirstRunChecks: FirstRunChecking {
    func permissionState() async -> PermissionState {
        PermissionState(accessibility: true, screenCapture: true)
    }
    func qianniuReceptionReady() async -> Bool { true }
    func codexLoggedIn() async -> Bool { true }
}

private struct ReadyCalibration: CalibrationProviding {
    let profile: MachineCompatibilityProfile

    init(profile: MachineCompatibilityProfile = .empty) {
        self.profile = profile
    }

    func calibrate() async throws -> MachineCompatibilityProfile { profile }
}

private struct ReadyPrewarmer: ReadinessPrewarming {
    func prepare() async throws -> [String: CapabilityStatus] { [:] }
}
