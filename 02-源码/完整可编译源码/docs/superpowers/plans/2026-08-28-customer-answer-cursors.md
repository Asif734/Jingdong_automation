# Customer Answer Cursors Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Guarantee that every customer text, image, and link belongs to exactly one frozen reply batch, even when later customer messages arrive before an earlier generated reply is sent.

**Architecture:** Replace visible-speaker inference with a durable per-UID answered cursor over the canonical ordered customer-event stream. Each scheduler task freezes `(startCursor, endCursor]`, sends that reply before later batches, advances the cursor only after verified delivery, and immediately captures any tail beyond the new cursor without waiting for another unread dot.

**Tech Stack:** Swift 5.9, Swift Concurrency/MainActor, Codable JSON checkpoints, CryptoKit SHA-256, XCTest, macOS 14 AppKit/Accessibility automation.

**Spec:** `docs/superpowers/specs/2026-08-28-customer-answer-cursor-design.md`

## Global Constraints

- Do not rewrite OCR parsing, media-copy, link-resolution, knowledge-base, model-selection, sender-location, or Qianniu foreground algorithms.
- Only a scheduler task with `deliveryOutcome == .sent` advances a customer's answered cursor.
- Red dots and visible service messages never advance the cursor.
- Existing customer histories and images under `/Users/scy/Desktop/AI客服记录-全自动版/用户` must remain untouched during implementation and automated tests.
- Preserve per-user Codex session reuse and current generation concurrency behavior.
- Preserve the installed app until the complete automated suite and signed output verification pass.

---

### Task 1: Define cursor and frozen-target data contracts

**Files:**
- Modify: `Sources/AutoReplyCore/SchedulerModels.swift`
- Modify: `components/batch-source/Sources/CustomerReplyBatchAppSupport/PromptBuilder.swift`
- Test: `Tests/AutoReplyCoreTests/SchedulerStoreTests.swift`
- Test: `components/batch-source/Tests/CustomerReplyBatchAppSupportTests/PromptBuilderTests.swift`

**Interfaces:**
- Produces: `CustomerCursor(count:digest:)`, `CaptureSnapshot.startCursor`, `CaptureSnapshot.endCursor`, `CaptureSnapshot.targetCustomerJSONL`, and `PromptInput.targetCustomerJSONL`.
- Compatibility: new snapshot fields decode with `nil` for archived schema-2 evidence; schema-3 active records will require non-nil boundaries in Task 4.

- [ ] **Step 1: Write failing cursor and prompt-contract tests**

Add a model round-trip test that encodes and decodes:

```swift
let start = CustomerCursor.empty
let end = CustomerCursor(count: 2, digest: String(repeating: "a", count: 64))
let snapshot = CaptureSnapshot(
    uid: "buyer",
    customerRevision: end.digest,
    historyJSONL: "full-history\n",
    targetCustomerJSONL: "{\"sender\":\"customer\",\"v\":\"B\"}\n",
    startCursor: start,
    endCursor: end,
    hasUnansweredCustomer: true,
    shouldGenerate: true
)
let decoded = try JSONDecoder().decode(
    CaptureSnapshot.self,
    from: JSONEncoder().encode(snapshot)
)
XCTAssertEqual(decoded.startCursor, start)
XCTAssertEqual(decoded.endCursor, end)
XCTAssertEqual(decoded.targetCustomerJSONL, snapshot.targetCustomerJSONL)
```

Add a prompt test asserting that the full history and frozen target are both present in separate labeled sections and that the target instruction says only the frozen batch is answered.

- [ ] **Step 2: Run the focused tests and verify failure**

Run:

```bash
swift test --filter SchedulerStoreTests
swift test --package-path components/batch-source --filter PromptBuilderTests
```

Expected: compilation fails because `CustomerCursor`, cursor fields, and `targetCustomerJSONL` do not exist.

- [ ] **Step 3: Add backward-compatible data types**

Add:

```swift
public struct CustomerCursor: Codable, Equatable, Hashable, Sendable {
    public let count: Int
    public let digest: String
    public static let empty = CustomerCursor(count: 0, digest: String(repeating: "0", count: 64))

    public init(count: Int, digest: String) {
        self.count = count
        self.digest = digest
    }
}
```

