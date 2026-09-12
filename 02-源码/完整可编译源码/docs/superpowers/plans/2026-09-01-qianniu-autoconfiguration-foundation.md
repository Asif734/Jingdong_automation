# Qianniu Autoconfiguration Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a truthful first-run state machine, durable machine/operator configuration, isolated Codex login guidance, and coordinated OCR/V2/Codex prewarming without changing the current customer-processing algorithms.

**Architecture:** A new `FirstRunCoordinator` owns readiness and persists state through focused stores. Existing live safety checks remain the phase-one calibration provider, so this plan delivers a working backward-compatible wizard; the adaptive locators arrive in the next plan behind the same interfaces.

**Tech Stack:** Swift 5.9, SwiftUI/AppKit, Codable JSON, Swift Testing/XCTest through SwiftPM, existing `KnowledgePrewarming` and Codex CLI.

**Spec:** `docs/superpowers/specs/2026-09-01-qianniu-universal-autoconfiguration-design.md`

## Global Constraints

- Use colleague B baseline `e1b0ab1bd2b35fa8aa00a9a3696fda00d7a441b3` plus conversation-row fix `68509f83e688f3f632b7b58cc476d6cf34d9bbea`; do not modify frozen Version A.
- Support Apple Silicon and the package's existing macOS 14 minimum.
- One App instance binds one Qianniu reception window; multi-account control is out of scope.
- Never bundle or copy a user's Codex credentials, Skills, rules, plugins, memories, or personal `CODEX_HOME`.
- Accessibility and Screen Recording remain explicit user grants.
- A failed new configuration must never overwrite the last-known-good file.
- Existing customer discovery, OCR, generation, scheduling, and sending behavior must remain unchanged in this plan.

## File Map

- Create `Sources/AutoReplyApp/Autoconfiguration/AutoconfigurationModels.swift`: readiness phases, capability states, operator settings, and profile envelope.
- Create `Sources/AutoReplyApp/Autoconfiguration/AtomicJSONStore.swift`: fsync-backed atomic JSON persistence and backup rotation.
- Create `Sources/AutoReplyApp/Autoconfiguration/FirstRunCoordinator.swift`: first-run state machine and automatic continuation.
- Create `Sources/AutoReplyApp/Autoconfiguration/CodexLoginCoordinator.swift`: dedicated-home login status and device-auth launch.
- Create `Sources/AutoReplyApp/Autoconfiguration/ReadinessPrewarmer.swift`: ordered OCR/V2/Codex readiness orchestration.
- Create `Sources/AutoReplyApp/Autoconfiguration/LegacyCalibrationProvider.swift`: phase-one adapter around the existing safety checks.
- Create `Sources/AutoReplyApp/Autoconfiguration/FirstRunView.swift`: simple user-facing wizard and advanced capability list.
- Modify `Sources/AutoReplyApp/AutomationAppModel.swift`: expose readiness and defer auto-start until the coordinator is ready.
- Modify `Sources/AutoReplyApp/AutoReplyApplication.swift`: show the wizard before the existing status panel.
- Modify `Sources/AutoReplyApp/CodexRuntimeIsolation.swift`: expose stable dedicated-home paths without copying personal configuration.
- Create focused tests under `Tests/AutoReplyAppTests/Autoconfiguration*Tests.swift`.

---

### Task 1: Durable configuration models and atomic stores

**Files:**
- Create: `Sources/AutoReplyApp/Autoconfiguration/AutoconfigurationModels.swift`
- Create: `Sources/AutoReplyApp/Autoconfiguration/AtomicJSONStore.swift`
- Test: `Tests/AutoReplyAppTests/AutoconfigurationStoreTests.swift`

**Interfaces:**
- Produces: `ReadinessPhase`, `CapabilityLevel`, `CapabilityStatus`, `OperatorConfig`, `MachineCompatibilityProfile`, and `AtomicJSONStore<Value>`.
- Produces: `AtomicJSONStore.load()`, `saveCandidate(_:validate:)`, `loadLastKnownGood()`.
- Consumes: Foundation `Codable`, `FileHandle.synchronize()`, and atomic rename on the same volume.

