# Controller QA — 2026-08-26

Installed app: `/Applications/千牛未读助手.app`

## AX button label correction — 2026-08-26 13:46 (latest)

- User's actual unread run found `tb263147182` but failed the phase-one idle preflight before changing the conversation. Read-only signed `Tests/ManualProfileQA/LinkQA.swift` reproduced the failure using actual production PhaseOneLink and printed only button metadata. Real recognition button: AXTitle=nil, AXDescription=识别千牛主聊天区, AXEnabled=1. The old code matched AXTitle alone. Copy-all had AXDescription=复制全部 and AXEnabled=0; it was not the target.
- Minimal production change: exact AXButton match uses nonempty AXTitle, otherwise AXDescription. Conflicting nonempty title is not overridden. Uniqueness, enabled state, full-UID recheck, attempted marker and single AXPress behavior retained. Preflight now distinguishes missing button, multiple buttons, unreadable enabled state and genuinely disabled recognition. Labels are read only for buttons, not OCR output/editable areas.
- Added UnreadAppTests target and recorded-attribute regression: old predicate failed two assertions (nil/empty title); after fix both tests pass, including wrong-role, wrong-label, conflicting-title and exact legacy-title checks. Full build: 39 tests, 0 failures.
- SAME actual installed OCR window in signed read-only harness: before fix `生产检查：一期版正在识别或窗口不可用`; after fix `生产检查：通过`. No OCR scan, chat click or sending action exists in this harness. Harness was removed from installed app by safely restoring the normal production bundle.
- Normal helper installed and opened, SHA256 installed/output both `63dabd4f20c9e6cc39a539c75349ab3b2edc45850919a4b978f14fa38d864312`; signature passed. Actual normal scan 0.17s no visible red dot/no phase-one trigger; permissions retained. Nine old crash reports unchanged, latest 11:55:06. Embedded phase-one Components remain byte-identical to frozen baseline.
- Current customer was already open and red dot had disappeared by live validation, so live positive new-red-dot-to-AXPress chain remains pending. This fix has a real positive BUTTON PREFLIGHT check, not merely the no-dot branch; do not conflate it with full chain completion.

## Minimal reliability fixes — 2026-08-26 13:27 (latest)

- Root cause of duplicate launch confirmed in both installed wrapper and authoritative source: `exec /usr/bin/open -n "$embedded_ocr_app"`. Source fix removes only `-n`. Historical initiator of each launch is unknown; do not attribute the launches to user clicks. Initial target OCR PIDs: 19594, 20100, 24259. Each was inspected via Computer Use: recognition button enabled, no active generation/send/queue. Quit each via Cmd-Q before whole-suite replacement. Unrelated older link-experiment PID 734 was left alone.
- Staged a copy of the installed suite, replaced/re-signed only its outer launcher and outer bundle, retained original at `installation-backups/suite.08i6QR/`. Embedded Components compared byte-for-byte against frozen phase-one baseline with no differences. Source checksum comparison against frozen project reports only `suite-wrapper/Packaging/launcher.zsh`. No OCR, AI, sender, red-dot or full-ID algorithms changed.
- The wrapper is a short-lived launcher with no window: Computer Use get_app_state on it times out after launching. Its embedded OCR was then inspected successfully, showing ready/empty output. Initial corrected launch and repeat launch both left the same unique target OCR PID 36084; no extra target copy appeared. Launcher OS-boundary test independently verifies the exact existing-instance open arguments. This is not a full message/response test.
- Added one atomic pending-handoff JSON record under Application Support/QianniuUnreadAssistant. Persist before customer click, keep on pre-trigger failure, reload/revalidate exact full UID on the next manual click even if dot cleared, clear on successful handoff. Before AXPress, persist attempted=true: an uncertain press is never blindly repeated. UI can clear a user-reviewed/abandoned marker, including an unreadable record. No background retry/queue added.
- Screenshot wait now has a 5-second caller deadline; late results cannot proceed to click. One still-pending capture blocks additional captures until it returns (or helper restarts), preventing accumulated tasks. Unit test simulates non-cooperative capture, timeout, blocked second capture, and late release without clicks. Real ScreenCaptureKit stall was not induced.
- Build script checks for live UnreadApp before build and again before output replacement. Controlled script test reproduced old exit0/overwrite and now passes refusal. Actual build attempt while helper running refused with exit1 and left original output hash unchanged. Installer still uses stopped-process, signed whole-bundle staging.
- Final build: 37 Swift tests, 0 failures; 2 executable packaging boundary tests pass. New recovery tests cover dot-clearing failure across journal reload, wrong current UID, and uncertain trigger. Earlier isolated audit reproduced lost handoff before the changes. Timeout accumulation regression failed two assertions before its guard. Added API tests initially failed to compile until new API implementation; do not claim those compiler failures alone prove runtime regressions.
- Read-only reviewer found no blocker; minor corrupt-journal recovery UI concern fixed. Production installed via safe installer, previous helper at `installation-backups/install.GkgZYD/`. Installed/output executable SHA256 match `880d81507ddb0d14f703aeb31c32bd95a8f0e1a95acc96dfd59ac0a27b5f17b4`; both application signatures verified.
- Actual normal helper UI click: no red dot, no phase-one trigger, 0.17s; permissions remained effective. No new crash reports (nine old reports, latest 11:55:06). No customer message sent during these checks.
- Remaining limitation: live incoming red-dot → customer open → phase-one trigger end-to-end is still not verified; no new incoming message was available. Automated recovery tests are not a substitute for that positive live chain.

