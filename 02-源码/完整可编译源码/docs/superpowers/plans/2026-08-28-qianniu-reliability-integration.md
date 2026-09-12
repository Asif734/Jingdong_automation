# Qianniu Reliability Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Integrate persistent run intent, bounded uncertain-delivery reconciliation, and portable runtime resources into the existing Qianniu auto-reply app.

**Architecture:** Keep the existing OCR/scheduler/model pipeline intact and add three narrow boundaries: an app-level run-intent controller, a scheduler-level delivery reconciler driven by read-only evidence, and a single runtime resource resolver used by capture, retrieval, and startup validation. Existing persisted scheduler data remains backward compatible.

**Tech Stack:** Swift 5.9, SwiftUI/AppKit, XCTest, Foundation, zsh packaging, Python 3.12 runtime bundle.

**Spec:** `docs/superpowers/specs/2026-08-28-qianniu-reliability-integration-design.md`

## Global Constraints

- Do not alter OCR recognition, red-dot detection, customer identity classification, FIFO ordering, Prompt text, model, or V2 Top-12 ranking.
- Do not delete, rotate, truncate, or reduce existing logs.
- Do not install or replace `/Applications/千牛全自动客服-实验版.app` until all automated and packaging checks pass.
- Preserve schema-3 scheduler compatibility.
- Every behavior change follows red-green TDD.

---

### Task 1: Portable Runtime Resources and Strict Retrieval

**Files:**
- Create: `Sources/AutoReplyApp/PortableRuntimeResources.swift`
- Modify: `Sources/AutoReplyApp/AutomationAppModel.swift`
- Modify: `Sources/AutoReplyApp/CapturedHistory.swift`
- Modify: `components/batch-source/Sources/CustomerReplyBatchAppSupport/V2KnowledgeRetriever.swift`
- Modify: `components/batch-source/Sources/CustomerReplyBatchAppSupport/CodexReplyGenerator.swift`
- Modify: `scripts/build-app.sh`
- Test: `Tests/AutoReplyAppTests/PortableRuntimeResourcesTests.swift`
- Test: `Tests/AutoReplyAppTests/CapturedHistoryTests.swift`
- Test: `components/batch-source/Tests/CustomerReplyBatchAppSupportTests/V2KnowledgeRetrieverTests.swift`

**Interfaces:**
- Produces: `PortableRuntimeResources.resolve(bundle:applicationSupportURL:fileManager:) throws -> PortableRuntimeResources`.
- Produces: `KnowledgeRetrievalFailurePolicy.failClosed` for the live generator; existing callers retain their explicit/default compatibility policy.
- Consumes: bundle-relative `Python.framework/Versions/3.12/bin/python3.12`, `V2Knowledge`, `KnowledgeBase/Grozziie-China-KB.zip`, and ordered Codex candidates.

- [ ] Write failing tests proving bundle-relative Python/knowledge resources resolve, missing components identify the exact blocker, `CapturedHistory` uses injected portable knowledge paths, and fail-closed retrieval never submits the full ZIP fallback.
- [ ] Run the focused Swift tests and confirm they fail for missing interfaces/current fallback behavior.
- [ ] Implement the resolver, inject its paths into `CapturedHistory`, `V2KnowledgeRetriever`, and `CodexReplyGenerator`, and make live startup fail closed.
- [ ] Update `build-app.sh` to bundle and verify Python framework plus knowledge-base seed using configurable build-source inputs without runtime `/Users/scy` paths.
- [ ] Run focused tests, V2 Python tests, and a temporary-output package build; inspect the built app for required resources and forbidden fixed runtime paths.

### Task 2: Persistent Run Intent and Relaunch Resume

**Files:**
- Create: `Sources/AutoReplyApp/AutomationRunIntent.swift`
- Modify: `Sources/AutoReplyApp/AutomationAppModel.swift`
- Test: `Tests/AutoReplyAppTests/AutomationRunIntentTests.swift`
- Test: `Tests/AutoReplyAppTests/AutomationAppModelTests.swift`

**Interfaces:**
- Produces: `AutomationRunIntent`, `AutomationRunIntentStore`, and `StartRetryPolicy`.
- `AutomationAppModel.start()` persists `.running`; `stop()` persists `.stopped`; initialization restores mode/aliases and schedules a bounded retry loop when desired state is running.

- [ ] Write failing tests for atomic run-intent round trip, stopped relaunch, running relaunch, transient start-check preservation, and `1,2,5,10,30,30` retry delays.
- [ ] Run focused tests and confirm failures reflect absent behavior.
- [ ] Implement the store and pure retry policy, then wire explicit start/stop and relaunch recovery into `AutomationAppModel` with injectable sleep for deterministic tests.
- [ ] Re-run focused tests and confirm manual stop cancels pending retries and remains stopped after reconstruction.

### Task 3: Bounded Delivery Reconciliation

**Files:**
- Modify: `Sources/AutoReplyCore/SchedulerModels.swift`
- Modify: `Sources/AutoReplyCore/AutoReplyScheduler.swift`
- Modify: `Sources/AutoReplyApp/NativeAutomationDriver.swift`
- Modify: `Sources/AutoReplyApp/LiveNativeUI.swift`
- Modify: `Sources/AutoReplyCore/SchedulerStore.swift`
- Test: `Tests/AutoReplyCoreTests/SchedulerTests.swift`
- Test: `Tests/AutoReplyCoreTests/SchedulerStoreTests.swift`
- Test: `Tests/AutoReplyAppTests/NativeAutomationDriverTests.swift`

**Interfaces:**
- Adds: `AutomationDriver.reconcile(uid:replyText:after:) async throws -> DeliveryObservation`.
- Adds: optional persisted `deliveryStableMisses` and `deliveryResendIssued` fields with decode defaults.
- Produces actions equivalent to `confirmSent`, `wait`, `resendOriginal`, and `releaseUnknown`.

- [ ] Write failing scheduler tests for exact confirmation, unreadable evidence not counting, three stable misses causing one resend, post-resend exhaustion releasing the UID/cursor, and restart recovery from `.sending`.
- [ ] Run focused tests and confirm current permanent-quarantine behavior fails the new expectations.
- [ ] Add backward-compatible record fields and the read-only evidence interface; parse only exact service-authored reply text from captured JSONL.
- [ ] Integrate reconciliation priority into `tick()`, preserve ready-send priority, and route the single resend through the existing sender transaction.
- [ ] Re-run focused scheduler, store, and native-driver tests.

### Task 4: Full Verification and Packaging Boundary

**Files:**
- Verify only; no log cleanup.

- [ ] Run `swift test` at the project root and confirm zero failures.
- [ ] Run `swift test` in each modified component package and confirm zero failures.
- [ ] Run `python3 -m unittest discover -s Tests/V2KnowledgePythonTests -p 'test_*.py' -v`.
- [ ] Build a fresh app to a temporary output directory and run `codesign --verify --deep --strict`.
- [ ] Confirm the installed app hash remains `a97db509175df3628b5ac3927af195d44fe6c65ce336cdb369ba32943158b0fd` until an explicit installation step.
- [ ] Inspect `git diff --check`, changed-file scope, packaged resources, and log directories; verify issue 8 remains untouched.