- [ ] **Step 1: Write failing round-trip, rollback, and privacy tests**

```swift
import XCTest
@testable import AutoReplyApp

final class AutoconfigurationStoreTests: XCTestCase {
    func testCandidateBecomesCurrentOnlyAfterValidation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = AtomicJSONStore<OperatorConfig>(root: root, stem: "operator")
        let value = OperatorConfig(serviceAliases: ["小甘"], autoStartWhenReady: true)
        try store.saveCandidate(value) { $0.serviceAliases == ["小甘"] }
        XCTAssertEqual(try store.load(), value)
        XCTAssertEqual(try store.loadLastKnownGood(), value)
    }

    func testRejectedCandidatePreservesLastKnownGood() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = AtomicJSONStore<OperatorConfig>(root: root, stem: "operator")
        let good = OperatorConfig(serviceAliases: ["苏苏"], autoStartWhenReady: true)
        try store.saveCandidate(good) { _ in true }
        XCTAssertThrowsError(try store.saveCandidate(
            OperatorConfig(serviceAliases: [], autoStartWhenReady: true),
            validate: { !$0.serviceAliases.isEmpty }
        ))
        XCTAssertEqual(try store.load(), good)
    }

    func testCompatibilityProfileEncodingContainsNoCustomerFields() throws {
        let data = try JSONEncoder().encode(MachineCompatibilityProfile.empty)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("customerUID"))
        XCTAssertFalse(text.contains("customerNickname"))
        XCTAssertFalse(text.contains("screenshot"))
    }
}
```

- [ ] **Step 2: Run the test and confirm RED**

Run: `swift test --filter AutoconfigurationStoreTests`

Expected: compilation fails because the new model and store types do not exist.

- [ ] **Step 3: Add the exact model surface and minimal store**

```swift
enum ReadinessPhase: String, Codable, CaseIterable, Sendable {
    case installed, permissionsPending, qianniuPending, operatorPending
    case codexPending, probing, calibrating, prewarming, readOnlyReady
    case running, degraded, waitingExternalState, recalibrating
}

enum CapabilityLevel: String, Codable, Sendable { case verified, fallback, unavailable }

struct CapabilityStatus: Codable, Equatable, Sendable {
    let level: CapabilityLevel
    let strategy: String
    let detail: String
}

struct InstallationState: Codable, Equatable, Sendable {
    let installedAppPath: String
    let appVersion: String
    let resourceManifestSHA256: String
}

struct OperatorConfig: Codable, Equatable, Sendable {
    let serviceAliases: [String]
    let autoStartWhenReady: Bool
}

struct MachineCompatibilityProfile: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let profileID: UUID
    let fingerprintDigest: String
    let capabilities: [String: CapabilityStatus]
    let readOnlyPassedAt: Date?
    let endToEndPassedAt: Date?
    static let empty = MachineCompatibilityProfile(
        schemaVersion: 1, profileID: UUID(), fingerprintDigest: "",
        capabilities: [:], readOnlyPassedAt: nil, endToEndPassedAt: nil
    )
}
```

`saveCandidate` must encode to `<stem>.candidate.json`, synchronize the file, decode it again, run `validate`, copy current to `<stem>.last-known-good.json`, then atomically replace `<stem>.json`. On any error it removes only the candidate.

- [ ] **Step 4: Run focused and full app tests**

Run: `swift test --filter AutoconfigurationStoreTests && swift test`

Expected: focused tests pass and the existing app/core suite remains green.

- [ ] **Step 5: Commit the configuration foundation**

```bash
git add Sources/AutoReplyApp/Autoconfiguration Tests/AutoReplyAppTests/AutoconfigurationStoreTests.swift
git commit -m "Add durable autoconfiguration stores"
```

