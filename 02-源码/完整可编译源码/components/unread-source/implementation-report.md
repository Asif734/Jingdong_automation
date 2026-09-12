# Implementation report — 2026-08-26

## Scope and isolation

All writes by implementer are under `work/qianniu-unread-assistant`. Evidence JPEGs, `progress.md`, old applications, old source, live conversation data and queues were not modified. No network/AI API, live UI operation, git init/commit, permission changes or subagent dispatch was performed by implementer. Controller owns installation and live UI QA.

Implemented Swift package (macOS14+, zero dependencies), pure core locator/detector/workflow, native SwiftUI app, AX/ScreenCaptureKit adapters, signed packaging script and README.

## TDD evidence

Read test-driven-development skill and its complete `writing-good-tests.md` reference before writing tests. Production break named in test comments; literals and immutable real fixtures supply expected results.

1. Initial `swift test --package-path work/qianniu-unread-assistant` first hit a scaffold compile issue: CGRect Equatable overlay needed explicit CoreGraphics import. Corrected scaffold, reran before implementing algorithms.
2. 11:01:26 RED: same command executed **10 tests, 14 assertion failures**, 0 unexpected. Empty detector failed real screenshot UID, translated/scaled row1/5/10 and multi-dot order; empty locator failed structural arbitrary IDs, fresh row y650, and missing-anchor rejection; false header verifier failed exact success case. Negative exclusion tests passed against empty detector, but positive tests proved the detector contract exercised pixels.
3. 11:02:17 GREEN: same command, **10 tests, 0 failures**, after minimal connected-component detector and structural locator.
4. 11:02:50 RED: `swift test --package-path work/qianniu-unread-assistant --filter OpenWorkflowTests`, **6 tests, 9 assertion failures**, 0 unexpected. Stub workflow failed permission failure, capture mutation stop, dot disappearance stop, opened UID/position, and mismatched header stop.
5. 11:04:48 GREEN: full suite **16 tests, 0 failures** after protocol-backed workflow implementation. External AX/capture/click are test substitutes; real state machine selects, revalidates, clicks and verifies. Native adapter compiled but no real UI operated by implementer.
6. 11:10:35 additional safety RED: `swift test --package-path work/qianniu-unread-assistant --filter 'UnreadCoreTests.testOnlyAmbiguous|UnreadCoreTests.testChildOutside'`, **2 tests, 2 failures**. Caught an all-duplicate list incorrectly returning empty and an AX child outside list bounds being accepted. Added explicit ambiguity failure and list containment.
7. 11:11:27 GREEN: full `swift test --package-path work/qianniu-unread-assistant`, **18 tests, 0 failures**, warning-free compilation.

## Implementation safety

- Reception-list checkbox anchors a narrow structural list, direct row container children and live frames; arbitrary AXGroup labels outside that topology are excluded. No UID prefix rule.
- Header is anchored by “转发当前用户” / “新建任务” controls and exact same-row text geometry; right-side customer panel is excluded. Full ID must match exactly; truncation does not verify.
- Red connected components are inspected in each avatar area; corner location, scale-relative size, aspect, density and connectivity reject supplied avatar/timer/global badge distractors.
- First snapshot/capture/snapshot is followed by fresh target capture and activation, then another snapshot/capture/snapshot; any scene change during capture throws. Immediately before click, native code synchronously re-resolves the same UID and frame and checks frontmost process. AXPress is preferred; point fallback additionally checks hit-test ancestry.
- Header verification polls at most 8 reads, 150ms apart, and never tries another conversation after failure.
- AX tree has a 2500-node/35-depth bound, a 5-second read deadline and 0.2-second per-message timeout. Chat-body values and message-preview children are not read.
- Missing permissions stop before capture/click; no system permission mutation. Diagnostics retain only last structure/frames, no text/UID/image.

## Packaging / live QA to date

`bash work/qianniu-unread-assistant/scripts/build-app.sh` built release, plist lint passed, codesign deep/strict verification passed, first app **304 KiB**. Existing development signing identity used. Initial build had three unsafeBitCast style warnings; subsequent source changes use checked unsafeDowncast after CF type validation.

