# Visual-First Qianniu Media Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add exact `messageId`-based image/video routing to the universal adaptive auto-reply app while preserving every existing text, image, link, OCR, retrieval, Codex, and send fallback.

**Architecture:** A persistent incremental log resolver lives in `AutoReplyApp`, while `LiveOCRRunner` gains a narrow pre-copy media gate. Visual detection remains authoritative for deciding whether media exists; the log resolver only selects `copy` or `ignore` after a visual media candidate exists. Unknown or failed log evidence always degrades to the existing image path.

**Tech Stack:** Swift 5.9, Swift Concurrency actors, Foundation file APIs, CryptoKit SHA-256, XCTest, SwiftPM.

**Spec:** `docs/superpowers/specs/2026-09-01-visual-log-media-routing-design.md`

## Global Constraints

- Base all work on colleague B baseline plus the universal adaptive branch; never modify version A.
- Do not download or delete customer video in this release.
- Do not call the media log resolver for text-only captures.
- Never suppress an image unless an exact, unambiguous `messageId` resolves to `messageType=105` for the same customer.
- A missing or broken log must preserve the existing image workflow.
- Persist only hashes and structural status, never raw log lines, customer text, images, credentials, or original UID.

---

### Task 1: Persistent exact-message log resolver

**Files:**
- Create: `Sources/AutoReplyApp/QianniuMediaLogResolver.swift`
- Test: `Tests/AutoReplyAppTests/QianniuMediaLogResolverTests.swift`

**Interfaces:**
- Produces: `protocol VisualMediaTypeResolving: Sendable { func resolve(customerUID: String, now: Date) async -> VisualMediaResolution }`
- Produces: `enum VisualMediaResolution { case copyImage(messageID: String?); case ignoreVideo(messageID: String) }`

- [ ] **Step 1: Write failing parser and persistence tests**

Cover exact 101, exact 105, mismatched message IDs, different customer UID, conflicting markers, partial lines, rotation, and restart persistence. Each expected outcome is a literal enum value.

- [ ] **Step 2: Verify RED**

Run: `swift test --filter QianniuMediaLogResolverTests`  
Expected: compilation fails because `QianniuMediaLogResolver` and its public behavior do not exist.

- [ ] **Step 3: Implement the minimum resolver**

Implement incremental file state, exact-ID aggregation, recent same-UID selection, SHA-256 journal entries, atomic JSON persistence and a 10,000-entry bound. Return `copyImage(nil)` on all unavailable/ambiguous paths.

- [ ] **Step 4: Verify GREEN**

Run: `swift test --filter QianniuMediaLogResolverTests`  
Expected: all resolver tests pass with no unexpected output.

- [ ] **Step 5: Commit**

```bash
git add Sources/AutoReplyApp/QianniuMediaLogResolver.swift Tests/AutoReplyAppTests/QianniuMediaLogResolverTests.swift
git commit -m "Add exact Qianniu media log routing"
```

### Task 2: Gate image copying after visual detection

**Files:**
- Modify: `components/ocr-source/Sources/QianniuOCRAppSupport/LiveOCRRunner.swift`
- Modify: `components/ocr-source/Tests/QianniuOCRAppSupportTests/RefreshWorkflowTests.swift`

**Interfaces:**
- Produces: `public enum DetectedMediaAction: Sendable { case copy; case ignore }`
- Produces overload: `run(includeImages:mediaAction:stage:)`

- [ ] **Step 1: Write failing behavioral tests**

One test supplies a visual box and `.ignore`, then asserts the image copy resolver call count is zero and result images are empty. A second supplies `.copy` and asserts the existing resolver output is preserved. A text-only test asserts the callback is never invoked.

- [ ] **Step 2: Verify RED**

Run: `swift test --package-path components/ocr-source --filter RefreshWorkflowTests`  
Expected: compilation fails because the media-action overload does not exist.

- [ ] **Step 3: Implement the pre-copy gate**

Invoke the async gate only after visual boxes are computed and before `ImageCopyResolving.resolve`. `.ignore` returns an `OCRRunResult` with the recognized text/links and zero images. The existing overload passes an always-copy closure.

- [ ] **Step 4: Verify GREEN**

Run: `swift test --package-path components/ocr-source --filter RefreshWorkflowTests`  
Expected: all workflow tests pass.

- [ ] **Step 5: Commit**

