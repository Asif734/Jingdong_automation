# Qianniu Adaptive Runtime Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace machine-specific locator assumptions with a calibrated, per-capability RuntimeAdapter while preserving the current scheduler and customer history semantics.

**Architecture:** Read-only snapshots produce an environment fingerprint and focused policies for window, conversation rows, identity, capture, composer, and send. Existing component selectors accept these policies; the App-level adapter selects semantic AX first, relative geometry second, and OCR/visual fallback last.

**Tech Stack:** Swift 5.9, AppKit/ApplicationServices/CoreGraphics, existing `UnreadCore`, `QianniuOCRCore`, `QianniuSenderCore`, Codable profiles, fixture-driven tests.

**Spec:** `docs/superpowers/specs/2026-09-01-qianniu-universal-autoconfiguration-design.md`

## Global Constraints

- Execute only after `2026-09-01-qianniu-autoconfiguration-foundation.md` is complete and green.
- Do not modify Version A; retain colleague B baseline and last-known-good profile rollback.
- Every capability failure is local; no single AX node may abort the full conversation-list result.
- No absolute screen coordinate may be the sole selector.
- Configuration stores only structural digests, relative geometry, strategy names, and validation state.
- The scheduler continues using `NativeUIAutomation`; customer cursor, queue, and delivery semantics remain unchanged.

## File Map

- Create `Sources/AutoReplyApp/Autoconfiguration/EnvironmentFingerprint.swift`: normalized environment and structural digests.
- Create `Sources/AutoReplyApp/Autoconfiguration/CalibrationSnapshot.swift`: privacy-safe window/AX/display observations.
- Create `Sources/AutoReplyApp/Autoconfiguration/AdaptiveCalibrationEngine.swift`: full profile generation.
- Create `Sources/AutoReplyApp/Autoconfiguration/RuntimeAdapter.swift`: capability routing and local fallback.
- Create `Sources/AutoReplyApp/Autoconfiguration/ProfileLifecycle.swift`: fast validation, local recalibration, rollback.
- Modify `components/unread-source/Sources/UnreadCore/ConversationLocator.swift`: policy-driven row classification.
- Modify `components/ocr-source/Sources/QianniuOCRCore/TargetSelection.swift`: calibrated window/crop policy.
- Modify `components/sender-source/Sources/QianniuSenderCore/QianniuElementSelection.swift`: calibrated composer/send policy.
- Modify `Sources/AutoReplyApp/NativeSession.swift`, `NativeConversationList.swift`, `LiveNativeUI.swift`, and `AutomationAppModel.swift`: consume RuntimeAdapter.
- Add focused tests in the corresponding root/component test targets.

---

### Task 1: Privacy-safe snapshots and environment fingerprints

**Files:**
- Create: `Sources/AutoReplyApp/Autoconfiguration/CalibrationSnapshot.swift`
- Create: `Sources/AutoReplyApp/Autoconfiguration/EnvironmentFingerprint.swift`
- Test: `Tests/AutoReplyAppTests/EnvironmentFingerprintTests.swift`

**Interfaces:**
- Produces: `CalibrationAXNode`, `CalibrationWindow`, `CalibrationDisplay`, `CalibrationSnapshot`, `EnvironmentFingerprint`.
- Produces: `EnvironmentFingerprint.make(from:)` and deterministic `digest`.

- [ ] **Step 1: Write determinism and redaction tests**

```swift
func testFingerprintIgnoresCustomerTextButTracksStructure() throws {
    let first = CalibrationSnapshot.fixture(customerLabel: "customer-A", rowHeight: 66)
    let second = CalibrationSnapshot.fixture(customerLabel: "customer-B", rowHeight: 66)
    XCTAssertEqual(EnvironmentFingerprint.make(from: first).digest,
                   EnvironmentFingerprint.make(from: second).digest)
}

func testFingerprintChangesForQianniuBuildOrStructure() throws {
    let original = CalibrationSnapshot.fixture(qianniuBuild: "1", rowHeight: 66)
    let changed = CalibrationSnapshot.fixture(qianniuBuild: "2", rowHeight: 34)
    XCTAssertNotEqual(EnvironmentFingerprint.make(from: original).digest,
                      EnvironmentFingerprint.make(from: changed).digest)
}
```

- [ ] **Step 2: Run and confirm RED**