Final implementer packaging run at **11:11:56**: `bash work/qianniu-unread-assistant/scripts/build-app.sh` exited **0**; **18 tests, 0 failures**, debug and release compilation warning-free; `plutil -lint` OK; `codesign --verify --deep --strict --verbose=2` valid on disk and satisfies designated requirement. Second package size **316 KiB**. `shasum -a 256 work/qianniu-unread-assistant/output/千牛未读助手.app/Contents/MacOS/UnreadApp` = `5033f6e02a12bab490ce31a6d1be680956451995c7c81aa2ead9aef84616c325`. Controller notified to install this revision and recheck visible button/settings links. No additional implementer UI operations.

Controller installed first package to the new `/Applications/千牛未读助手.app` and clicked via Computer Use: it correctly stopped with missing Accessibility permission in 0.02s. This is a verified permission-failure path, **not** an end-to-end unread opening success. Controller supplied `evidence/first-app-permission-ui.jpeg`; implementer visually inspected it and confirmed blank primary-button pixels while AX remained clickable. The inactive-looking titlebar and default `.borderedProminent` rendering suggest a native-style drawing issue (not proven upstream root cause). Minimal isolated change replaces that style with explicit blue fill/white text using `.plain`; controller must verify rendered result. Added two Link entry points opening Accessibility/Screen Capture settings only, without permission mutation. Real native AX topology remains unverified until user grants this new bundle its permissions.

## Concerns / honest limits

No live unread target opened yet. Automated tests cannot prove actual Qianniu AX topology matches the structurally conservative adapter. The current supplied positive/negative screenshots pass; unknown themes/layouts require live validation. Pure red-dot imagery cannot distinguish a deliberate avatar drawing identical to the badge at the same location. ScreenCaptureKit capture has no explicit wall-clock watchdog; AX read operations are bounded. No claims of all customers being read or business-level reply completion are made.

## Review fix round — 11:14

Reviewed both IMPORTANT findings against source. The locator had identity validation inside a `continue` guard and removed duplicate identities whenever another unique row remained. That could return a partial list and falsely report no dot. It now throws an explicit incomplete-list error for any structurally valid visible candidate with missing, truncated or ambiguous identity, and for any duplicate UID. Geometrically unrelated nodes remain excluded. The existing permissive test was aligned to this safety contract.

RED at **11:13:49**: `swift test --package-path work/qianniu-unread-assistant --filter 'UnreadCoreTests.testMixed|UnreadCoreTests.testTruncatedAndAmbiguous'` ran **4 tests, 4 failures** (all expected “did not throw”). Three new fixtures mix valid rows with ambiguous/truncated/duplicate rows and place the only image dot on the uncertain row. Each fixture independently confirms its dot is detectable before asserting the combined locate/detect operation fails explicitly. The fourth updates the previous mixed-invalid-row contract.

GREEN at **11:13:59**: same focused command ran **4 tests, 0 failures** after the minimal guard/duplicate changes.

Changed `WindowGroup` to a single macOS `Window("千牛未读助手", id: "unread-assistant")` scene. This eliminates independent per-window busy state without adding application infrastructure. Controller explicitly requested this minimal scene change and no auto-opening test; no UI was launched by implementer. Runtime single-window verification remains with controller.

Final review-round packaging at **11:14:12**: `bash work/qianniu-unread-assistant/scripts/build-app.sh` exited **0**, **21 tests, 0 failures**, warning-free debug/release compile, plist lint OK, deep/strict signature verification passed. Third package remains **316 KiB**. Executable SHA256 from `shasum -a 256 work/qianniu-unread-assistant/output/千牛未读助手.app/Contents/MacOS/UnreadApp`: **`5f858535e85d3fab2071c9dc7689221f57cc5d28189870425db56bfa9c0a5583`**.

Controller reported second-package blue button and settings links visually verified and a fresh 18-test run passing. Third-package live UI/permissioned opening verification remains pending. Capture watchdog remains the documented minor limitation; no scope expansion or UI operations were performed in this round.
