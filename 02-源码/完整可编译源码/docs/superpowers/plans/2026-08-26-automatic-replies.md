# Automatic Replies Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Freeze current software and deliver an isolated automatic unread-to-OCR-to-local-CLI-to-send app.

**Architecture:** One main-actor scheduler owns all UI actions; local immutable jobs feed at most five concurrent existing CLI generators. Reuse copied native OCR, unread and sender components; start/stop and durable state are new orchestration, not recognition or answer algorithm changes.

**Tech Stack:** SwiftPM, Swift 5.9/6 interoperability, SwiftUI/AppKit, existing local libraries, JSON snapshots, advisory flock.

**Spec:** docs/superpowers/specs/2026-08-26-automatic-replies.md

## Global Constraints

- Original installed apps and original source must remain unchanged.
- Do not change OCR/parser/image/link algorithms, prompt, model, reasoning effort, knowledge base or sending text logic.
- At most five live CLI processes including cleanup.
- All Qianniu UI operations are serialized; ready sends take priority at safe operation boundaries.
- One active reply per full UID; immutable input; no blind retry after uncertain send.
- Independent root: ~/Desktop/AI客服记录-全自动版. Test recipients: stoneshishininger and tb263147182.
- No direct API credentials, no new login item, no remote publishing; use existing ChatGPT-authenticated CLI.

### Task 1: Durable scheduler and dynamic AI dispatch

**Files:** Create Package.swift, Sources/AutoReplyCore/SchedulerModels.swift, SchedulerStore.swift, AutoReplyScheduler.swift, Tests/AutoReplyCoreTests/SchedulerTests.swift. Local dependency components/batch-source exports CustomerReplyBatchAppSupport and CustomerReplyBatchCore. Core target may import these to reuse PromptInput, ReplyGenerating, GeneratedReply and ReplyEnvelope. No native app calls in tests.

**Interfaces:** Define public @MainActor protocol AutomationDriver with discover() async throws -> [String], capture(uid: String) async throws -> CaptureSnapshot, send(uid: String, text: String) async throws -> DeliveryResult. CaptureSnapshot is Codable/Sendable with uid, customerRevision, historyJSONL, imagePaths, knowledgeBasePaths, hasUnansweredCustomer (Bool), shouldGenerate (Bool). Its promptInput freezes historyJSONL, no historyText. DeliveryResult is sent, failedBeforeSend(String), uncertain(String). Public @MainActor AutoReplyScheduler accepts driver, generator:any ReplyGenerating, store:SchedulerStore, maximumConcurrentGenerations:Int=5, now:()->Date. Expose start(), stop(), async tick(), records/status/events and isRunning. tick is reentrancy-safe; start pumps tick plus bounded polling. State updates observable via onChange callback. Background generation publishes ready reply immediately but retains its live slot until cleanup finishes. Use task handles and generation IDs to reject stale callbacks; stale/restarted results cannot release another job's UID.

- [ ] Write regression tests exercising real scheduler/store, injected controlled driver and generator only for external UI/CLI. The initial compiling baseline can implement signatures returning no work, so failures assert behavior rather than missing symbols.

```swift
func testNewCustomerStartsWhileFirstGenerationIsBlocked() async throws {
    // Controlled generator suspends A; real scheduler must start B before A finishes.
    let f = try Fixture()
    f.driver.unread = ["A"]
    f.scheduler.start()
    await f.waitUntilGenerationStarted("A")
    f.driver.unread = ["B"]
    await f.scheduler.tick()
    await f.waitUntilGenerationStarted("B")
    XCTAssertEqual(f.generator.startedUIDs, ["A", "B"])
    XCTAssertFalse(f.generator.completedUIDs.contains("A"))
    f.scheduler.stop()
}
```

- [ ] Run swift test --filter SchedulerTests and record expected failures before implementing.
- [ ] Implement one persisted record per task plus archived completion, FIFO discovery sequence, active-UID checks, live-slot counter, and a UI pump. In each tick: collect outcomes/refill slots; if ready choose earliest ready, recapture/compare, persist sending, send, persist result; else choose a due discovered UID, persist capture, capture, save frozen input and refill slots; otherwise discover. Never await generator completion in UI pump. Use bounded retry cooldown, keep error visible. Re-read eligible queue each tick, not fixed batch snapshots.
- [ ] Add tests for six+ customers capped at five, cleanup holding slots, duplicate red dots, list reorder FIFO, send priority while capture suspended, A supplements invalidating old reply, service/read-status not creating a task, stop during capture/generation, no-new capture, persistent state restore, sending->uncertain on restart, write failure failing closed, wrong UID rejecting capture and corrupt-state refusal. Fake dependencies must assert target/text and controllable ordering.
- [ ] Run full core suite, commit task and write report including red/green commands, evidence, interfaces, known limits. Do not build or launch actual apps.

### Task 2: Native integration and independent app