---

### Task 2: First-run state machine with external-state waiting

**Files:**
- Create: `Sources/AutoReplyApp/Autoconfiguration/FirstRunCoordinator.swift`
- Test: `Tests/AutoReplyAppTests/FirstRunCoordinatorTests.swift`

**Interfaces:**
- Consumes: `OperatorConfig`, `MachineCompatibilityProfile`, `CapabilityStatus` from Task 1.
- Produces: `FirstRunChecking`, `CalibrationProviding`, `ReadinessPrewarming`, and `FirstRunCoordinator`.
- Produces: `FirstRunCoordinator.advance()` and `FirstRunCoordinator.beginAutomaticContinuation()`.

- [ ] **Step 1: Write state-transition tests with injected dependencies**

```swift
@MainActor final class FirstRunCoordinatorTests: XCTestCase {
    func testMissingPermissionWaitsWithoutThrowLoop() async {
        let checks = FakeFirstRunChecks(accessibility: false, screenCapture: true, qianniuReady: true)
        let coordinator = FirstRunCoordinator(checks: checks, calibration: FakeCalibration(), prewarmer: FakePrewarmer())
        await coordinator.advance(operatorConfig: .init(serviceAliases: ["小甘"], autoStartWhenReady: true))
        XCTAssertEqual(coordinator.phase, .permissionsPending)
        XCTAssertEqual(coordinator.blockingReason, "请开启辅助功能")
        XCTAssertEqual(checks.permissionChecks, 1)
    }

    func testReadyChainAdvancesInOrder() async {
        let coordinator = FirstRunCoordinator(
            checks: FakeFirstRunChecks(accessibility: true, screenCapture: true, qianniuReady: true, codexReady: true),
            calibration: FakeCalibration(result: .empty),
            prewarmer: FakePrewarmer()
        )
        await coordinator.advance(operatorConfig: .init(serviceAliases: ["小甘"], autoStartWhenReady: true))
        XCTAssertEqual(coordinator.phase, .readOnlyReady)
        XCTAssertTrue(coordinator.shouldAutoStart)
    }
}
```

- [ ] **Step 2: Run and verify RED**

Run: `swift test --filter FirstRunCoordinatorTests`

Expected: compilation fails because coordinator protocols and implementation are absent.

- [ ] **Step 3: Implement a single-owner state machine**

```swift
protocol FirstRunChecking: Sendable {
    func permissionState() async -> (accessibility: Bool, screenCapture: Bool)
    func qianniuReceptionReady() async -> Bool
    func codexLoggedIn() async -> Bool
}

protocol CalibrationProviding: Sendable {
    func calibrate() async throws -> MachineCompatibilityProfile
}

protocol ReadinessPrewarming: Sendable {
    func prepare() async throws -> [String: CapabilityStatus]
}

@MainActor final class FirstRunCoordinator: ObservableObject {
    @Published private(set) var phase: ReadinessPhase = .installed
    @Published private(set) var blockingReason: String?
    @Published private(set) var capabilities: [String: CapabilityStatus] = [:]
    @Published private(set) var shouldAutoStart = false
    func advance(operatorConfig: OperatorConfig) async
    func beginAutomaticContinuation(operatorConfig: @escaping @Sendable () -> OperatorConfig)
    func stopAutomaticContinuation()
}
```

`advance` must return normally for missing external state, set one of the pending phases, and let the polling task retry at one-second intervals. It must not append a scheduler error each second.

- [ ] **Step 4: Run transition tests and full suite**

Run: `swift test --filter FirstRunCoordinatorTests && swift test`

Expected: all tests pass; no existing scheduler behavior changes.

- [ ] **Step 5: Commit the state machine**

```bash
git add Sources/AutoReplyApp/Autoconfiguration/FirstRunCoordinator.swift Tests/AutoReplyAppTests/FirstRunCoordinatorTests.swift
git commit -m "Add first-run readiness state machine"
```