Extend `CaptureSnapshot` with optional cursor fields for archive decoding and a nonoptional `targetCustomerJSONL` defaulting to an empty string in custom decoding. Extend `PromptInput` with `targetCustomerJSONL`, and have `CaptureSnapshot.promptInput` pass it through. Keep `customerRevision` as the compatibility alias for `endCursor.digest` in all new snapshots.

- [ ] **Step 4: Separate full context from the frozen target in prompts**

Render:

```text
full_history.jsonl:
<complete history>

target_customer_batch.jsonl:
<only events in (startCursor, endCursor]>
```

Change both initial and continuation prompt rules to state that only `target_customer_batch.jsonl` is answered and later messages outside that batch cannot cancel or rewrite the reply.

- [ ] **Step 5: Run focused tests and commit**

Run the two Step 2 commands. Expected: PASS.

Commit:

```bash
git add Sources/AutoReplyCore/SchedulerModels.swift \
  Tests/AutoReplyCoreTests/SchedulerStoreTests.swift \
  components/batch-source/Sources/CustomerReplyBatchAppSupport/PromptBuilder.swift \
  components/batch-source/Tests/CustomerReplyBatchAppSupportTests/PromptBuilderTests.swift
git commit -m "feat: define frozen customer batch cursors"
```

---

### Task 2: Build a canonical customer-event timeline

**Files:**
- Create: `Sources/AutoReplyApp/CustomerEventTimeline.swift`
- Create: `Tests/AutoReplyAppTests/CustomerEventTimelineTests.swift`
- Modify: `Sources/AutoReplyApp/CapturedHistory.swift`
- Modify: `Tests/AutoReplyAppTests/CapturedHistoryTests.swift`

**Interfaces:**
- Consumes: `CustomerCursor` from Task 1 and existing stored `history.jsonl` events.
- Produces: `CustomerEventTimeline.currentCursor`, `containsPrefix(_:)`, and `batch(after:) -> CustomerEventBatch` where `CustomerEventBatch` exposes `startCursor`, `endCursor`, `targetJSONL`, and target image paths.

- [ ] **Step 1: Write failing timeline tests**

Cover these exact cases:

```swift
func testServiceReplyAfterBCDoesNotMoveCustomerCursor() throws
func testBatchAfterACursorContainsOnlyBandC() throws
func testRepeatedIdenticalCustomerTextHasTwoCursorPositions() throws
func testImageCursorUsesBytesNotFilename() throws
func testNonPrefixCursorIsRejected() throws
```

For the A/B/C regression, build history in this order:

```text
customer A
customer B
customer C
service answer-A
```

Assert `batch(after: cursorA)` targets B and C despite the final service event.

- [ ] **Step 2: Run the focused tests and verify failure**

Run:

```bash
swift test --filter CustomerEventTimelineTests
swift test --filter CapturedHistoryTests
```

Expected: compilation fails because `CustomerEventTimeline` and cursor-aware capture are absent.

- [ ] **Step 3: Implement the timeline as a focused unit**

Move the existing canonical customer-identity projection out of `CapturedHistory.customerRevision` into `CustomerEventTimeline`. Compute each prefix digest as a SHA-256 chain over the previous digest and the sorted-key JSON encoding of the next identity:

```swift
nextDigest = sha256(Data(previous.digest.utf8) + encodedIdentity)
nextCursor = CustomerCursor(count: previous.count + 1, digest: nextDigest)
```

`containsPrefix` must verify both count and digest. `batch(after:)` must reject non-prefix cursors and return only customer events after the cursor, preserving source order. Image identities continue to use bytes read through the existing safe `images/` path resolver.

- [ ] **Step 4: Make `CapturedHistory.snapshot` cursor-aware**

Change the entry point to:

```swift
func snapshot(
    uid: String,
    latestSpeaker: String?,
    newlyQueued: Bool,
    after answeredCursor: CustomerCursor
) throws -> CaptureSnapshot
```

Construct the snapshot from `timeline.batch(after: answeredCursor)`. Set:

```swift
hasUnansweredCustomer = batch.endCursor != batch.startCursor
shouldGenerate = hasUnansweredCustomer
customerRevision = batch.endCursor.digest
```

Do not use `latestSpeaker` to decide whether the target exists. Keep it only as observed diagnostic input until all callers migrate. Attach only image paths belonging to the returned target batch.

- [ ] **Step 5: Run focused tests and commit**

Run the Step 2 commands. Expected: PASS.

Commit:

