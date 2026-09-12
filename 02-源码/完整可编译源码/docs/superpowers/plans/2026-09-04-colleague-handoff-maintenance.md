# Version B Colleague Handoff and Maintenance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a verified Version B delivery ZIP that a colleague's Codex can install, configure, prewarm, run, debug, rebuild from source, and maintain without developer-machine paths or credentials.

**Architecture:** Keep Version B's customer-facing algorithms unchanged. Add a standalone standard-library maintenance tool around the existing runtime state, package it with stable launchers and a sanitized diagnostic exporter, then upgrade the existing DMG/developer-handoff pipeline and manuals. The exact current Version B source is frozen into Git before packaging; large runtime/model payloads remain in the signed App/DMG and are reused as the offline rebuild seed instead of being duplicated in Git.

**Tech Stack:** Swift 5.9/SwiftPM/AppKit, Python 3 standard library, zsh, XCTest, Python `unittest`, `git bundle`, `codesign`, `hdiutil`, SHA-256 manifests.

**Spec:** `docs/superpowers/specs/2026-09-04-colleague-handoff-maintenance-design.md`

## Global Constraints

- Do not change Version B red-dot, AX, OCR, image, video, V2, Codex reply, send, or transfer behavior.
- The installed main App path is `/Applications/千牛全自动客服-版本B.app`; never operate permanently from a WeChat, ZIP, Downloads, DMG, or App Translocation path.
- Runtime paths must derive from the current user's `~/Library/Application Support`; no `/Users/scy` or colleague-specific path may enter production files.
- First-run instructions must require Qianniu `设置 → 系统设置 → 接待设置 → 会话窗口 → 文本模式`; bubble mode is unsupported.
- First-run instructions must require the colleague's own customer-service name/ID, not a carried developer value.
- Cleanup checks daily, performs age cleanup at 30 days, triggers capacity cleanup at 10 GiB, and stops capacity cleanup at or below 8 GiB.
- Cleanup may permanently delete only allowlisted completed media and terminal stale diagnostics; all active, failed, unknown, customer-history, model, knowledge, identity, authentication, and scheduler/send data is preserved.
- The final ZIP contains editable source, tests, scripts, docs, a Git bundle with history, the installable DMG, and checksums; it contains no customer runtime data or credentials.
- Build outputs, `.build`, local caches, `.tmp`, developer-machine logs, and old experimental applications are not source and must not be included.

---

### Task 1: Freeze the exact current Version B source baseline

**Files:**
- Modify only if already part of current Version B: tracked files reported by `git diff --name-only`
- Add only if required by the current installed Version B: `Sources/AutoReplyApp/SenseVoiceSpeechTranscriber.swift`, `Sources/AutoReplyCore/CodexFailureRoutingPolicy.swift`, `Resources/SenseVoice/**`, and current related tests
- Exclude: `build-*`, `.build`, `.tmp`, installed App copies, logs, and runtime records

**Interfaces:**
- Consumes: the currently installed `/Applications/千牛全自动客服-版本B.app` and the dirty source worktree.
- Produces: one clean Git commit whose source, tests, and build scripts represent the current Version B behavior; records model-resource hashes without duplicating the same payload in multiple package sections.

- [ ] **Step 1: Inventory every dirty path and classify it**

Run:

```bash
git status --short
git diff --name-status
find Resources/SenseVoice -type f -print 2>/dev/null | sort
find . -maxdepth 1 -type d -name 'build-*' -print | sort
```

Expected: source/test/resource changes are separated from generated build directories. Do not stage generated directories.

- [ ] **Step 2: Verify the current uncommitted source before freezing**

Run:

```bash
swift test
python3 -m unittest discover -s Tests/Packaging -p '*test.py'
```

Expected: all suites pass. If a failure is pre-existing, record its exact test and stop rather than packaging an unverified state.

- [ ] **Step 3: Stage only source-of-truth files**