---

### Task 3: Dedicated Codex login coordinator

**Files:**
- Create: `Sources/AutoReplyApp/Autoconfiguration/CodexLoginCoordinator.swift`
- Modify: `Sources/AutoReplyApp/CodexRuntimeIsolation.swift`
- Test: `Tests/AutoReplyAppTests/CodexLoginCoordinatorTests.swift`
- Test: `Tests/AutoReplyAppTests/CodexRuntimeIsolationTests.swift`

**Interfaces:**
- Consumes: `CodexRuntimeIsolationResult.codexHomeURL` and `workingDirectoryURL`.
- Produces: `CodexLoginRunning`, `CodexLoginState`, `CodexLoginCoordinator.status()` and `startDeviceLogin()`.

- [ ] **Step 1: Write command, environment, and isolation tests**

```swift
func testStatusUsesDedicatedHomeAndNeverPersonalConfig() async throws {
    let runner = RecordingCodexLoginRunner(result: .init(exitCode: 0, output: "Logged in using ChatGPT"))
    let home = URL(fileURLWithPath: "/tmp/customer-codex-home")
    let coordinator = CodexLoginCoordinator(codexURL: URL(fileURLWithPath: "/bin/codex"), codexHomeURL: home, runner: runner)
    XCTAssertEqual(try await coordinator.status(), .loggedIn)
    XCTAssertEqual(runner.calls[0].arguments, ["login", "status"])
    XCTAssertEqual(runner.calls[0].environment["CODEX_HOME"], home.path)
    XCTAssertNil(runner.calls[0].environment["OPENAI_API_KEY"])
}

func testDeviceLoginUsesSameDedicatedHome() async throws {
    let runner = RecordingCodexLoginRunner(result: .init(exitCode: 0, output: "Login successful"))
    let coordinator = CodexLoginCoordinator(codexURL: URL(fileURLWithPath: "/bin/codex"), codexHomeURL: URL(fileURLWithPath: "/tmp/customer"), runner: runner)
    try await coordinator.startDeviceLogin()
    XCTAssertEqual(runner.calls[0].arguments, ["login", "--device-auth"])
}
```

- [ ] **Step 2: Run and confirm RED**

Run: `swift test --filter CodexLoginCoordinatorTests`

Expected: new login types are unresolved.

- [ ] **Step 3: Implement bounded login process execution**

```swift
enum CodexLoginState: Equatable, Sendable { case loggedIn, loginRequired(String) }

struct CodexLoginProcessResult: Sendable { let exitCode: Int32; let output: String }

protocol CodexLoginRunning: Sendable {
    func run(executable: URL, arguments: [String], environment: [String: String]) async throws -> CodexLoginProcessResult
}

actor CodexLoginCoordinator {
    func status() async throws -> CodexLoginState
    func startDeviceLogin() async throws
}
```

Use a process group and a 15-second status timeout. Device login is user-visible and may remain active for five minutes; cancellation terminates the process group. Build the environment from a minimal allowlist plus `CODEX_HOME`; remove API-key variables. Do not copy or link `~/.codex`.

- [ ] **Step 4: Run login, isolation, and full tests**

Run: `swift test --filter 'Codex(LoginCoordinator|RuntimeIsolation)Tests' && swift test`

Expected: dedicated-home assertions and all existing tests pass.

- [ ] **Step 5: Commit Codex readiness support**

```bash
git add Sources/AutoReplyApp/Autoconfiguration/CodexLoginCoordinator.swift Sources/AutoReplyApp/CodexRuntimeIsolation.swift Tests/AutoReplyAppTests/CodexLoginCoordinatorTests.swift Tests/AutoReplyAppTests/CodexRuntimeIsolationTests.swift
git commit -m "Guide isolated Codex login during setup"
```

---

### Task 4: Coordinated OCR, V2, and Codex prewarming