Run: `swift test --filter EnvironmentFingerprintTests`

Expected: snapshot/fingerprint types are missing.

- [ ] **Step 3: Implement normalized structural hashing**

```swift
struct CalibrationAXNode: Codable, Equatable, Sendable {
    let id: Int
    let parentID: Int?
    let role: String
    let actionNames: [String]
    let labelCategory: String
    let relativeFrame: CGRect
    let hasValue: Bool
}

struct EnvironmentFingerprint: Codable, Equatable, Sendable {
    let macOSBuild: String
    let architecture: String
    let qianniuVersion: String
    let qianniuBuild: String
    let displayScales: [Double]
    let structureDigest: String
    var digest: String
    static func make(from snapshot: CalibrationSnapshot) -> Self
}
```

Map raw labels to categories such as `reception-title`, `list-anchor`, `image-marker`, `input-control`, `send-control`, `identity-like`, and `blank`; never hash raw customer text.

- [ ] **Step 4: Run focused and full app tests**

Run: `swift test --filter EnvironmentFingerprintTests && swift test`

Expected: deterministic hashes pass and no existing behavior changes.

- [ ] **Step 5: Commit fingerprint support**

```bash
git add Sources/AutoReplyApp/Autoconfiguration/CalibrationSnapshot.swift Sources/AutoReplyApp/Autoconfiguration/EnvironmentFingerprint.swift Tests/AutoReplyAppTests/EnvironmentFingerprintTests.swift
git commit -m "Add privacy-safe environment fingerprints"
```

---

### Task 2: Calibrated reception-window selection and coordinate mapping

**Files:**
- Create: `Sources/AutoReplyApp/Autoconfiguration/WindowCalibration.swift`
- Create: `components/ocr-source/Sources/QianniuOCRCore/WindowSelectionPolicy.swift`
- Modify: `Sources/AutoReplyApp/AutomationSafety.swift`
- Modify: `components/ocr-source/Sources/QianniuOCRCore/TargetSelection.swift`
- Test: `Tests/AutoReplyAppTests/WindowCalibrationTests.swift`
- Test: `components/ocr-source/Tests/QianniuOCRCoreTests/TargetSelectionTests.swift`

**Interfaces:**
- `QianniuOCRCore` produces dependency-facing `WindowSelectionPolicy` and `CoordinateMapping`; the root App imports them without creating a package cycle.
- `WindowCalibration.calibrate(snapshot:)` produces `WindowSelectionPolicy`.
- Adds: `TargetSelection.qianniuWindow(from:policy:)` while preserving the existing overload for migration.

- [ ] **Step 1: Write mixed-scale, one-pixel, and wrong-workbench tests**

```swift
func testCalibrationMatchesAXAndCaptureUsingMeasuredScale() throws {
    let policy = try WindowCalibration.calibrate(snapshot: .twoXScaleReceptionFixture)
    XCTAssertEqual(policy.coordinateMapping.pointsToPixelsX, 2, accuracy: 0.001)
    XCTAssertEqual(policy.coordinateMapping.pointsToPixelsY, 2, accuracy: 0.001)
}

func testReceptionOutranksWorkbenchWithIndependentEvidence() throws {
    let policy = try WindowCalibration.calibrate(snapshot: .receptionAndWorkbenchFixture)
    XCTAssertEqual(policy.selectedWindowRole, "reception")
    XCTAssertTrue(policy.requiredRegions.contains("conversation-list"))
    XCTAssertTrue(policy.requiredRegions.contains("composer"))
}
```

- [ ] **Step 2: Run and confirm RED**

Run: `swift test --filter WindowCalibrationTests && swift test --package-path components/ocr-source --filter TargetSelectionTests`

Expected: policy APIs are absent.

- [ ] **Step 3: Implement scoring with measured geometry**

```swift
public struct CoordinateMapping: Codable, Equatable, Sendable {
    let pointsToPixelsX: Double
    let pointsToPixelsY: Double
    let originOffsetX: Double
    let originOffsetY: Double
}

public struct WindowSelectionPolicy: Codable, Equatable, Sendable {
    let selectedWindowRole: String
    let requiredTitleTokens: [String]
    let minimumRelativeSize: CGSize
    let requiredRegions: Set<String>
    let coordinateMapping: CoordinateMapping
}
```