```bash
git add Sources/AutoReplyApp/CustomerEventTimeline.swift \
  Sources/AutoReplyApp/CapturedHistory.swift \
  Tests/AutoReplyAppTests/CustomerEventTimelineTests.swift \
  Tests/AutoReplyAppTests/CapturedHistoryTests.swift
git commit -m "feat: derive reply batches from customer cursors"
```

---

### Task 3: Queue new customer evidence regardless of visible service tail

**Files:**
- Modify: `components/ocr-source/Sources/QianniuOCRAppSupport/CustomerRequestPackageExporter.swift`
- Test: `components/ocr-source/Tests/QianniuOCRAppSupportTests/CustomerRequestPackageExporterTests.swift`

**Interfaces:**
- Consumes: existing `hasNewCustomerRequest`, incremental-message detection, and exact history pointer format.
- Produces: a refreshed per-UID pending pointer whenever new customer evidence is committed, even if the last visible speaker is service.

- [ ] **Step 1: Write the failing A/B/C plus answer-A exporter test**

Perform two exports. The first commits customer A and creates a queue pointer. The second visible window contains A, B, C, then service answer-A. Assert:

```swift
let queue = try XCTUnwrap(try JSONSerialization.jsonObject(
    with: Data(contentsOf: pendingURL)
) as? [String: Any])
XCTAssertNotEqual(queue["history_version"] as? String, firstHistoryVersion)
XCTAssertTrue(try String(contentsOf: historyURL).contains("\"v\":\"B\""))
XCTAssertTrue(try String(contentsOf: historyURL).contains("\"v\":\"C\""))
```

- [ ] **Step 2: Run the focused test and verify failure**

Run:

```bash
swift test --package-path components/ocr-source --filter CustomerRequestPackageExporterTests
```

Expected: FAIL because `shouldQueue` is false when `latestVisibleSpeaker == "service"`.

- [ ] **Step 3: Remove service-tail authority from queuing**

Replace the visible-speaker gate with:

```swift
let shouldQueue = hasNewCustomerRequest
```

Keep all existing incremental-message, old-image, link, timestamp, identity, atomic-write, and queue-trigger code unchanged.

- [ ] **Step 4: Run component tests and commit**

Run:

```bash
swift test --package-path components/ocr-source --filter CustomerRequestPackageExporterTests
swift test --package-path components/ocr-source
```

Expected: PASS.

Commit:

```bash
git add components/ocr-source/Sources/QianniuOCRAppSupport/CustomerRequestPackageExporter.swift \
  components/ocr-source/Tests/QianniuOCRAppSupportTests/CustomerRequestPackageExporterTests.swift
git commit -m "fix: retain customer queue behind service replies"
```

---

### Task 4: Persist and migrate per-UID answered cursors

**Files:**
- Modify: `Sources/AutoReplyCore/SchedulerModels.swift`
- Modify: `Sources/AutoReplyCore/SchedulerStore.swift`
- Test: `Tests/AutoReplyCoreTests/SchedulerStoreTests.swift`

**Interfaces:**
- Consumes: `CustomerCursor` and optional task boundaries from Task 1.
- Produces: schema-3 `SchedulerPersistentState.answeredCursors: [String: CustomerCursor]`, schema-2 migration, and schema-3 validation.

- [ ] **Step 1: Write failing persistence and migration tests**

Add tests for:

```swift
func testSchemaThreePersistsAnsweredCursorAcrossRestart() throws
func testSchemaTwoMigratesLatestVerifiedSentRevisionPrefix() throws
func testMigrationBaselinesIdleUIDWithoutPendingWork() throws
func testSchemaThreeRejectsOverlappingActiveRangesForSameUID() throws
func testConfirmedSendCursorCannotMoveBackward() throws
```

Use a migration callback injected into `SchedulerStore` to resolve old customer revisions against the current history without reading live history from the scheduling pump.

- [ ] **Step 2: Run focused tests and verify failure**

Run:

```bash
swift test --filter SchedulerStoreTests
```

Expected: FAIL because only schema 2 is accepted and no answered cursor is persisted.

- [ ] **Step 3: Add schema-3 state and explicit migration**

Change the persistent model to decode missing dictionaries as empty:

```swift
public var schemaVersion: Int = 3
public var answeredCursors: [String: CustomerCursor]
```

Make `SchedulerStore` accept schema 2 only through a dedicated migration path. Migration must:

