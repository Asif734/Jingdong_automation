# Qianniu Video Open-Only Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Integrate exact-105 video opening into the universal adaptive Qianniu assistant without changing text/image behavior or allowing a video task to reach Codex/send.

**Architecture:** Extend the OCR media boundary with a typed open-video result and a bounded open-only coordinator. Reuse the existing visual detector and log tail resolver; carry a terminal video disposition through the native driver as a non-generating snapshot. Persist click attempts by message ID so retries and relaunches cannot reopen the same video.

**Tech Stack:** Swift 5.9, Swift Concurrency, AppKit Accessibility, ScreenCaptureKit, CoreGraphics, XCTest.

**Spec:** `docs/superpowers/specs/2026-09-02-video-open-only-integration-design.md`

## Global Constraints

- Only exact `105`/`VIDEO` log evidence may route to video.
- `101`/`IMAGETEXT` stays on the existing visual path.
- One physical click maximum per message ID.
- Ten-second maximum open transaction.
- No download, recording, reply, delete, player dismissal, or global scheduler stop.
- The current text/image/Codex/send behavior must remain unchanged.

---

### Task 1: Typed Media Routing Contract

**Files:**
- Modify: `components/ocr-source/Sources/QianniuOCRAppSupport/AppModel.swift`
- Modify: `components/ocr-source/Sources/QianniuOCRAppSupport/LiveOCRRunner.swift`
- Modify: `Sources/AutoReplyApp/QianniuMediaLogResolver.swift`
- Test: `Tests/AutoReplyAppTests/LiveMediaRoutingTests.swift`
- Test: `components/ocr-source/Tests/QianniuOCRAppSupportTests/LiveOCRRunnerTests.swift`

**Interfaces:**
- Produces `DetectedMediaAction.openVideo(messageID:)` and `OCRMediaDisposition.videoOpened(messageID:)`.
- Preserves `.copy` for every non-105 case.

- [ ] Write failing tests proving exact 105 produces `openVideo`, 101 produces `copy`, and a successful video handler returns a video disposition with no copied image.
- [ ] Run the focused tests and verify failures are caused by missing typed video behavior.
- [ ] Implement the smallest typed routing/result changes.
- [ ] Run the focused tests and verify they pass.
- [ ] Commit the task.

### Task 2: Open-Only Video Transaction

**Files:**
- Create: `components/ocr-source/Sources/QianniuOCRAppSupport/QianniuVideoOpenOnly.swift`
- Test: `components/ocr-source/Tests/QianniuOCRAppSupportTests/QianniuVideoOpenOnlyTests.swift`

**Interfaces:**
- Consumes media boxes, `LocatedPanel`, source image size, event ID, and injected window/pointer/capture dependencies.
- Produces `VideoOpenOutcome.opened`, `.alreadyAttempted`, or `.failedBeforeClick` while durably recording attempted IDs.

- [ ] Write failing tests for bottom-most customer target selection, exact one-click behavior, new Qianniu window verification, post-click dedupe, and no player dismissal.
- [ ] Run the focused tests and verify RED.
- [ ] Implement target mapping, triangle detection, one-click transaction, and atomic attempt journal.
- [ ] Run focused tests and verify GREEN.
- [ ] Commit the task.

### Task 3: Driver and Scheduler Terminal Handling

**Files:**
- Modify: `Sources/AutoReplyApp/LiveNativeUI.swift`
- Modify: `Sources/AutoReplyApp/NativeAutomationDriver.swift`
- Test: `Tests/AutoReplyAppTests/NativeAutomationDriverTests.swift`
- Test: `Tests/AutoReplyCoreTests/SchedulerTests.swift`

**Interfaces:**
- Consumes `OCRMediaDisposition.videoOpened(messageID:)`.
- Produces a stable non-generating `CaptureSnapshot` revision for the video event.

- [ ] Write failing tests proving a video observation creates no generation and the scheduler continues with another customer.
- [ ] Run focused tests and verify RED.
- [ ] Implement terminal snapshot mapping and status messages.
- [ ] Run focused tests and verify GREEN.
- [ ] Commit the task.

### Task 4: Deadlines and Regression Verification

**Files:**
- Modify: `Sources/AutoReplyApp/NativeAutomationDriver.swift`
- Modify: related focused tests only if the public deadline contract changes.

**Interfaces:**
- Enforces a ten-second inner open deadline within the existing twenty-second recognition boundary.

- [ ] Write a failing timeout test proving a hung opener returns and releases the task.
- [ ] Run the focused test and verify RED.
- [ ] Implement the bounded deadline/cancellation path.
- [ ] Run focused tests, component tests, and root `swift test`.
- [ ] Confirm package and app build succeed, then commit.