Require process ownership plus at least two independent signals among reception title, list region, chat region, and composer region. Replace global pixel tolerance with mapping residual derived from the calibration pairs.

- [ ] **Step 4: Run window, OCR, and safety suites**

Run: `swift test --filter 'WindowCalibrationTests|AutomationSafetyTests' && swift test --package-path components/ocr-source --filter TargetSelectionTests`

Expected: wrong workbench is rejected and 1–3 pixel representation differences pass when consistent with mapping.

- [ ] **Step 5: Commit window calibration**

```bash
git add Sources/AutoReplyApp/Autoconfiguration/WindowCalibration.swift Sources/AutoReplyApp/AutomationSafety.swift components/ocr-source/Sources/QianniuOCRCore/WindowSelectionPolicy.swift components/ocr-source/Sources/QianniuOCRCore/TargetSelection.swift Tests/AutoReplyAppTests/WindowCalibrationTests.swift components/ocr-source/Tests/QianniuOCRCoreTests/TargetSelectionTests.swift
git commit -m "Calibrate Qianniu window and display coordinates"
```

---

### Task 3: Policy-driven conversation rows and section headers

**Files:**
- Modify: `components/unread-source/Sources/UnreadCore/ConversationLocator.swift`
- Create: `components/unread-source/Sources/UnreadCore/ConversationListPolicy.swift`
- Test: `components/unread-source/Tests/UnreadCoreTests/ConversationListPolicyTests.swift`
- Test: `components/unread-source/Tests/UnreadCoreTests/ConversationCandidateTests.swift`

**Interfaces:**
- Produces: `ConversationListPolicy.calibrate(nodes:window:)`.
- Adds: `ConversationLocator.candidates(nodes:window:policy:preferStructuralUID:)`.
- Preserves: old overload during migration; it constructs `ConversationListPolicy.legacy`.

- [ ] **Step 1: Write A/B structure, blank header, and malformed-row tests**

```swift
func testBlankShortHeaderDoesNotBecomeCustomer() throws {
    let fixture = ConversationFixture.colleagueBWithBlankHeader
    let policy = try ConversationListPolicy.calibrate(nodes: fixture.nodes, window: fixture.window)
    let result = try ConversationLocator.candidates(nodes: fixture.nodes, window: fixture.window, policy: policy)
    XCTAssertEqual(result.compactMap(\.identity.resolved), ["stoneshishininger"])
}

func testMalformedNodeDoesNotDiscardValidRows() throws {
    let fixture = ConversationFixture.validRowsWithMalformedMiddleNode
    let result = try ConversationLocator.candidates(
        nodes: fixture.nodes, window: fixture.window,
        policy: try .calibrate(nodes: fixture.nodes, window: fixture.window)
    )
    XCTAssertEqual(Set(result.compactMap(\.identity.resolved)), ["customer-a", "customer-b"])
}
```

- [ ] **Step 2: Run and confirm RED**

Run: `swift test --package-path components/unread-source --filter ConversationListPolicyTests`

Expected: policy types/overloads are absent.

- [ ] **Step 3: Implement relative row modeling**

```swift
public struct ConversationListPolicy: Codable, Equatable, Sendable {
    public let medianCustomerHeight: CGFloat
    public let medianRowSpacing: CGFloat
    public let minimumWidthRatio: CGFloat
    public let sectionHeaderMaximumHeightRatio: CGFloat
    public let anchorLabelCategory: String
}
```

Build the reference height only from rows with identity evidence. A blank/no-red node below `0.80 * medianCustomerHeight` is a section header. A red-dot row without identity becomes unresolved, not a fabricated customer. Iterate per node and retain previously accepted rows when one node is malformed.

- [ ] **Step 4: Run unread package and root integration tests**

Run: `swift test --package-path components/unread-source && swift test --filter 'NativeAutomationDriverTests|ReceptionActivationTests'`

Expected: all valid customers survive malformed neighbors; existing colleague B regression remains green.

- [ ] **Step 5: Commit row adaptation**

```bash
git add components/unread-source/Sources/UnreadCore components/unread-source/Tests/UnreadCoreTests
git commit -m "Calibrate conversation rows per Qianniu structure"
```

---

### Task 4: Identity strategy calibration and runtime resolution