Run `git add` with explicit paths for the tracked source, tests, scripts, docs, and required `Resources/SenseVoice` files. Then run:

```bash
git diff --cached --name-only
git diff --cached --check
```

Expected: no path begins with `build-`, `.build/`, `.tmp/`, or contains runtime customer data.

- [ ] **Step 4: Commit the Version B baseline**

```bash
git commit -m "feat: freeze current version B runtime"
```

- [ ] **Step 5: Rebuild from the commit and compare identity**

```bash
AUTOREPLY_APP_NAME='千牛全自动客服-版本B.app' scripts/build-app.sh
codesign --verify --deep --strict build-output/千牛全自动客服-版本B.app
```

Expected: the committed source builds and signs. Record executable and bundled-model SHA-256 values for the release manifest; behavioral equality is established by tests, not by requiring byte-identical Mach-O output.

---

### Task 2: Record an unambiguous video completion timestamp

**Files:**
- Modify: `Sources/AutoReplyApp/VideoAnalysisInbox.swift`
- Modify: `Tests/AutoReplyAppTests/VideoAnalysisInboxTests.swift`

**Interfaces:**
- Consumes: `VideoAnalysisEntry.phase`, `updatedAt`, and `markCompleted(_:)`.
- Produces: optional `completedAt: Date?`; only `markCompleted(_:)` sets it, and legacy records decode with `nil`.

- [ ] **Step 1: Write failing state-compatibility tests**

Add tests equivalent to:

```swift
func testMarkCompletedStoresDedicatedCompletionTime() async throws {
    // enqueue, markCompleted, reload from disk
    XCTAssertEqual(entry.phase, .completed)
    XCTAssertNotNil(entry.completedAt)
}

func testLegacyCompletedEntryWithoutCompletionTimeRemainsUndated() async throws {
    // decode schema-1 JSON without completedAt
    XCTAssertEqual(entry.phase, .completed)
    XCTAssertNil(entry.completedAt)
}
```

- [ ] **Step 2: Run the focused tests and confirm RED**

```bash
swift test --filter VideoAnalysisInboxTests
```

Expected: compilation/test failure because `completedAt` does not exist.

- [ ] **Step 3: Add the minimal backward-compatible field**

Implement:

```swift
struct VideoAnalysisEntry: Codable, Equatable, Sendable {
    // existing fields
    var completedAt: Date? = nil
}

func markCompleted(_ hash: String) throws {
    _ = try update(hash) {
        let now = Date()
        $0.phase = .completed
        $0.updatedAt = now
        $0.completedAt = now
    }
}
```

Do not infer `completedAt` from a legacy file's modification date.

- [ ] **Step 4: Run focused and full tests**

```bash
swift test --filter VideoAnalysisInboxTests
swift test
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AutoReplyApp/VideoAnalysisInbox.swift Tests/AutoReplyAppTests/VideoAnalysisInboxTests.swift
git commit -m "feat: record completed video retention time"
```

---

### Task 3: Build the safe cleanup engine

**Files:**
- Create: `scripts/maintenance/qianniu_safe_cleanup.py`
- Create: `Tests/Maintenance/qianniu_safe_cleanup_test.py`

**Interfaces:**
- Consumes: runtime root, `运行状态/媒体路由/video-analysis-inbox.json`, completed message hashes, known media directories, and the current time.
- Produces: `run_cleanup(runtime_root: Path, now: datetime, dry_run: bool) -> CleanupReport` and a JSON audit record under `Maintenance/logs/`.

- [ ] **Step 1: Write failing policy tests**

Cover exact cases:

```python
def test_age_cleanup_deletes_only_completed_older_than_30_days(): ...
def test_capacity_cleanup_uses_oldest_completed_until_at_or_below_8_gib(): ...
def test_active_failed_unknown_and_legacy_undated_entries_are_preserved(): ...
def test_symlink_or_outside_runtime_path_is_rejected(): ...
def test_changed_file_identity_between_plan_and_delete_is_skipped(): ...
def test_second_run_is_idempotent_and_keeps_hash_tombstone(): ...
def test_corrupt_state_returns_blocked_report_without_deleting(): ...
def test_concurrent_lock_returns_busy_without_deleting(): ...
```