1. resolve the latest `.completed` + `.sent` customer revision that is a valid current-history prefix;
2. baseline an idle UID at current history only when no active record and no pending pointer exists;
3. throw a UID-specific migration error when active work exists but no start prefix can be proven;
4. write schema 3 atomically before normal scheduling starts.

Do not rewrite immutable schema-2 archives. Their optional cursor fields remain nil and checksum verification remains valid.

- [ ] **Step 4: Add schema-3 validation**

Validate cursor count, 64-character lowercase hexadecimal digest, active task start/end presence, `start.count <= end.count`, and at most one active frozen range per UID. Preserve all current archive and delivery-outcome validation.

- [ ] **Step 5: Run focused tests and commit**

Run `swift test --filter SchedulerStoreTests`. Expected: PASS.

Commit:

```bash
git add Sources/AutoReplyCore/SchedulerModels.swift \
  Sources/AutoReplyCore/SchedulerStore.swift \
  Tests/AutoReplyCoreTests/SchedulerStoreTests.swift
git commit -m "feat: persist per-customer answered cursors"
```

---

### Task 5: Schedule, send, and advance exact frozen ranges

**Files:**
- Modify: `Sources/AutoReplyCore/AutoReplyScheduler.swift`
- Modify: `Sources/AutoReplyCore/SchedulerModels.swift`
- Modify: `Sources/AutoReplyApp/NativeAutomationDriver.swift`
- Modify: `Sources/AutoReplyApp/AutomationAppModel.swift`
- Test: `Tests/AutoReplyCoreTests/SchedulerTests.swift`
- Test: `Tests/AutoReplyAppTests/NativeAutomationDriverTests.swift`
- Test: `Tests/AutoReplyAppTests/AutomationAppModelTests.swift`

**Interfaces:**
- Consumes: answered cursors from Task 4 and cursor-aware capture from Task 2.
- Produces: `AutomationDriver.capture(uid:after:)`, `captureBeforeDelivery(uid:after:)`, exact range scheduling, atomic sent-cursor advancement, and immediate tail capture.

- [ ] **Step 1: Write failing interleaving tests**

Add deterministic scheduler tests for:

```swift
func testAnswerAThenAutomaticallyGenerateBandCWithoutAnotherRedDot() async throws
func testServiceAnswerAAfterBandCDoesNotCompleteBandC() async throws
func testDWaitsBehindFrozenBandCReply() async throws
func testReadyReplySendsBeforeCapturingLaterTail() async throws
func testSendFailureDoesNotAdvanceAnsweredCursor() async throws
func testUncertainSendDoesNotAdvanceAnsweredCursor() async throws
func testRestartResumesFrozenRangeAndLaterTailExactlyOnce() async throws
```

The primary assertion is:

```swift
XCTAssertEqual(sentTexts, ["answer-A", "answer-B+C", "answer-D"])
XCTAssertEqual(storeState.answeredCursors["buyer"], cursorD)
XCTAssertFalse(driver.operations.contains("discover-required-for-B+C"))
```

- [ ] **Step 2: Run focused tests and verify failure**

Run:

```bash
swift test --filter SchedulerTests
swift test --filter NativeAutomationDriverTests
swift test --filter AutomationAppModelTests
```

Expected: compilation or assertions fail because capture has no cursor argument and delivery uses `latestSpeaker`/revision inference.

- [ ] **Step 3: Pass cursor boundaries through the driver**

Change the protocol and native driver methods to:

```swift
func capture(uid: String, after cursor: CustomerCursor) async throws -> CaptureSnapshot
func captureBeforeDelivery(uid: String, after cursor: CustomerCursor) async throws -> CaptureSnapshot
```

Initial capture uses `answeredCursors[uid] ?? .empty`. Pre-send capture uses the ready task's `endCursor`, so its returned target can contain only later messages.

- [ ] **Step 4: Freeze and queue only uncovered tails**

When capture returns a nonempty target, require:

```swift
snapshot.startCursor == persistent.answeredCursors[uid]
snapshot.endCursor.count > snapshot.startCursor.count
```

If a task for that UID already covers the same end cursor, coalesce the observation. Never replace a generating or ready task with a later snapshot.

- [ ] **Step 5: Advance cursor atomically with verified delivery**

For `.sent`, perform one scheduler-store commit that:

```swift
record.state = .completed
record.deliveryOutcome = .sent
state.answeredCursors[uid] = original.endCursor
```