## Verified

- Captured real Qianniu avatar-dot and no-dot screenshots without clicking/replying to customers.
- Controller independently ran final Swift suite at 11:15:09: 21 tests, 0 failures, no warnings. Includes row 1/5/10, translated window, 2x pixels, same UID reordered, non-tb/long UID, invalid and duplicate identity coverage, stale scene/dot failure and exact header verification.
- Installed binary matches release SHA256 `5f858535e85d3fab2071c9dc7689221f57cc5d28189870425db56bfa9c0a5583`; plist lint and codesign deep/strict passed.
- Computer Use launched actual packaged app; button clicked and missing Accessibility was reported in 0.02 seconds without any conversation action.
- First UI native prominent button was invisible in capture despite AX-clickable. Explicit plain blue/white rendering was verified visible in second and final package. Settings links visible.
- Final single-window scene shown as `unread-assistant`; no File/New Window menu.
- Old installed app and source remained content-identical to frozen baseline.
- Read-only independent review: both important findings fixed and approved for permission-enabled QA; no open important/critical findings.

## Permission-enabled check

- User confirmed the two permission grants and completed macOS administrator authentication themselves. System Settings showed Accessibility on and Screen Recording on for 千牛未读助手. Clicked the system's Quit & Reopen action to apply recording permission.
- The restarted installed app completed a scan, reporting 当前可见列表未检测到红点 in 0.08 seconds without a permission error. Its structural diagnostic file was updated at 11:22.
- Fresh Computer Use screenshot of Qianniu confirmed neither visible customer avatar had a red dot; the unrelated global 39 badge remained. No message was sent.

## Still unverified

Actual red-dot target clicking and post-click header verification remain unverified with permissions enabled because no visible customer currently has a red dot. Automated fixtures are not a substitute for that positive end-to-end check.

After authorization: open new app, create/receive a red-dot message, click 查找并打开, confirm found UID equals actual header and status shows success. Repeat with another visible row and moved window. Do not send messages from this utility. Diagnostic file is `~/Library/Application Support/QianniuUnreadAssistant/last-diagnostic.txt` (structure and frames only).

Known limitation: ScreenCaptureKit capture has no explicit watchdog; if it stalls, reopen the app. Only current visible list is scanned, no background loop or automatic scrolling.

## Latest verification — 12:33 update

- Isolated native profile test identified transient AXWindows `.cannotComplete` (-25204) during profile closure. Added bounded retries for that specific read error only; successful enumeration must still include the original reception window. Baseline enumeration before clicking remains fail-fast without retry suspension. Independent read-only review approved the final adjustment.
- Live isolated native code returned `stoneshishininger` from the truncated current title and closed the profile: 1.44s with test-only foreground activation, then 1.19s with that comparison disabled. Switched to the other customer and returned `tb263147182` in 0.36s. No phase-one trigger or send performed by this test entry point. The final baseline fail-fast adjustment was reviewed and compiled after these positive checks; profile polling/closure behavior is unchanged.
- Production build at 12:30 ran 33 tests with 0 failures. Installed via the staged whole-bundle installer after confirming the QA process exited. The installed app is the NORMAL helper, not the isolated QA entry point. Installed/release executable hashes match: `1084d2df170994aa4d14911d51f8cd9c603daf0702ebe3fbaaedcee21373340a`; deep/strict signature verification passed.
- Actual installed normal UI scans: full-title customer 0.16s, truncated-title customer 0.10s. Both correctly reported no visible red dot and no phase-one trigger; no permission error.
- Crash report count remains nine, latest 11:55:06, with no new report after safe staged installation. This is observed recovery, not a guarantee against every future crash.
- Repeated checksum comparison of phase-one source and full installed phase-one bundle against the frozen baseline: no differences.
- Positive real red-dot → click → full-ID verification → phase-one trigger remains UNVERIFIED. iPhone Mirroring currently says iPhone is in use and must be locked to reconnect; no new buyer message was fabricated or sent. Existing duplicate phase-one process observations also still need a fresh readiness check before positive testing. No monitoring loop added.

## Truncated-header fix — 11:51 update