```bash
git add components/ocr-source/Sources/QianniuOCRAppSupport/LiveOCRRunner.swift components/ocr-source/Tests/QianniuOCRAppSupportTests/RefreshWorkflowTests.swift
git commit -m "Gate media copy after visual detection"
```

### Task 3: Connect the resolver to the full auto-reply UI

**Files:**
- Modify: `Sources/AutoReplyApp/LiveNativeUI.swift`
- Modify: `Sources/AutoReplyApp/AutomationAppModel.swift`
- Modify: `Sources/AutoReplyApp/NativeAutomationDriver.swift`
- Modify: `Tests/AutoReplyAppTests/NativeAutomationDriverTests.swift`
- Create: `Tests/AutoReplyAppTests/LiveMediaRoutingTests.swift`

**Interfaces:**
- `NativeUIAutomation.recognize(uid:includeImages:lease:stage:)`
- `LiveNativeUI.init(..., mediaTypeResolver: any VisualMediaTypeResolving)`

- [ ] **Step 1: Write failing integration tests**

Verify the driver forwards the exact UID into recognition. Verify video resolution returns `.ignore` before the image copy resolver and image/unknown returns `.copy`. Verify `includeImages=false` bypasses media routing.

- [ ] **Step 2: Verify RED**

Run: `swift test --filter 'NativeAutomationDriverTests|LiveMediaRoutingTests'`  
Expected: compilation failure at the old recognition interface.

- [ ] **Step 3: Wire the live assembly**

Construct the resolver from the two Aliworkbench log URLs and `运行状态/媒体路由/processed-events.json`. Forward the currently routed UID. Record a structured stage for ignored video, but do not create a reply request.

- [ ] **Step 4: Verify GREEN**

Run: `swift test --filter 'NativeAutomationDriverTests|LiveMediaRoutingTests'`  
Expected: all selected tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AutoReplyApp Tests/AutoReplyAppTests
git commit -m "Integrate video ignore routing into auto reply"
```

### Task 4: Restore portable unread evidence fixtures

**Files:**
- Restore: `components/unread-source/evidence/2026-08-26-105614-red-dot.jpeg`
- Restore: `components/unread-source/evidence/2026-08-26-105941-no-red-dot.jpeg`

**Interfaces:** Existing `UnreadCoreTests.fixture(_:)` reads these package-local files.

- [ ] **Step 1: Confirm the current failures**

Run: `swift test --package-path components/unread-source --filter 'testRealScreenshotRedDotOnly|testRealNoDotAvatarAndGlobalBadgeAreExcluded'`  
Expected: two failures because `CGImageSourceCreateWithURL` receives missing files.

- [ ] **Step 2: Restore the exact historical evidence bytes**

Copy the two immutable fixtures from the frozen version A evidence folder. Compare SHA-256 with all other historical copies before committing.

- [ ] **Step 3: Verify GREEN**

Run the same filtered command.  
Expected: both tests pass.

- [ ] **Step 4: Commit**

```bash
git add components/unread-source/evidence
git commit -m "Restore portable unread screenshot fixtures"
```

### Task 5: Full regression and distribution package

**Files:**
- Modify: `docs/千牛通用自适应版-首次安装与真机验收.md`
- Generate: `build-output/千牛全自动客服-通用自适应版.dmg`
- Generate: `build-output/千牛全自动客服-通用自适应版.dmg.sha256.txt`

**Interfaces:** The installer payload remains arm64 and keeps the universal adaptive bundle identifier.

- [ ] **Step 1: Run all Swift suites**

Run root plus `batch-source`, `ocr-source`, `sender-source`, and `unread-source` test suites.  
Expected: zero failures; documented skips only.

- [ ] **Step 2: Run Python, A/B fixture and packaging tests**

Run all `Tests/**/*test.py` and `Tests/Packaging/*test.*`.  
Expected: zero failures and `DMG_CONTRACT_OK=1`.

- [ ] **Step 3: Update colleague instructions**

Explain that 105 is ignored in this release, 101 follows the image path, unknown falls back to image, and real-machine text/image/video acceptance remains required on each new Mac.

- [ ] **Step 4: Build and verify the DMG**

Run `scripts/build-distribution-dmg.sh`, mount read-only, verify nested signatures, arm64 binaries, manifest hashes, app resources, and SHA-256. Do not claim notarization unless `NOTARIZATION_ACCEPTED=1` appears.

- [ ] **Step 5: Commit tracked delivery changes**

```bash
git add docs scripts Sources Tests components
git commit -m "Prepare adaptive auto reply media-aware release"
```