**Files:** Add Sources/AutoReplyApp/AutoReplyApplication.swift, NativeAutomationDriver.swift, CapturedHistory.swift, copied NativeSession.swift and WindowCapture.swift from components/unread-source; add Tests/AutoReplyAppTests; modify Package.swift dependencies. Add only a public isolated export adapter to components/ocr-source/Sources/QianniuOCRAppSupport/AutomationCaptureBridge.swift. Do not rewrite existing exporter. Reuse QianniuAXSession and QianniuSendTransaction from components/sender-source.

**Interfaces:** NativeAutomationDriver implements Task 1 AutomationDriver. capture opens uid via existing verified sender search (or fresh unread row), verifies header, runs existing LiveOCRRunner, verifies identity again, exports to injected isolated root with NO old batch trigger, then loads history into immutable CaptureSnapshot. Bridge returns UID, queue entry, history path; all clipboard/capture complete before returning. Capture revision from stable stored customer events, ignoring service/read status and volatile filenames; use content hash for images. shouldGenerate follows existing exporter queued-new-customer decision, with active-task preflight allowed even if export produces no new queue entry. hasUnansweredCustomer reflects latest non-system conversation speaker; unseen service answers invalidate pending AI. Add selected-user polling without requiring red dot. discover uses existing RedDotDetector and ConversationLocator; bounded list scrolling one page per operation, dynamically resolves container. No hardcoded screen coordinates.

**Integration edge cases discovered during baseline inspection:** Sender search can leave the conversation list filtered. Restore the list by dynamically identifying and clearing that search field before unread discovery, without sending or clearing the message composer. The copied NativeSession may change only diagnostic destination and permission app-name text to the new app; record these non-algorithmic deviations. Preserve a durable exporter-to-scheduler handoff: if export committed history/its isolated pending pointer then the app crashed before scheduler snapshot persistence, a retry must recover that pending customer revision, not call it “no new message.” Completed revisions in the scheduler must still suppress replays. Remove/archive the corresponding isolated pending pointer only after verified completion, never an updated pointer for a newer customer revision. Test these paths. Do not import original production pending pointers.

- [ ] Add failing tests for customer revision unchanged by read status/service append, changed by a new customer event, distinct repeated identical messages retaining event identity, image paths not masquerading as new content, snapshots excluding history.txt. Run focused tests, record RED.
- [ ] Implement adapter with stable history event identity and guarded full-UID validation. Persist capture job before UI click via core. Preserve error distinctions. Reuse old source modules directly; main app runs only one UI pump and rejects competing old worker processes. Provide session-scoped flock singleton with no stale directory deadlock. Do not mutate original app preferences or permission DB.
- [ ] Build SwiftUI status with Start/Stop, test-only/all-customer mode, current UI owner, per-customer stage and timing events; default stopped and test-only. Restore jobs on start. Keep window non-activating during automation, never steal focus each tick.
- [ ] Run core plus adapter tests and original component baseline tests. Verify copied algorithm files against freeze. Commit and report; do not install or do manual Computer Use (controller owns UI).

### Task 3: Packaging, end-to-end evidence and rollback

**Files:** Create scripts/build-app.sh, scripts/verify-baseline.py, README.md; packaging Info.plist; evidence logs ignored. Controller performs Computer Use.

- [ ] Validate baseline manifest by SHA256, verify codesign of frozen and installed old apps. Build a separate app named 千牛全自动客服-实验版.app with stable signing identity already present, unique bundle ID com.scy.qianniu-autoreply.scheduler, full offline WebOCR and schema resources. Build arm64 on current host; do not claim untested universal support. Keep previous build recoverably when replacing.
- [ ] Baseline verification must detect changed protected source files, allow only explicit new adapter files. Example acceptance: copy a protected fixture to a temporary tree, change its bytes, verifier exits nonzero; unchanged exits zero. Never mutate real frozen content.
- [ ] Prepare isolated runtime by copying 用户 context only and pointing KB at existing cleaned ZIP. No import of 待处理/待发送/发送中. Archive per-task generated reply JSON/TXT and sender evidence. Document rollback restores old apps, not old queues or histories.
- [ ] Controller uses Computer Use to inspect/close old operators, open new app, inspect permission prompts and handle only authorized actions. If a security-sensitive action requires fresh confirmation, stop that action, report exactly, do not bypass TCC.
- [ ] Controller sends ordinary printer questions from phone Taobao to own shop, starts scheduler once, then observes without manually triggering OCR/AI/send. Record UID, message, discovery, capture, AI start/finish, send/confirmation, buyer arrival, queue completion. Cover changed selected customer, supplements during generation, repeated rounds and second test UID where available. Missing phone access is a real external test blocker, never fabricate passing evidence.
- [ ] Final independent whole-branch review, resolve important issues, full tests/build/signature check, baseline integrity verification. Hand over app, rollback name, actual test counts and any limits. Leave automation stopped unless user explicitly requests continuing live service.
