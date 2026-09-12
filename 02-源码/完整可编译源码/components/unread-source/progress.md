# SDD ledger — plan: docs/superpowers/plans/2026-08-26-qianniu-unread-assistant.md

2026-08-26 13:46 latest: user real unread scan exposed phase-one button AXTitle-only mismatch. Signed read-only LinkQA confirmed AXTitle=nil/AXDescription=识别千牛主聊天区/enabled=1. Fallback exact description matcher and distinct preflight errors added; recorded-attribute regression RED two assertions → GREEN, full 39 tests pass. Same real OCR preflight now passes. Restored normal production helper (not QA), no-dot actual UI 0.17s, signature/hash verified, embedded phase-one components unchanged. Full new-red-dot chain still pending because current customer had already been opened by time of live check.

2026-08-26 13:27 latest: user approved minimal fixes from audit. Confirmed wrapper `open -n` duplicate-launch root mechanism, removed only -n in authoritative wrapper, safely replaced outer suite with embedded components unchanged. Target OCR reduced from three idle instances to one and remained same PID after repeat launch. Added pending manual handoff recovery with attempted-press barrier, bounded non-cooperative screenshot wait/in-flight cap, and pre-build/pre-copy running guards. 37 Swift tests + 2 packaging tests pass; independent review no blocker. Normal helper installed and no-dot GUI scan passes in 0.17s. Exact artifacts/evidence in LIVE-QA.md. Live positive incoming-red-dot chain remains pending, not claimed complete.

Scope approved by user: independent find-unread/full-ID/open tool. Added emphasis: unread dot can occur at any vertical position in multi-user list.

Workspace: dedicated new project directory; outer workspace is not a Git repository, so Git-only workspace/diff scripts cannot operate. Preserve file-based audit instead.

Preflight:
| Task/interface | Check | Result |
| --- | --- | --- |
| Task 1 internal | Screenshot fixture → dynamic-row detection → native open/verify | Same coordinate system is required; captured window bounds and fresh AX frames must be checked. |
| Task 1 scope | UI/button/native workflow vs spec | Visible-only, no background loop, no send or old dependency. |
| Task 1 packaging | Standalone bundle vs isolation | Unique bundle ID and output, old app unchanged. |

Task 1: in progress.

Implementer: /root/implement_unread. Tests and source owned by implementer; controller owns live Computer Use QA, evidence, installation and review coordination.

Baseline checks 2026-08-26 10:59:
- `rsync -rnic` active project vs frozen project, excluding rebuild caches/output: no differences.
- `diff -qr` installed old app vs frozen old app: no differences.
- New `/Applications/千牛未读助手.app` target does not exist.
- Captured true no-dot fixture after a service response, leaving global badge39 visible. The earlier incoming-frame fixture is transitional, not an answered-state assertion.

Controller QA:
- Installed first package to unique new Applications path; button click stopped at missing Accessibility in 0.02s, no target opened.
- First screenshot showed native prominent button invisible despite AX-clickable; second package plain blue/white button visibly rendered with both Settings links.
- Second installed executable SHA256 5033f6e02a12bab490ce31a6d1be680956451995c7c81aa2ead9aef84616c325; codesign verified.
- Controller full `swift test` 11:12:41: 18 tests, 0 failures, no build warnings.
- OS permission confirmation requested asynchronously, not received yet. No permission changed; live unread opening unverified.

Task review /root/review_unread: changes required, 2 important gaps (mixed incomplete rows silently omitted; multiple WindowGroup windows have independent busy state). Fix round 1 dispatched to original implementer. Minor deferred: ScreenCaptureKit lacks explicit wall-clock timeout; documented.

Task 1: fix round 1/5 (2 addressed, 0 important open). Scoped rereview and whole-project assessment approved for permission-enabled live QA by /root/review_unread.

Final controller verification 11:15:
- Full Swift test suite: 21 tests, 0 failures, warning-free build.
- Final app installed; executable SHA256 5f858535e85d3fab2071c9dc7689221f57cc5d28189870425db56bfa9c0a5583.
- Installed plist lint + deep/strict signature verification succeeded.
- CU final app window ID unread-assistant, blue button/settings links visible; single Window scene (no File/New Window menu).
- Old source checksum comparison and installed old app diff: unchanged against frozen baseline.

Implementation/review/packaging complete. Live positive pipeline QA remains blocked awaiting new-app Accessibility and Screen Recording authorization; no real unread opening success claimed. Keep project/audit files because this is not a Git repository and no commit history exists to recover them.

2026-08-26 11:51 superseding status: app permissions were enabled in prior QA. Title/list dependency fixed; 33 tests pass, package installed and phase one unchanged. Native full-profile positive QA is currently blocked by foreground UserNotificationCenter dialog (Computer Use denies interacting with that app). Isolated QA executable removed from installed bundle by restoring signed production output. See LIVE-QA.md for evidence and remaining live tests.

2026-08-26 11:57 correction: the preceding "dialog" claim was unverified; only a foreground process name was observed. User-reported unexpected exits were confirmed as CODESIGNING Invalid Page during premature live executable replacement. Recovered production bundle, added staged whole-bundle installer refusing live processes, and tested refusal plus clean quit/install/reopen. Full native profile-positive QA remains pending, separately from deployment crash recovery. Do not modify live app files or use system-process names as proof of visible dialogs.

2026-08-26 12:33: isolated native profile-positive checks passed for stoneshishininger (1.19s without activation comparison) and tb263147182 (0.36s). AXWindows transient cannotComplete is retried only during polling/closure within the original deadline; baseline before click remains fail-fast. Review approved. Production build 33/33 tests, normal helper safely installed/reopened, two real no-dot scans passed (0.16s/0.10s), signature/hash checked, no additional crash report, phase-one baseline unchanged. Positive real unread-to-phase-one chain remains pending; buyer iPhone currently in use and mirroring disconnected. Full evidence and limitations in LIVE-QA.md.