Then append a `.discovered` follow-up record immediately when pre-send capture observed a later end cursor. The follow-up capture starts after the newly stored answered cursor. For `.failedBeforeSend` and `.uncertain`, leave the cursor unchanged.

- [ ] **Step 6: Acknowledge pending pointers by exact sent end cursor**

Update `AutomationAppModel.refresh` to call `CapturedHistory.complete` with the sent task's `endCursor.digest`, never a later supplement revision. A newer pointer must remain present and drive the follow-up task.

- [ ] **Step 7: Run focused tests and commit**

Run the Step 2 commands. Expected: PASS.

Commit:

```bash
git add Sources/AutoReplyCore/AutoReplyScheduler.swift \
  Sources/AutoReplyCore/SchedulerModels.swift \
  Sources/AutoReplyApp/NativeAutomationDriver.swift \
  Sources/AutoReplyApp/AutomationAppModel.swift \
  Tests/AutoReplyCoreTests/SchedulerTests.swift \
  Tests/AutoReplyAppTests/NativeAutomationDriverTests.swift \
  Tests/AutoReplyAppTests/AutomationAppModelTests.swift
git commit -m "fix: deliver every frozen customer batch in order"
```

---

### Task 6: Prove full regression safety and package the experimental app

**Files:**
- Modify: `Tests/AutoReplyCoreTests/SchedulerTests.swift`
- Modify: `Tests/AutoReplyAppTests/CapturedHistoryTests.swift`
- Modify: `components/batch-source/Tests/CustomerReplyBatchAppSupportTests/PerUserSessionIntegrationTests.swift`
- Modify: `components/ocr-source/Tests/QianniuOCRAppSupportTests/CustomerRequestPackageExporterTests.swift`
- Modify: `README.md`

**Interfaces:**
- Consumes: all preceding tasks.
- Produces: exhaustive interleaving evidence, component regression evidence, signed arm64 experimental app output, and an operator-visible explanation of cursor status.

- [ ] **Step 1: Add a table-driven interleaving regression**

Exercise customer B/C/D arrival at each scheduler await boundary: capture, generation, pre-send capture, send start, send completion, and follow-up capture. For every permutation assert:

```swift
XCTAssertEqual(allTargetEventIDs.sorted(), ["event-A", "event-B", "event-C", "event-D"])
XCTAssertEqual(Set(allTargetEventIDs).count, 4)
XCTAssertEqual(sentBatchOrder, expectedBatchOrder)
```

Include text, link, image, repeated identical text, and app-restart variants.

- [ ] **Step 2: Run all Swift and baseline tests**

Run:

```bash
swift test
swift test --package-path components/batch-source
swift test --package-path components/ocr-source
swift test --package-path components/sender-source
swift test --package-path components/unread-source
python3 scripts/verify-baseline.py --self-test
python3 -m unittest Tests/Packaging/verify_baseline_test.py Tests/BaselineScriptsTests/freeze_per_user_session_baseline_test.py
```

Expected: all commands exit 0 with zero test failures. Existing frozen apps and protected source hashes remain unchanged.

- [ ] **Step 3: Update operator documentation**

Document that the progress view's completed cursor means “last customer batch confirmed sent,” that later observed messages are scheduled without a red dot, and that visible service messages do not clear a customer tail.

- [ ] **Step 4: Build and verify signed output without installing**

Run:

```bash
scripts/build-app.sh
plutil -lint output/千牛全自动客服-实验版.app/Contents/Info.plist
codesign --verify --deep --strict --verbose=2 output/千牛全自动客服-实验版.app
```

Expected: release build succeeds, plist is valid, signature verification succeeds, and the installed app remains unchanged.

- [ ] **Step 5: Commit verified implementation**

```bash
git add Tests README.md
git commit -m "test: prove exact customer batch delivery"
```

- [ ] **Step 6: Install only after explicit live-QA checkpoint**

Quit the currently installed experimental app and wait for its process to exit. Preserve the installed bundle as a timestamped recoverable backup, install the fully signed output as a whole bundle, reopen it, and verify permissions remain effective. Never overwrite or re-sign a running executable.

- [ ] **Step 7: Run controlled live A/B/C/D validation**

Using only the user's authorized test accounts, run the five scenarios from the design spec. Record scheduler task IDs, frozen target batches, send results, and final cursors. Acceptance requires A, B+C, and D to send in order without a new red dot being needed for B+C.
