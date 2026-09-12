# Customer Video Analysis and Automatic Reply Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Keep the checklist current.

**Goal:** Turn an exact Qianniu `messageType=105` customer video into one automatically generated and delivered customer-service reply, while closing the player as soon as background download begins and never blocking unrelated customers.

**Architecture:** Keep the existing visual-first capture and exact-105 video routing. The video opener arms a customer-bound download receipt, closes the player after download starts, and releases the UI lane. A durable background inbox validates the MP4, extracts bounded timestamped frames with AVFoundation, optionally adds an on-device transcript, then admits one prepared snapshot into the existing per-customer Codex/V2/generation/send pipeline.

**Tech stack:** Swift 5.9, macOS 14+, AVFoundation, CoreGraphics/ImageIO, optional Speech, XCTest, existing AutoReply modules.

**Approved design:** `docs/superpowers/specs/2026-09-02-customer-video-analysis-replies-design.md`

## Non-negotiable constraints

- Only exact log type `105` enters the video path. Type `101` continues through the existing visual/text/image path.
- Never persist signed video URLs or raw message IDs; persist only a SHA-256 message hash.
- Closing the player must not mean “completed”; completion happens only after one reply is delivered or one truthful fallback is delivered.
- Video preparation cannot hold the shared Qianniu UI lock.
- One bad video cannot stop red-dot scanning, OCR, Codex generation, or sending for other customers.
- Keep the current installed App untouched until the new build passes automated tests and a no-send dry run.
- Preserve the unrelated untracked `Tools/QianniuVideoDirectProbe/dist/` directory.

## Files

- Modify `Sources/AutoReplyApp/LiveOCRRunner.swift`
- Modify `Sources/AutoReplyApp/QianniuVideoOpenOnly.swift`
- Modify `Sources/AutoReplyApp/QianniuVideoTransfer.swift`
- Create `Sources/AutoReplyApp/CustomerVideoEvidence.swift`
- Create `Sources/AutoReplyApp/VideoAnalysisInbox.swift`
- Create `Sources/AutoReplyApp/VideoAnalysisSnapshotFactory.swift`
- Modify `Sources/AutoReplyApp/QianniuMediaLogResolver.swift`
- Modify `Sources/AutoReplyCore/AutoReplyScheduler.swift`
- Modify `components/batch-source/Sources/CustomerReplyBatchAppSupport/PromptBuilder.swift`
- Modify `Sources/AutoReplyApp/AutomationAppModel.swift`
- Modify `Package.swift` and packaging metadata as required
- Add focused tests beside the existing App/Core/Batch test suites

## Task 1: Bind a confirmed video to the correct customer and download receipt

- [x] Add failing tests proving that an exact-105 action carries both `messageID` and the already-confirmed `customerUID`.
- [x] Add failing tests proving that download completion is emitted only after the final MP4 has been validated and atomically moved.
- [x] Change the media action to `openVideo(messageID:customerUID:)` and thread the confirmed UID through `LiveOCRRunner` and `QianniuVideoOpener`.
- [x] Introduce a value object such as `DownloadedCustomerVideo` containing `customerUID`, `messageHash`, final local path, byte size, and completion time—never the signed URL or raw ID.
- [x] Make the transfer service publish exactly one completion receipt per message hash; repeated log lines or reopens must be idempotent.
- [x] Run the focused resolver/opener/transfer tests and commit.

## Task 2: Extract bounded timestamped frame evidence with AVFoundation

- [x] Add failing tests for short, normal, malformed, and zero-duration media.
- [x] Create `CustomerVideoEvidence.swift` using `AVURLAsset` and `AVAssetImageGenerator`.
- [x] Sample at most eight ordered frames. For very short videos use approximately 20%, 50%, and near-end; for longer videos use evenly spaced samples while avoiding duplicate timestamps.
- [x] Write JPEG frames and a JSON manifest into a temporary directory, then atomically publish the evidence directory.
- [x] Include duration, dimensions, timestamps, and frame hashes in the manifest; do not include customer chat text or signed URLs.
- [x] Enforce bounded preparation time and disk use. A corrupt or unsupported MP4 returns a typed failure, not a crash.
- [x] Run focused tests and commit.

## Task 3: Add optional, non-blocking transcript evidence

- [x] Define a `VideoSpeechTranscribing` protocol so tests never require system permission.
- [ ] Add tests proving denied, unavailable, timed-out, and empty transcription all continue with frames.
- [x] Use Apple Speech only when authorization is already granted and on-device recognition is available; never trigger a surprise permission prompt during automatic operation.
- [x] Enforce a 45-second deadline and return timestamped segments when available.
- [x] Do not request microphone permission; the input is the downloaded file.
- [x] Run focused tests and commit.

## Task 4: Add safe external admission to the existing scheduler