**Files:**
- Create: `Sources/AutoReplyApp/Autoconfiguration/ReadinessPrewarmer.swift`
- Create: `components/ocr-source/Sources/QianniuOCRAppSupport/OCRPrewarming.swift`
- Modify: `components/ocr-source/Sources/QianniuOCRAppSupport/LiveOCRRunner.swift`
- Modify: `components/ocr-source/Sources/QianniuOCRAppSupport/PaddleOCRWebEngine.swift`
- Test: `components/ocr-source/Tests/QianniuOCRAppSupportTests/OCRPrewarmTests.swift`
- Modify: `Sources/AutoReplyApp/AutomationAppModel.swift`
- Test: `Tests/AutoReplyAppTests/ReadinessPrewarmerTests.swift`
- Test: `Tests/AutoReplyAppTests/AutomationAppModelTests.swift`

**Interfaces:**
- Consumes: existing `KnowledgePrewarming`, `CodexLoginCoordinator`, and a new narrow `OCRPrewarming` protocol implemented by the live OCR service.
- Produces: `ReadinessPrewarmer.prepare() -> [String: CapabilityStatus]`.

- [ ] **Step 1: Write ordering, retry, and truthful-state tests**

```swift
func testPrepareReportsEachSubsystemSeparately() async throws {
    let prewarmer = ReadinessPrewarmer(
        ocr: RecordingOCRPrewarmer(result: .success(())),
        knowledge: RecordingKnowledgePrewarmer(version: "v2-top12"),
        codex: RecordingCodexReadiness(result: .loggedIn)
    )
    let statuses = try await prewarmer.prepare()
    XCTAssertEqual(statuses["ocr"]?.level, .verified)
    XCTAssertEqual(statuses["v2"]?.strategy, "persistent-top12")
    XCTAssertEqual(statuses["codex"]?.level, .verified)
}

func testKeywordKnowledgeModeIsDegradedButRunnable() async throws {
    let prewarmer = ReadinessPrewarmer(
        ocr: RecordingOCRPrewarmer(result: .success(())),
        knowledge: RecordingKnowledgePrewarmer(version: "lexical-fallback"),
        codex: RecordingCodexReadiness(result: .loggedIn)
    )
    XCTAssertEqual(try await prewarmer.prepare()["v2"]?.level, .fallback)
}
```

- [ ] **Step 2: Run and confirm RED**

Run: `swift test --filter ReadinessPrewarmerTests`

Expected: missing prewarmer types.

- [ ] **Step 3: Implement ordered preparation without duplicate workers**

```swift
protocol CodexReadinessChecking: Sendable {
    func codexState() async throws -> CodexLoginState
    func runNoToolGenerationProbe() async throws
}

actor ReadinessPrewarmer: ReadinessPrewarming {
    func prepare() async throws -> [String: CapabilityStatus]
}
```

Define the dependency-facing interface inside `QianniuOCRAppSupport`, not in `AutoReplyApp`, to avoid a package cycle:

```swift
@MainActor public protocol OCRPrewarming: AnyObject {
    func prepareOCR() async throws
}
```

Make `LiveOCRRunner` conform to that protocol and add `PaddleOCRWebEngine.prepare()` as a narrow wrapper around its existing `ensureReady()` task. The same `LiveOCRRunner` instance used by `LiveNativeUI` must be injected into `ReadinessPrewarmer`; do not instantiate a second WebKit OCR engine. Reuse the same live `KnowledgePrewarming` instance already passed to `AutomationAppModel`; do not start a second V2 worker. After `codexState()` reports logged in, run one no-image, no-knowledge, no-tool generation probe in the dedicated `CODEX_HOME`; validate a one-field JSON schema and discard the temporary session/result. Coalesce simultaneous prepare calls into one task. Map lexical fallback to `.fallback` rather than failure.

- [ ] **Step 4: Run prewarm and model regression tests**