**Files:**
- Create: `Sources/AutoReplyApp/Autoconfiguration/IdentityCalibration.swift`
- Create: `components/unread-source/Sources/UnreadCore/ConversationIdentityPolicy.swift`
- Modify: `components/unread-source/Sources/UnreadCore/ConversationCandidate.swift`
- Modify: `components/unread-source/Sources/UnreadCore/ConversationLocator.swift`
- Modify: `Sources/AutoReplyApp/NativeSession.swift`
- Test: `Tests/AutoReplyAppTests/IdentityCalibrationTests.swift`
- Test: `components/unread-source/Tests/UnreadCoreTests/ProfileIdentityTests.swift`

**Interfaces:**
- `UnreadCore` produces dependency-facing `ConversationIdentitySource` and `ConversationIdentityPolicy`.
- App-level `IdentityCalibration` inspects capabilities and produces `ConversationIdentityPolicy` without introducing a reverse dependency.
- Adds evidence source metadata to `ConversationIdentityEvidence` without changing `resolved` semantics.
- Consumes current visible rows when deciding whether a truncated prefix is unique.

- [ ] **Step 1: Write source-order and prefix-collision tests**

```swift
func testFullContainerUIDWinsOverNicknameAndOCR() {
    let policy = ConversationIdentityPolicy.availableSources(
        containerTitle: true, childNickname: true, header: true, ocr: true
    )
    XCTAssertEqual(policy.orderedSources.first, .containerTitle)
}

func testTruncatedPrefixIsRejectedWhenTwoVisibleRowsShareIt() {
    let policy = ConversationIdentityPolicy.default
    XCTAssertNil(policy.resolvePrefix("stonesh...", visibleIdentities: ["stoneshishininger", "stoneshipping"]))
}
```

- [ ] **Step 2: Run and confirm RED**

Run: `swift test --filter IdentityCalibrationTests`

Expected: identity policy is missing.

- [ ] **Step 3: Implement ordered, evidence-bearing identity resolution**

```swift
public enum ConversationIdentitySource: String, Codable, Sendable {
    case containerTitle, childNickname, chatHeader, uniquePrefix, ocrNickname
}

public struct ConversationIdentityPolicy: Codable, Equatable, Sendable {
    public let orderedSources: [ConversationIdentitySource]
    func resolvePrefix(_ display: String, visibleIdentities: [String]) -> String?
}
```

Do not persist actual identity values in the machine profile. The live snapshot supplies values; the profile supplies only source order and matching policy. Existing profile-panel identity remains a supported source when the header is truncated.

- [ ] **Step 4: Run identity, unread, and root tests**

Run: `swift test --filter IdentityCalibrationTests && swift test --package-path components/unread-source && swift test`

Expected: full UID paths remain unchanged; unique English/Chinese prefixes work; collisions remain unresolved.

- [ ] **Step 5: Commit identity calibration**

```bash
git add Sources/AutoReplyApp/Autoconfiguration/IdentityCalibration.swift Sources/AutoReplyApp/NativeSession.swift components/unread-source/Sources/UnreadCore/ConversationIdentityPolicy.swift components/unread-source/Sources/UnreadCore/ConversationCandidate.swift components/unread-source/Sources/UnreadCore/ConversationLocator.swift components/unread-source/Tests/UnreadCoreTests Tests/AutoReplyAppTests/IdentityCalibrationTests.swift
git commit -m "Adapt customer identity sources per machine"
```

---

### Task 5: Calibrated capture, composer, and send strategies

**Files:**
- Create: `Sources/AutoReplyApp/Autoconfiguration/InteractionCalibration.swift`
- Create: `components/ocr-source/Sources/QianniuOCRCore/CaptureSelectionPolicy.swift`
- Create: `components/sender-source/Sources/QianniuSenderCore/ComposerSelectionPolicy.swift`
- Modify: `components/ocr-source/Sources/QianniuOCRCore/TargetSelection.swift`
- Modify: `components/sender-source/Sources/QianniuSenderCore/QianniuElementSelection.swift`
- Modify: `components/sender-source/Sources/QianniuSenderCore/MessageSending.swift`
- Test: `Tests/AutoReplyAppTests/InteractionCalibrationTests.swift`
- Test: `components/ocr-source/Tests/QianniuOCRCoreTests/TargetSelectionTests.swift`
- Test: `components/sender-source/Tests/QianniuSenderCoreTests/QianniuElementSelectionTests.swift`