- Reproduced root cause with RED tests: rows() required a full current header, rejecting the otherwise intact list when the header was `stoneshishinin...`. Removed that dependency, leaving left-list structural validation and full row-ID requirements intact.
- Live installed intermediate build scanned the actual truncated-title scene in 0.15s, correctly reporting no visible red dot and not triggering phase one.
- AX row selected-state is unsupported and help contains no identity. Manual Computer Use click on current header revealed a separate profile window titled `加普威旗舰店:小丹-stoneshishininger的资料`; this supplies a full UID. No prefix-only identity inference added.
- Added native fallback to open the current header's profile, require new-window provenance, extract full UID, close and verify stable reception/list/title. AXWindows errors/expiry fail closed with a separate profile deadline. Multiple rows sharing displayed prefix fail closed. Independent reviewer confirmed the two initial blocking issues were addressed.
- Final build at 11:50: 33 Swift tests, zero failures; release/plist/signature checks passed. Activation now explicitly yields from this app using macOS cooperative activation and checks acceptance; profile code yields 150ms then revalidates its target.
- Isolated manual QA entry point in Tests/ManualProfileQA compiles with the actual NativeSession/WindowCapture code and cannot send or invoke phase one. Native positive test did NOT pass: activation was rejected while system `UserNotificationCenter` owned the foreground. Computer Use refused access to that system app for safety. No workaround attempted; user must handle the system dialog. Do not equate parser/unit tests with live profile success.
- QA entry point is NOT included in the production bundle. Restored/reopened the normal helper. Final installed and release SHA256 both `fabef4742063f9e47c9d5b7535d8cce9909a17f99ef38f426f17d40edf8f46b3`. Same signing identity retained.
- Final phase-one source rsync checksum comparison and installed-bundle diff against frozen baseline: no differences.
- Still pending: native profile-positive test after clearing system dialog, then real unread → open → full-ID verification → one phase-one trigger. Existing multiple phase-one instances observed; the helper's existing multi-instance guard will stop rather than choose one. No phase-one instance closed or changed during this fix.

## Correction and crash recovery — 11:57 update (supersedes dialog claim)

- User asked what dialog; no dialog contents were read. Foreground process name alone was insufficient evidence for a visible permission dialog. Do NOT require the user to find a presumed dialog.
- Continued isolated tests reported different foreground apps (ChatGPT/Godot) and app activation rejection. A test-only NSWorkspace.openApplication activates=true comparison did bring Qianniu to the foreground, but native profile-window verification then failed. Full-ID positive QA is still incomplete, not a demonstrated permission issue. The temporary NativeSession stage-diagnostic edit was reverted; only the test utility retains comparison instrumentation.
- User reported repeated unexpected exits. All nine UnreadApp reports from 11:47–11:55 record `SIGKILL (Code Signature Invalid)` / `CODESIGNING: Invalid Page`. Latest report PID 27787 was on NSApplication terminate when its running executable was overwritten. Prior workflow issued Cmd-Q then immediately copied/re-signed the installed binary without waiting for complete process exit. This deployment mistake caused the crashes; no evidence that the OCR algorithm caused them.
- Stopped test runs, confirmed all UnreadApp processes exited, and restored the signed production release (SHA256 fabef4742063f9e47c9d5b7535d8cce9909a17f99ef38f426f17d40edf8f46b3).
- Added scripts/install-app.sh: refuse a running process, verify source/current/staged signatures and identity, copy to fresh same-volume staging, then move complete bundles with the previous app retained in a unique backup. No in-place live binary overwrite. Independent read-only review found no blocker for this fix; installations must be serialized.
- Real checks: installer while PID 28249 running refused with exit 1, hash/PID unchanged; normal scan reported no dot in 0.15s; Cmd-Q reached complete process exit; staged reinstall and signature validation succeeded; production app reopened. No phase-one action or reply sent.

## Phase-one link — 11:29 update

- User approved the minimal external link: after a visible red-dot target is opened and its full UID is verified, press the existing installed phase-one OCR button once. No phase-one source/bundle edits.
- New orchestration tests: missing handoff hook first failed three assertions; after implementing it all 25 tests passed. Busy-preflight regression separately failed three assertions before the guard was implemented. Final release build ran all 26 tests with zero failures and no compiler warnings.
- Independent reviewer identified that busy OCR must be checked before changing customers. Added a synchronous before-click readiness callback in the helper; retained the final pre-trigger enabled/UID check. Reviewer found no remaining blocking issue for this minimal link. Separate-process readiness is not an atomic lock against an unrelated simultaneous manual scan.
- Only helper connection/UI/workflow hooks/tests/docs changed. Red-dot detection, identity/location algorithms and NativeSession unchanged. Final rsync source comparison and installed phase-one bundle diff against the frozen baseline both reported no differences.
- Installed release SHA256: `7edbabce0c50fdb6e83a9db030b29ee56d3c1a381d86aea0dc36ed63740aa649`; codesign verification passed. Previous helper installation retained as `pre-link-installed.app`.
- Computer Use opened the final installed helper and clicked 查找并打开. Permissions remained effective. Result: 当前可见列表未检测到红点；未触发一期版, 0.16 seconds. Fresh Qianniu screenshot showed no red dot; phase-one UI state remained unchanged.
- Positive live red-dot → click → phase-one AXPress has NOT yet been verified. No synthetic dot, forced production trigger or test reply was inserted. Native cold launch, busy rejection and launch-time UID-change branches also remain unverified in live UI. Do not describe the 26 tests as full GUI success.