Run: `swift test --package-path components/ocr-source --filter OCRPrewarmTests && swift test --filter 'ReadinessPrewarmerTests|AutomationAppModelTests' && swift test`

Expected: one prewarm call per subsystem and the legacy V2 retry tests remain green.

- [ ] **Step 5: Commit unified prewarming**

```bash
git add Sources/AutoReplyApp/Autoconfiguration/ReadinessPrewarmer.swift Sources/AutoReplyApp/AutomationAppModel.swift components/ocr-source/Sources/QianniuOCRAppSupport/OCRPrewarming.swift components/ocr-source/Sources/QianniuOCRAppSupport/LiveOCRRunner.swift components/ocr-source/Sources/QianniuOCRAppSupport/PaddleOCRWebEngine.swift components/ocr-source/Tests/QianniuOCRAppSupportTests/OCRPrewarmTests.swift Tests/AutoReplyAppTests/ReadinessPrewarmerTests.swift Tests/AutoReplyAppTests/AutomationAppModelTests.swift
git commit -m "Coordinate first-run runtime prewarming"
```

---

### Task 5: Backward-compatible phase-one calibration provider

**Files:**
- Create: `Sources/AutoReplyApp/Autoconfiguration/LegacyCalibrationProvider.swift`
- Modify: `Sources/AutoReplyApp/AutomationSafety.swift`
- Test: `Tests/AutoReplyAppTests/LegacyCalibrationProviderTests.swift`

**Interfaces:**
- Consumes: existing `AutomationPermissions`, `NativeSafety`, and reception-window selection.
- Produces: a `CalibrationProviding` implementation that emits a truthful legacy capability profile.

- [ ] **Step 1: Write profile and failure-isolation tests**

```swift
func testLegacyProviderMarksExistingPathsWithoutClaimingAdaptiveCalibration() async throws {
    let provider = LegacyCalibrationProvider(probe: FakeLegacyProbe(
        receptionWindow: true, conversationList: true, composer: true
    ))
    let profile = try await provider.calibrate()
    XCTAssertEqual(profile.capabilities["receptionWindow"]?.level, .verified)
    XCTAssertEqual(profile.capabilities["conversationList"]?.strategy, "legacy-static-rules")
    XCTAssertNil(profile.endToEndPassedAt)
}

func testMissingComposerDoesNotEraseOtherCapabilities() async throws {
    let profile = try await LegacyCalibrationProvider(probe: FakeLegacyProbe(
        receptionWindow: true, conversationList: true, composer: false
    )).calibrate()
    XCTAssertEqual(profile.capabilities["conversationList"]?.level, .verified)
    XCTAssertEqual(profile.capabilities["composer"]?.level, .unavailable)
}
```

- [ ] **Step 2: Run and confirm RED**

Run: `swift test --filter LegacyCalibrationProviderTests`

Expected: provider does not exist.

- [ ] **Step 3: Implement read-only legacy capability reporting**

```swift
protocol LegacyCapabilityProbing: Sendable {
    func receptionWindowAvailable() async -> Bool
    func conversationListAvailable() async -> Bool
    func composerAvailable() async -> Bool
}

struct LegacyCalibrationProvider: CalibrationProviding {
    func calibrate() async throws -> MachineCompatibilityProfile
}
```

This provider must not click, type, capture customer text, or send. It records `legacy-static-rules` so phase two can distinguish old behavior from adaptive configuration.

- [ ] **Step 4: Run calibration and safety tests**

Run: `swift test --filter 'LegacyCalibrationProviderTests|AutomationSafetyTests' && swift test`

Expected: focused and full suites pass.

- [ ] **Step 5: Commit the compatibility bridge**

```bash
git add Sources/AutoReplyApp/Autoconfiguration/LegacyCalibrationProvider.swift Sources/AutoReplyApp/AutomationSafety.swift Tests/AutoReplyAppTests/LegacyCalibrationProviderTests.swift
git commit -m "Bridge existing safety checks into setup calibration"
```