**Interfaces:**
- `QianniuOCRCore` produces `CaptureSelectionPolicy`; `QianniuSenderCore` produces `ComposerSelectionPolicy` and continues using existing `QianniuSendTrigger`.
- App-level `InteractionCalibration` produces those dependency-facing policies without making component packages import `AutoReplyApp`.
- Adds policy arguments to target and sender selection with legacy overloads during migration.

- [ ] **Step 1: Write relative crop and action-selection tests**

```swift
func testCaptureRegionUsesWindowRelativeRect() {
    let policy = CaptureSelectionPolicy(relativeMessageRect: CGRect(x: 0.24, y: 0.16, width: 0.43, height: 0.62))
    XCTAssertEqual(policy.absoluteMessageRect(in: CGRect(x: 100, y: 50, width: 1000, height: 800)),
                   CGRect(x: 340, y: 178, width: 430, height: 496))
}

func testAXButtonUsesPressAndMenuButtonUsesReturn() {
    XCTAssertEqual(ComposerSelectionPolicy.resolveSendTrigger(role: "AXButton", actions: ["AXPress"]), .accessibilityPress)
    XCTAssertEqual(ComposerSelectionPolicy.resolveSendTrigger(role: "AXMenuButton", actions: []), .returnKeyOnce)
}
```

- [ ] **Step 2: Run and confirm RED**

Run: `swift test --filter InteractionCalibrationTests`

Expected: policy types are missing.

- [ ] **Step 3: Implement capability-specific policies**

```swift
public struct CaptureSelectionPolicy: Codable, Equatable, Sendable {
    let relativeMessageRect: CGRect
    func absoluteMessageRect(in window: CGRect) -> CGRect
}

public struct ComposerSelectionPolicy: Codable, Equatable, Sendable {
    let acceptedRoles: [String]
    let relativeRegion: CGRect
    let fallback: SendFallbackPolicy
    static func resolveSendTrigger(role: String, actions: [String]) -> QianniuSendTrigger?
}

public struct SendFallbackPolicy: Codable, Equatable, Sendable {
    let relativeClickPoint: CGPoint?
}
```

Add `Codable` conformance to the existing no-associated-value `QianniuSendTrigger`. `ComposerSelectionPolicy.resolveSendTrigger` returns that enum for AX press or Return. `SendFallbackPolicy.relativeClickPoint` is non-nil only for the exact unique calibrated control. Coordinate click is permitted only when the candidate remains inside the calibrated relative region. Preserve existing input-clear/new-bubble verification as the distinction between activation and successful delivery.

- [ ] **Step 4: Run OCR, sender, and app tests**

Run:

```bash
swift test --filter InteractionCalibrationTests
swift test --package-path components/ocr-source
swift test --package-path components/sender-source
swift test
```

Expected: all suites pass and existing AXPress/Return regressions remain protected.

- [ ] **Step 5: Commit interaction calibration**

```bash
git add Sources/AutoReplyApp/Autoconfiguration/InteractionCalibration.swift components/ocr-source/Sources/QianniuOCRCore/CaptureSelectionPolicy.swift components/ocr-source/Sources/QianniuOCRCore/TargetSelection.swift components/ocr-source/Tests/QianniuOCRCoreTests/TargetSelectionTests.swift components/sender-source/Sources/QianniuSenderCore/ComposerSelectionPolicy.swift components/sender-source/Sources/QianniuSenderCore/QianniuElementSelection.swift components/sender-source/Sources/QianniuSenderCore/MessageSending.swift components/sender-source/Tests/QianniuSenderCoreTests Tests/AutoReplyAppTests/InteractionCalibrationTests.swift
git commit -m "Calibrate capture composer and send behavior"
```

---

### Task 6: RuntimeAdapter and native-session integration

**Files:**
- Create: `Sources/AutoReplyApp/Autoconfiguration/RuntimeAdapter.swift`
- Create: `Sources/AutoReplyApp/Autoconfiguration/AdaptiveCalibrationEngine.swift`
- Modify: `Sources/AutoReplyApp/Autoconfiguration/AutoconfigurationModels.swift`
- Modify: `Sources/AutoReplyApp/Autoconfiguration/AtomicJSONStore.swift`
- Modify: `Sources/AutoReplyApp/NativeSession.swift`
- Modify: `Sources/AutoReplyApp/NativeConversationList.swift`
- Modify: `Sources/AutoReplyApp/LiveNativeUI.swift`
- Modify: `Sources/AutoReplyApp/AutomationAppModel.swift`
- Modify: `Sources/AutoReplyApp/Autoconfiguration/FirstRunView.swift`
- Test: `Tests/AutoReplyAppTests/RuntimeAdapterTests.swift`
- Test: `Tests/AutoReplyAppTests/NativeAutomationDriverTests.swift`