Use sparse fixture files for 10/8 GiB tests so the test does not allocate real gigabytes.

- [ ] **Step 2: Run and confirm RED**

```bash
python3 -m unittest Tests/Maintenance/qianniu_safe_cleanup_test.py -v
```

Expected: import failure because the cleanup engine does not exist.

- [ ] **Step 3: Implement explicit policy and report types**

Implement standard-library dataclasses:

```python
@dataclass(frozen=True)
class CleanupPolicy:
    retention_days: int = 30
    high_watermark_bytes: int = 10 * 1024**3
    target_bytes: int = 8 * 1024**3

@dataclass
class CleanupReport:
    checked_at: str
    trigger: str
    bytes_before: int
    bytes_after: int
    deleted_hashes: list[str]
    skipped: list[dict[str, str]]
    errors: list[str]
```

Only entries with `phase == "completed"` and a valid ISO-8601 `completedAt` can become candidates.

- [ ] **Step 4: Implement path-safe candidate planning**

For each eligible hash, allow only:

```text
收到的视频/<messageHash>.mp4
收到的视频帧和音轨/<messageHash>/
收到的视频证据/<messageHash>/
```

Require a 64-character lowercase hexadecimal hash, use `Path.resolve(strict=False)`, require the resolved candidate to remain below the canonical runtime root, reject every symlink, and capture `(st_dev, st_ino, st_size, st_mtime_ns)` before deletion.

- [ ] **Step 5: Implement locked deletion and tombstone preservation**

Use an exclusive `fcntl.flock` on `Maintenance/cleanup.lock`. Re-stat immediately before deletion and skip if identity changed. Remove only planned allowlisted paths, retain the JSON entry with its hash/content hash/completion time, clear deleted file paths from the tombstone, and atomically replace state with `os.replace` plus directory `fsync`.

- [ ] **Step 6: Add terminal CLI trace cleanup without touching active traces**

Only consider trace files older than 30 days whose final valid JSONL metadata contains `process.completed`. Any unreadable, unfinished, changing, or symlinked trace is preserved. This cleanup is not used to force the runtime below 8 GiB.

- [ ] **Step 7: Write the audit log and stable exit codes**

Exit `0` for clean/no-op or successful cleanup, `3` for lock busy, `4` for state corruption/path safety block, and `5` for partial cleanup/error. Never print customer chat, raw message IDs, signed URLs, credentials, or frame contents.

- [ ] **Step 8: Run maintenance and full regression tests**