---

### Task 6: First-run SwiftUI and automatic start integration

**Files:**
- Create: `Sources/AutoReplyApp/Autoconfiguration/FirstRunView.swift`
- Modify: `Sources/AutoReplyApp/AutoReplyApplication.swift`
- Modify: `Sources/AutoReplyApp/AutomationAppModel.swift`
- Test: `Tests/AutoReplyAppTests/FirstRunViewModelTests.swift`
- Test: `Tests/AutoReplyAppTests/AutomationAppModelTests.swift`

**Interfaces:**
- Consumes: `FirstRunCoordinator`, `OperatorConfig`, `AutomationPermissions`.
- Produces: `FirstRunViewModel`, explicit actions for permission settings, Codex login, alias save, retry, and auto-start.

- [ ] **Step 1: Write UI-model and auto-start tests**

```swift
@MainActor func testReadyCoordinatorStartsSchedulerExactlyOnce() async throws {
    let harness = AutomationModelHarness(firstRunPhase: .readOnlyReady, autoStart: true)
    await harness.model.consumeReadinessChange()
    await harness.model.consumeReadinessChange()
    XCTAssertEqual(harness.schedulerStartCount, 1)
}

@MainActor func testPermissionActionOpensCorrectPaneWithoutStarting() {
    let viewModel = FirstRunViewModel(settings: RecordingSettingsOpener())
    viewModel.openAccessibilitySettings()
    XCTAssertEqual(viewModel.settings.lastPane, .accessibility)
    XCTAssertFalse(viewModel.startRequested)
}
```

- [ ] **Step 2: Run and confirm RED**

Run: `swift test --filter 'FirstRunViewModelTests|AutomationAppModelTests'`

Expected: missing view model and readiness integration.

- [ ] **Step 3: Implement the wizard and one-shot automatic start**

The view must show the eight user stages from the spec and an advanced list sourced from `capabilities`. `AutomationAppModel` must persist aliases through `OperatorConfig`, observe `FirstRunCoordinator`, and invoke the existing `start()` only once when `phase == .readOnlyReady && autoStartWhenReady`.

```swift
@MainActor func consumeReadinessChange() async {
    guard firstRun.phase == .readOnlyReady,
          firstRun.shouldAutoStart,
          !automaticStartConsumed else { return }
    automaticStartConsumed = true
    start()
}
```

The existing status UI remains available after setup. Do not duplicate scheduler ownership in the view.

- [ ] **Step 4: Run full Swift and Python regression suites**

Run:

```bash
swift test
swift test --package-path components/unread-source
swift test --package-path components/ocr-source
swift test --package-path components/sender-source
swift test --package-path components/batch-source
python3 -m unittest discover -s Tests -p '*test*.py'
```

Expected: all suites pass; app setup tests show one automatic start and no production-logic changes.

- [ ] **Step 5: Build the phase-one app and inspect the signed bundle**

Run: `AUTOREPLY_SIGNING_IDENTITY=- scripts/build-app.sh`

Expected: build completes, `codesign --verify --deep --strict` succeeds, and the app contains the existing OCR/V2/knowledge resources.

- [ ] **Step 6: Commit phase-one integration**

```bash
git add Sources/AutoReplyApp/Autoconfiguration Sources/AutoReplyApp/AutoReplyApplication.swift Sources/AutoReplyApp/AutomationAppModel.swift Tests/AutoReplyAppTests
git commit -m "Add guided first-run readiness flow"
```

## Phase-One Acceptance Checkpoint

- Existing algorithms remain active through `LegacyCalibrationProvider`.
- A fresh support directory walks through permissions, Qianniu, alias, Codex login, prewarm, and read-only readiness.
- Missing external state waits without exiting or logging an error every second.
- Automatic start occurs once after readiness when enabled.
- Current and last-known-good configuration survive restart and rejected writes.
- No personal Codex configuration or credentials enter the package.