**Interfaces:**
- Produces: `RuntimeAdapting`, `AdaptiveRuntimeAdapter`, and `AdaptiveCalibrationEngine` implementing `CalibrationProviding`.
- Consumes: policies from Tasks 2–5 and `MachineCompatibilityProfile` from the foundation plan.
- Produces: profile schema version 2 with optional typed window/list/identity/capture/composer/send policy fields and a deterministic migration from schema version 1.

- [ ] **Step 1: Write per-capability fallback and no-global-abort tests**

```swift
func testUnavailableAXCaptureFallsBackWithoutChangingSendStrategy() async throws {
    let adapter = AdaptiveRuntimeAdapter.fixture(captureAX: .unavailable, captureOCR: .verified, sendAX: .verified)
    XCTAssertEqual(try await adapter.captureStrategy(), .ocr)
    XCTAssertEqual(try await adapter.sendStrategy(), .accessibilityPress)
}

func testOneMalformedRowStillReturnsOtherCustomers() async throws {
    let adapter = AdaptiveRuntimeAdapter.fixtureWithMalformedMiddleRow()
    XCTAssertEqual(Set(try await adapter.discoverCustomers()), ["customer-a", "customer-b"])
}
```

- [ ] **Step 2: Run and confirm RED**

Run: `swift test --filter RuntimeAdapterTests`

Expected: runtime adapter does not exist.

- [ ] **Step 3: Implement the stable adapter interface**

```swift
@MainActor protocol RuntimeAdapting: AnyObject {
    func receptionWindow() async throws -> CalibratedReceptionWindow
    func discoverCustomers() async throws -> [ConversationCandidate]
    func resolveIdentity(for candidate: ConversationCandidate) async throws -> String?
    func captureStrategy() async throws -> RuntimeCaptureStrategy
    func composerStrategy() async throws -> ComposerSelectionPolicy
    func sendStrategy() async throws -> QianniuSendTrigger
}
```

`LiveNativeUI` and `NativeSession` must ask this adapter for strategies while preserving the existing `NativeUIAutomation` surface used by the scheduler. Remove direct creation of machine-wide fixed policies from live methods only after all callers use the adapter.

Upgrade `MachineCompatibilityProfile.schemaVersion` to 2 and add these optional fields: `windowPolicy`, `conversationListPolicy`, `identityPolicy`, `capturePolicy`, `composerPolicy`, and `sendPolicy`. Decoding a version-1 profile must preserve its capabilities and produce nil typed policies, forcing a full adaptive calibration; decoding must not delete the version-1 last-known-good file.

Update the advanced area of `FirstRunView` to display the live profile's actual per-capability strategy, for example `客户身份 · containerTitle · verified` and `消息正文 · ocr · fallback`; never infer green status from the global scheduler state.

- [ ] **Step 4: Run root and all component suites**

Run:

```bash
swift test
swift test --package-path components/unread-source
swift test --package-path components/ocr-source
swift test --package-path components/sender-source
swift test --package-path components/batch-source
```

Expected: all pass; scheduler tests require no adaptive-runtime knowledge.

- [ ] **Step 5: Commit adaptive runtime wiring**

```bash
git add Sources/AutoReplyApp components/unread-source components/ocr-source components/sender-source Tests/AutoReplyAppTests
git commit -m "Route native automation through calibrated capabilities"
```

---

### Task 7: Profile lifecycle and local recalibration

**Files:**
- Create: `Sources/AutoReplyApp/Autoconfiguration/ProfileLifecycle.swift`
- Modify: `Sources/AutoReplyApp/AutomationAppModel.swift`
- Modify: `Sources/AutoReplyApp/NativeAutomationDriver.swift`
- Modify: `Sources/AutoReplyApp/Autoconfiguration/FirstRunCoordinator.swift`
- Test: `Tests/AutoReplyAppTests/ProfileLifecycleTests.swift`
- Test: `Tests/AutoReplyAppTests/AutomationAppModelTests.swift`