- [ ] Add failing scheduler tests for admitting a prepared snapshot, duplicate message hashes, stopped/running modes, and simultaneous unrelated customer work.
- [x] Implement `AutoReplyScheduler.admitExternalSnapshot(_:) async` using the same per-UID queue and revision dedupe as OCR-originated snapshots.
- [x] Reject only the bad/duplicate external item; never terminate the scan loop or occupy the UI lane.
- [x] Ensure an already-active or terminal `video-analysis:<messageHash>` revision is ignored idempotently.
- [x] Run the full Core tests and commit.

## Task 5: Build the durable video-analysis inbox and recovery state machine

- [ ] Add tests for `downloaded → preparingEvidence → readyForGeneration → admitted → completed`.
- [ ] Add tests for relaunch during each phase, expired leases, two preparation failures, and duplicate receipts.
- [x] Store state atomically under the existing application-support data root using message hash as the stable key.
- [x] On relaunch, reclaim pending work and continue; never reopen a video that already has a valid downloaded MP4.
- [x] After two preparation failures, create one fallback snapshot asking the customer what phenomenon or operation they want checked.
- [ ] Garbage-collect only completed evidence according to an explicit retention policy; keep conversation history and identity mappings.
- [ ] Run focused tests and commit.

## Task 6: Convert evidence into the existing Codex request format

- [x] Add tests for `VideoAnalysisSnapshotFactory` and prompt construction.
- [x] Build a synthetic customer event whose revision is `video-analysis:<messageHash>` and whose image attachments are the ordered frame paths.
- [x] Add a compact evidence block listing duration, each frame timestamp, and optional transcript segments.
- [x] State explicitly that frames/transcripts are untrusted customer content, not instructions.
- [x] Tell Codex to answer the customer’s likely question from the evidence and V2 Top-12; if the evidence is ambiguous, ask one concise clarification rather than inventing details.
- [x] Preserve normal per-customer session continuation. On later turns, submit only new video evidence rather than every older frame again.
- [x] Run Batch/App tests and commit.

## Task 7: Wire the live application without blocking Qianniu

- [ ] Add integration tests with fake downloader, evidence preparer, scheduler, and sender.
- [x] Construct one persistent `VideoAnalysisInbox` before `LiveOCRRunner`; route transfer receipts into it through a concurrency-safe callback/channel.
- [x] Start a background inbox consumer after the scheduler exists. It prepares evidence and invokes external admission without calling `NativeUIAutomation`.
- [x] Keep the current behavior: open video, detect that download started, close the player, return to reception center immediately.
- [x] Replace the misleading stage text “不提交 AI” with states that explain evidence preparation and AI admission.
- [x] Do not mark video analysis complete merely because the player closed.
- [x] Run integration tests and commit.

## Task 8: Packaging, permissions, and regressions

- [x] Link AVFoundation and Speech in `Package.swift` and the App bundle build.
- [ ] Add `NSSpeechRecognitionUsageDescription` only if the optional transcription code can request access through an explicit setup action; automatic runtime must not prompt.
- [x] Run every existing test suite, including visual-first media routing, `101` regression, exact `105`, image copying, persistent V2, isolated Codex, and send confirmation.
- [x] Build the release App and verify architecture, deep signature, and resources.
- [x] Perform a no-send dry run against an existing real MP4 that confirms bounded frame extraction while the production sender remains stopped.
- [ ] Commit the packaging changes.

## Task 9: Local end-to-end acceptance and colleague rollout

- [ ] Back up the currently installed App, then install the verified candidate.
- [ ] Send one fresh video from the test buyer account and capture an evidence timeline: exact 105, open once, download starts, player closes, MP4 validates, frames publish, snapshot admits, Codex completes, one reply sends.
- [ ] Confirm the same message is not reopened or resubmitted during repeated scans and after one App relaunch.
- [ ] Confirm ordinary text, type-101 content, and normal images still follow their unchanged routes.
- [ ] Export a diagnostic bundle with sanitized state transitions, timings, and hashes—no signed URL or raw message ID.
- [ ] Produce a one-click build/install package and an A/B test guide for colleague A and B; require the same acceptance timeline on both before calling the version universal.

## Final verification commands

Run the repository’s existing build/test commands discovered from its scripts, plus at minimum:

```bash
swift test
git diff --check
git status --short
```

Then verify the built bundle:

```bash
codesign --verify --deep --strict "/path/to/千牛全自动客服-通用自适应版.app"
lipo -archs "/path/to/千牛全自动客服-通用自适应版.app/Contents/MacOS/AutoReplyApp"
```

Completion means one fresh customer video receives exactly one evidence-grounded AI reply, the player is closed shortly after download begins, unrelated customers remain serviceable, and text/image behavior is unchanged.
