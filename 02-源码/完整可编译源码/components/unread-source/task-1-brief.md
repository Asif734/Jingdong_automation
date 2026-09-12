### Task 1: Independent app and tested dynamic targeting

**Files (all under work/qianniu-unread-assistant):**
- Create `Package.swift`, `Sources/UnreadCore/Models.swift`, `Sources/UnreadCore/RedDotDetector.swift`, `Sources/UnreadCore/ConversationLocator.swift`.
- Create `Sources/UnreadApp/NativeSession.swift`, `Sources/UnreadApp/UnreadAssistantApp.swift`, `Sources/UnreadApp/WindowCapture.swift`.
- Create `Tests/UnreadCoreTests/UnreadCoreTests.swift`, `Packaging/Info.plist`, `scripts/build-app.sh`, `README.md`.
- Existing evidence JPEGs are immutable test inputs; add tests which load them directly via path relative to #filePath.

**Interfaces:**
- Core receives structural AX nodes with ID, parent, role, title/value/description, frame; returns visible conversation rows containing node ID, full UID, frame.
- Detector receives RGB(A) image and coordinate mapping between window screen frame and image; returns target rows with a validated dot relative to their own frames.
- Selection returns fresh row matching prior UID; verification compares actual chat header ID exactly.

- [ ] **Step 1: Test-first pure contracts.** Build an executable Swift package with a core library and XCTest target. Write failing tests before detector/locator implementation, with stubs returning empty results if needed for a clean RED. Assert real detection, not constants:
  ```swift
  XCTAssertEqual(found.map(\.uid), ["stoneshishininger"])
  XCTAssertEqual(freshTarget?.frame.minY, 650) // same UID moved from first to tenth row
  XCTAssertFalse(verified(expected: "alice", actual: "bob"))
  ```
  Required cases: supplied real red-dot screenshot (UID tb263147182); no-dot avatar with orange/red face; right-side red timer and global red badges excluded; synthetic dot on rows 1, 5, 10; window translation and 2x scale; multiple dots sorted top-to-bottom; full non-tb/long UID; reject truncated or ambiguous identity; stale target disappeared; header mismatch. For AX structure constrain rows to the actual list anchored below the reception tabs and left of chat header, do not classify arbitrary AXGroup titles as UIDs.
- [ ] **Step 2: Run RED.** `swift test --package-path work/qianniu-unread-assistant`; record actual assertion failures and reason in `implementation-report.md`.
- [ ] **Step 3: Minimal core.** Detect connected red components only in each row's avatar-corner region, with relative size/aspect/density checks; map image pixels from actual window/frame dimensions. Derive list rows from AX structure and geometry rather than UID patterns. Re-resolve same UID on new snapshots. Run focused tests then full `swift test` to GREEN. Expose useful diagnostics when structural rows are unavailable instead of false “no unread”.
- [ ] **Step 4: Native adapter and UI.** Native reader traverses current reception window, bounded node count and messaging timeout; capture with `SCShareableContent` and `SCScreenshotManager`. Request no automatic permission mutation. Fail when missing permission or window is minimized/unavailable. On button: check, snapshot+capture, detect, report IDs, take a fresh snapshot+capture and locate same UID/dot, activate window, resolve again before click, click inside fresh row (AXPress preferred, real-time point fallback), verify header with bounded reads. Changes during asynchronous capture must cause retry/clear failure rather than stale-click. UI shows busy state, found UID, final verified UID, elapsed time and error; disable button while busy. Add protocol-backed tests for orchestration where feasible, without executing live UI. Retain only last compact diagnostic summary under app support, no chat text/images by default.
- [ ] **Step 5: Package.** Script builds release executable into `output/千牛未读助手.app`, macOS 14+, bundle ID `com.local.qianniu-unread-assistant`, uses existing `Apple Development: Chu Ye Shi (6Q9HFP6LJJ)` signing identity (never export private key); fail clearly if missing. Do not delete existing unrelated bundles. `plutil -lint`, `codesign --verify --deep --strict`, `swift test` and report size. Controller installs to `/Applications/千牛未读助手.app` after checking target does not exist.
- [ ] **Step 6: Review and live QA.** Controller dispatches read-only spec/quality review, addresses important findings, and tests packaged app using Computer Use. If permissions need confirmation, finish safe testing first and report precise blocker instead of success. Include moving/reordering screenshot tests and real UI success when red dot available. Do not send messages to manufacture state.

No Git commits: workspace is not a Git repository. Preserve implementation report and review artifacts as the audit record.