**Interfaces:**
- Produces: `ProfileLifecycle.validateQuickly(snapshot:)`, `recordFailure(capability:)`, `recordEndToEndDelivery()`, `recalibrate(_:)`, and `currentProfile`.
- Consumes: `AtomicJSONStore<MachineCompatibilityProfile>` and `AdaptiveCalibrationEngine`.

- [ ] **Step 1: Write reuse, local invalidation, and rollback tests**

```swift
func testMatchingFingerprintReusesCurrentProfile() async throws {
    let lifecycle = ProfileLifecycle.fixture(current: .verifiedFixture)
    XCTAssertEqual(try await lifecycle.validateQuickly(snapshot: .matchingFixture), .reuseCurrent)
}

func testDisplayChangeRecalibratesCoordinateCapabilityOnly() async throws {
    let lifecycle = ProfileLifecycle.fixture(current: .verifiedFixture)
    let result = try await lifecycle.validateQuickly(snapshot: .differentDisplayFixture)
    XCTAssertEqual(result, .recalibrate(capabilities: ["coordinateMapping"]))
}

func testRejectedCandidateKeepsLastKnownGood() async throws {
    let lifecycle = ProfileLifecycle.fixture(current: .verifiedFixture, candidateValidation: false)
    do {
        try await lifecycle.recalibrate(["composer"])
        XCTFail("candidate validation should fail")
    } catch {
        XCTAssertNotNil(error)
    }
    let current = await lifecycle.currentProfile
    XCTAssertEqual(current.profileID, MachineCompatibilityProfile.verifiedFixture.profileID)
}
```

- [ ] **Step 2: Run and confirm RED**

Run: `swift test --filter ProfileLifecycleTests`

Expected: lifecycle APIs are absent.

- [ ] **Step 3: Implement fast validation and two-failure local recalibration**

```swift
enum ProfileValidationDecision: Equatable, Sendable {
    case reuseCurrent
    case recalibrate(capabilities: Set<String>)
    case fullCalibration
}

actor ProfileLifecycle {
    func validateQuickly(snapshot: CalibrationSnapshot) async throws -> ProfileValidationDecision
    func recordFailure(capability: String) async -> ProfileValidationDecision
    func recordEndToEndDelivery(at date: Date) async throws
    func recalibrate(_ capabilities: Set<String>) async throws
}
```

One failure records evidence and uses the configured fallback. Two consecutive failures of the same capability trigger local recalibration. A macOS/Qianniu build or major structural digest change triggers full calibration. Candidate activation uses the atomic store validation path. Inject an `onConfirmedDelivery` closure into `NativeAutomationDriver`; invoke it only when `ui.send` returns `.sent`, and route it to `recordEndToEndDelivery`. `.uncertain` and `.failedBeforeSend` must not set `endToEndPassedAt`.

- [ ] **Step 4: Run lifecycle, app, and fault-isolation tests**

Run: `swift test --filter 'ProfileLifecycleTests|AutomationAppModelTests' && swift test && python3 Tests/FaultInjection/long_running_isolation_test.py`

Expected: local failures do not stop unrelated capabilities; rollback remains available.

- [ ] **Step 5: Commit profile lifecycle**

```bash
git add Sources/AutoReplyApp/Autoconfiguration/ProfileLifecycle.swift Sources/AutoReplyApp/Autoconfiguration/FirstRunCoordinator.swift Sources/AutoReplyApp/AutomationAppModel.swift Sources/AutoReplyApp/NativeAutomationDriver.swift Tests/AutoReplyAppTests/ProfileLifecycleTests.swift Tests/AutoReplyAppTests/AutomationAppModelTests.swift Tests/AutoReplyAppTests/NativeAutomationDriverTests.swift
git commit -m "Revalidate and recalibrate machine profiles locally"
```

## Adaptive-Runtime Acceptance Checkpoint

- Current, colleague A, and colleague B structures generate different profiles from one binary.
- A blank section group never creates a customer and never prevents valid rows from returning.
- Window, identity, capture, composer, and send can independently choose AX or fallback.
- Display movement invalidates coordinate mapping only.
- Two repeated failures trigger local recalibration; failed candidates preserve last-known-good.
- Scheduler public interfaces and customer history semantics remain unchanged.