```bash
python3 -m unittest Tests/Maintenance/qianniu_safe_cleanup_test.py -v
swift test
```

Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add scripts/maintenance/qianniu_safe_cleanup.py Tests/Maintenance/qianniu_safe_cleanup_test.py
git commit -m "feat: add safe version B runtime cleanup"
```

---

### Task 4: Add stable one-click maintenance and diagnostics launchers

**Files:**
- Create: `Packaging/自动维护/安装自动清理.command`
- Create: `Packaging/自动维护/检查并安全清理.command`
- Create: `Packaging/自动维护/自动清理规则.md`
- Create: `Packaging/故障处理/一键导出诊断包.command`
- Create: `scripts/maintenance/qianniu_diagnostic_export.py`
- Create: `Tests/Packaging/maintenance_launcher_test.py`
- Create: `Tests/Maintenance/qianniu_diagnostic_export_test.py`

**Interfaces:**
- Consumes: packaged maintenance engine, installed Version B bundled Python (fallback to `/usr/bin/python3` only if available), current-user runtime root, and allowlisted machine/readiness files.
- Produces: stable tools under `~/Library/Application Support/QianniuAutoReplyTaskIsolationCandidate/Maintenance/` and a sanitized diagnostic ZIP on Desktop.

- [ ] **Step 1: Write failing launcher and privacy tests**

Assert that installation from a path containing spaces/Chinese characters copies tools to the stable directory, makes launchers executable, records SHA-256, and never embeds the source extraction path. Assert the diagnostic ZIP includes environment/profile/readiness/maintenance logs but excludes `用户/`, media, `auth.json`, Codex sessions, chat text, and signed URLs.

- [ ] **Step 2: Run and confirm RED**

```bash
python3 -m unittest Tests/Packaging/maintenance_launcher_test.py Tests/Maintenance/qianniu_diagnostic_export_test.py -v
```

- [ ] **Step 3: Implement the stable installer**

`安装自动清理.command` resolves its own directory, copies the cleanup engine, diagnostic exporter, wrapper, rules, and a generated SHA-256 manifest to a temporary sibling of the stable directory, verifies every hash, then atomically renames it into place. It must not schedule itself or request hidden permissions.

- [ ] **Step 4: Implement the cleanup wrapper**

`检查并安全清理.command` verifies the installed script hash, selects:

```text
/Applications/千牛全自动客服-版本B.app/Contents/Resources/Python.framework/Versions/Current/bin/python3
```

or a verified executable `/usr/bin/python3`, then passes only the dynamically derived runtime root. No `rm`, glob deletion, or caller-provided arbitrary root is allowed in the wrapper.

- [ ] **Step 5: Implement sanitized diagnostic export**

The exporter writes to a temporary directory, copies only allowlisted JSON/log summaries, adds `sw_vers`, hardware architecture, installed App bundle metadata, signature verification result, disk usage totals, and maintenance status, then creates `~/Desktop/千牛版本B-脱敏诊断包-<timestamp>.zip`. It must structurally redact absolute home paths and reject raw-evidence arguments.

- [ ] **Step 6: Run tests**

```bash
python3 -m unittest Tests/Packaging/maintenance_launcher_test.py Tests/Maintenance/qianniu_diagnostic_export_test.py -v
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Packaging/自动维护 Packaging/故障处理 scripts/maintenance/qianniu_diagnostic_export.py Tests/Packaging/maintenance_launcher_test.py Tests/Maintenance/qianniu_diagnostic_export_test.py
git commit -m "feat: add stable maintenance and diagnostic tools"
```

---

### Task 5: Rewrite the colleague and engineer handoff manuals

**Files:**
- Modify: `Packaging/首次安装说明.txt`
- Modify: `docs/把这个文件交给Codex-项目完整接管与Debug手册.md`
- Create: `docs/工程师构建与Debug说明.md`
- Create: `Tests/Packaging/colleague_guide_contract_test.py`

**Interfaces:**
- Consumes: existing first-run UI, adaptive calibration, prewarm, diagnostics, maintenance scripts, DMG builder, and Git bundle.
- Produces: deterministic instructions another Codex follows and beginner-facing instructions it gives the colleague.

- [ ] **Step 1: Write failing documentation contract tests**

Assert the manuals contain exact required concepts and paths:

```python
required = [
    "把整个解压文件夹交给Codex", "仍要打开", "辅助功能",
    "屏幕与系统音频录制", "语音识别",
    "设置 → 系统设置 → 接待设置 → 会话窗口 → 文本模式",
    "气泡模式不受支持", "填写自己的客服名称", "接待中心",
    "OCR", "V2", "SenseVoice", "只读自检", "自动开始",
    "30 天", "10 GiB", "一键导出诊断包", "Git bundle",
]
```

Also fail if `/Users/scy`, customer UIDs, auth/token files, or instructions to disable Gatekeeper appear.

- [ ] **Step 2: Run and confirm RED**

```bash
python3 -m unittest Tests/Packaging/colleague_guide_contract_test.py -v
```

- [ ] **Step 3: Put the Codex execution contract first**

The first page tells the colleague to provide the whole folder, not only the Markdown file. It tells Codex to verify checksums, install the DMG, guide Gatekeeper and permissions, confirm Text Mode, collect the colleague's own operator name, open the one correct reception center, calibrate, prewarm, run read-only self-test, start, and observe one scan cycle. Each failure reports the exact unfinished step and never claims setup is complete.

- [ ] **Step 4: Add the beginner operating guide**

Use button-level Chinese instructions for start, stop, permission repair, queue/status reading, video progress, diagnostic export, and the rule that old and new App versions must not run together.

- [ ] **Step 5: Add the engineer build/debug guide**

Document:

```bash
git clone ../03-Git完整历史/千牛全自动客服.bundle qianniu-version-b
cd qianniu-version-b
git checkout <manifest gitCommit>
swift test
AUTOREPLY_RESOURCE_APP='/Applications/千牛全自动客服-版本B.app' \
AUTOREPLY_APP_NAME='千牛全自动客服-版本B.app' scripts/build-app.sh
```

Explain Swift/macOS floors, local component packages, offline OCR/V2/SenseVoice resources, signing modes, DMG build, diagnostic-first debugging, and how permissions are tied to App identity/path/signature.

- [ ] **Step 6: Add the Codex recurring-task contract**

Tell Codex to first run `安装自动清理.command`, verify the stable installed hash, then create one daily thread heartbeat whose prompt is exactly the semantic contract in the spec. If automation creation is unavailable, teach the colleague to double-click `检查并安全清理.command`; never invent cron or `launchctl` behind the user's back.

- [ ] **Step 7: Run documentation tests and commit**

```bash
python3 -m unittest Tests/Packaging/colleague_guide_contract_test.py -v
git add Packaging/首次安装说明.txt docs/把这个文件交给Codex-项目完整接管与Debug手册.md docs/工程师构建与Debug说明.md Tests/Packaging/colleague_guide_contract_test.py
git commit -m "docs: add colleague setup and engineer rebuild guide"
```

---

### Task 6: Upgrade the developer-handoff package contract

**Files:**
- Modify: `scripts/build-developer-handoff.sh`
- Modify: `Tests/Packaging/developer_handoff_contract_test.py`
- Modify: `scripts/build-distribution-dmg.sh`
- Modify if naming requires it: `scripts/build-installer-app.sh`
- Modify: `Tests/Packaging/distribution_dmg_test.sh`

**Interfaces:**
- Consumes: verified Version B DMG, clean Git HEAD, manuals, maintenance/diagnostic launchers, and source tree.
- Produces: `千牛全自动客服-版本B-完整交付包-<timestamp>.zip` with directories `00` through `06` defined by the spec.

- [ ] **Step 1: Extend the failing package contract test**

Require:

```text
00-先看这里/把这个文件交给Codex-安装配置维护与Debug手册.md
01-安装/千牛全自动客服-版本B.dmg
02-源码/完整可编译源码/
02-源码/源码快照.zip
02-源码/工程师构建与Debug说明.md
03-Git完整历史/千牛全自动客服.bundle
04-自动维护/*
05-故障处理/一键导出诊断包.command
06-校验/manifest.json
06-校验/SHA256SUMS.txt
```

The test also verifies executable bits after ZIP extraction, source HEAD equals manifest `gitCommit`, Git bundle clone succeeds, and forbidden runtime paths are absent.

- [ ] **Step 2: Run and confirm RED**

```bash
python3 -m unittest Tests/Packaging/developer_handoff_contract_test.py -v
```

- [ ] **Step 3: Update product naming without changing bundle behavior**

Set DMG/payload display names to Version B while preserving the existing stable bundle identifier so already-granted macOS permissions have the best chance of surviving replacement. Do not change identifiers merely to match filenames.

- [ ] **Step 4: Package an editable source directory and Git history**

Use `git archive HEAD` twice: once extracted into `完整可编译源码/`, once as `源码快照.zip`. Do not copy the working directory. Create and verify `git bundle --all`, clone it to a temporary directory, checkout manifest HEAD, and run at least the packaging contract plus `swift build --product AutoReplyApp` using the installed/DMG App as the offline resource seed.

- [ ] **Step 5: Copy maintenance, diagnostics, and manuals**

Preserve `.command` executable bits. The final manifest records every artifact hash, Git commit/branch, source-build verification, bundle clone verification, DMG/App architecture/signature result, and privacy booleans.

- [ ] **Step 6: Generate checksums last and verify the final ZIP**

After ZIP creation, extract into a new temporary directory and recompute every SHA-256 listed in `06-校验/SHA256SUMS.txt`. Reject extra unmanifested files except the checksum file itself.

- [ ] **Step 7: Run packaging tests and commit**

```bash
python3 -m unittest Tests/Packaging/developer_handoff_contract_test.py -v
Tests/Packaging/distribution_dmg_test.sh
git add scripts/build-developer-handoff.sh scripts/build-distribution-dmg.sh scripts/build-installer-app.sh Tests/Packaging/developer_handoff_contract_test.py Tests/Packaging/distribution_dmg_test.sh
git commit -m "feat: package complete version B engineering handoff"
```

---

### Task 7: Build, verify, and deliver the final ZIP

**Files:**
- Generate outside Git: `build-output/千牛全自动客服-版本B.dmg`
- Generate outside Git: Desktop delivery directory and ZIP
- Create: `docs/releases/2026-09-04-version-b-colleague-handoff.md`

**Interfaces:**
- Consumes: Tasks 1–6 and the existing signed/adhoc resource seed.
- Produces: one final colleague-ready ZIP plus a release verification record; it does not install or start a second App during packaging.

- [ ] **Step 1: Run all automated verification**

```bash
swift test
python3 -m unittest discover -s Tests/Packaging -p '*test.py'
python3 -m unittest discover -s Tests/Maintenance -p '*test.py'
```

Expected: PASS with exact counts captured in the release record.

- [ ] **Step 2: Build the Version B DMG**

```bash
AUTOREPLY_APP_NAME='千牛全自动客服-版本B.app' \
AUTOREPLY_OUTPUT_DIR="$PWD/build-output" \
scripts/build-distribution-dmg.sh
```

Expected: DMG exists, mounts read-only, installer and nested App signatures verify, and architecture is arm64. Do not claim notarization unless the build reports `NOTARIZATION_ACCEPTED=1`.

- [ ] **Step 3: Run the handoff builder**

```bash
scripts/build-developer-handoff.sh \
  --dmg "$PWD/build-output/千牛全自动客服-版本B.dmg" \
  --output "$HOME/Desktop/千牛全自动客服-版本B-同事交付"
```

- [ ] **Step 4: Perform clean-room restore and rebuild verification**

Extract the final ZIP into a new `mktemp -d` directory, verify all hashes, clone only the bundled Git history, checkout the manifest commit, run the documented focused test and App build commands, and confirm no path resolves back into the developer worktree.

- [ ] **Step 5: Verify the actual handoff experience without sending**

Mount the DMG, launch only the installer validation path, verify the installed App identity/permissions guidance, verify the first-run checklist includes Text Mode and own operator name, run calibration/prewarm/read-only self-test, then stop before any customer message is sent. Do not run old Version B and the packaged candidate simultaneously.

- [ ] **Step 6: Write and commit the release record**

Record Git commit, ZIP/DMG SHA-256, sizes, architecture, signing/notarization status, test counts, clean-room build result, exclusions, and the fact that no customer message was sent.

```bash
git add docs/releases/2026-09-04-version-b-colleague-handoff.md
git commit -m "docs: record version B colleague handoff verification"
```

- [ ] **Step 7: Report the exact deliverables**

Provide clickable absolute links to the final ZIP, checksum, unpacked folder, Codex handoff manual, engineer guide, and DMG. State clearly that the source and Git history are included and that the release remains one App/one Qianniu account.
