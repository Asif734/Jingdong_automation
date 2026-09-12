# Per-user Codex Sessions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace stateless fixed-five customer reply generation with isolated, one-hour resumable Codex sessions per canonical Tmall UID, dynamic process concurrency, and trusted knowledge-base image/video link replies.

**Architecture:** Local `history.jsonl` remains authoritative. A persistent actor-backed registry maps each exact UID to a Codex session ID and append-only history checkpoint; each CLI process exits after one turn, and follow-ups resume the UID's session with only new messages and attachments. A per-UID gate serializes turns, while an adaptive controller allows different UIDs to run concurrently beyond the old fixed limit without changing the serialized Qianniu UI driver.

**Tech Stack:** Swift 6 / SwiftPM, Foundation `Process`, CryptoKit SHA-256, JSONL Codex CLI event stream, XCTest, signed arm64 macOS app, local Codex CLI with ChatGPT login.

**Spec:** `docs/superpowers/specs/2026-08-27-per-user-codex-sessions.md`

## Global Constraints

- Do not change OCR, red-dot detection, UID resolution, chat parsing, image/link copying, or Qianniu click/send algorithms.
- Keep `gpt-5.6-sol` with reasoning effort `medium` and ChatGPT CLI login; do not use API-key authentication.
- Keep all customer history and media in the existing isolated local record root.
- A UID must never resume a session selected by recency or `--last`; only an exact persisted session ID is valid.
- One UID has at most one active generation. Different UIDs may generate concurrently.
- One-hour idle expiry does not interrupt an in-flight turn.
- Knowledge-base or prompt-contract changes invalidate old sessions.
- Image/video URLs may be emitted only when found verbatim in the trusted knowledge base; never fabricate, open, or upload them.
- Preserve the current build before modifying source, and keep rollback independent of newer chat history.

---

### Task 1: Freeze and verify the current experimental build

**Files:**
- Create: `scripts/freeze-per-user-session-baseline.py`
- Create: `Tests/BaselineScriptsTests/freeze_per_user_session_baseline_test.py`
- Create at runtime: `../per-user-session-baseline-<timestamp>/manifest.json`

**Interfaces:**
- Consumes: current source and `/Applications/千牛全自动客服-实验版.app`.
- Produces: `freeze(source_root: Path, installed_app: Path, destination: Path, verify_signature: bool = True) -> dict[str, object]`.

- [ ] **Step 1: Write the failing test**

```python
def test_freeze_copies_and_hashes_source_and_app(tmp_path):
    source, app = fixture_source_and_app(tmp_path)
    destination = tmp_path / "frozen"
    manifest = freeze(source, app, destination, verify_signature=False)
    assert (destination / "source/Sources/a.swift").is_file()
    assert (destination / "app/Current.app/Contents/MacOS/App").is_file()
    assert set(manifest["files"]) == {
        "app/Current.app/Contents/MacOS/App", "source/Sources/a.swift"
    }
```

- [ ] **Step 2: Verify the test fails**

Run: `python3 -m unittest Tests/BaselineScriptsTests/freeze_per_user_session_baseline_test.py -v`

Expected: FAIL because `freeze()` does not exist.

- [ ] **Step 3: Implement the non-overwriting freezer**

```python
def freeze(source_root, installed_app, destination, verify_signature=True):
    if destination.exists():
        raise FileExistsError(destination)
    shutil.copytree(source_root, destination / "source", ignore=ignore_generated)
    shutil.copytree(installed_app, destination / "app" / installed_app.name)
    if verify_signature:
        subprocess.run(["codesign", "--verify", "--deep", "--strict",
                        str(destination / "app" / installed_app.name)], check=True)
    manifest = {"created_at": datetime.now().astimezone().isoformat(),
                "rollback": "Restore app/source only; never overwrite newer history or queues.",
                "files": hashes(destination)}
    atomic_json(destination / "manifest.json", manifest)
    return manifest
```

Exclude `.git`, `.build*`, `output`, derived evidence, and the live customer record root.

- [ ] **Step 4: Run the test and freeze the real phase**

Run: `python3 -m unittest Tests/BaselineScriptsTests/freeze_per_user_session_baseline_test.py -v && python3 scripts/freeze-per-user-session-baseline.py`

Expected: PASS, then one new signed snapshot path and nonzero manifest count.

- [ ] **Step 5: Commit**

```bash
git add scripts/freeze-per-user-session-baseline.py Tests/BaselineScriptsTests/freeze_per_user_session_baseline_test.py
git commit -m "test: freeze pre-session autoreply baseline"
```

---

### Task 2: Compute append-only history and attachment deltas

**Files:**
- Create: `components/batch-source/Sources/CustomerReplyBatchAppSupport/HistoryContinuation.swift`
- Create: `components/batch-source/Tests/CustomerReplyBatchAppSupportTests/HistoryContinuationTests.swift`

**Interfaces:**
- Consumes: existing full `PromptInput`.
- Produces `HistoryCheckpoint`, `HistorySubmission`, and `HistoryContinuation.plan(input:after:)`.

- [ ] **Step 1: Write failing full/delta/rewrite/media tests**

```swift
func testStrictAppendReturnsOnlySuffixAndNewImage() throws {
    let first = try HistoryContinuation.plan(input: input("a\n", [oldImage]), after: nil)
    let next = try HistoryContinuation.plan(input: input("a\nb\n", [oldImage, newImage]), after: first.checkpoint)
    XCTAssertEqual(next.mode, .incremental)
    XCTAssertEqual(next.historyJSONL, "b\n")
    XCTAssertEqual(next.imagePaths, [newImage])
}

func testRewriteForcesFullRehydration() throws {
    let first = try HistoryContinuation.plan(input: input("old\n", []), after: nil)
    let next = try HistoryContinuation.plan(input: input("changed\nnew\n", []), after: first.checkpoint)
    XCTAssertEqual(next.mode, .full)
}
```

Also test identical image bytes are not resubmitted and missing image files fail visibly.

- [ ] **Step 2: Verify failure**

Run: `swift test --package-path components/batch-source --filter HistoryContinuationTests`

Expected: missing-type compile failure.

- [ ] **Step 3: Implement strict-prefix SHA-256 planning**

```swift
public struct HistoryCheckpoint: Codable, Equatable, Sendable {
    public let historyByteCount: Int
    public let prefixSHA256: String
    public let attachmentSHA256: [String: String]
}

public enum HistoryContinuation {
    public static func plan(input: PromptInput, after old: HistoryCheckpoint?) throws -> HistorySubmission {
        let bytes = Data(input.historyJSONL.utf8)
        let images = try hashFiles(input.imagePaths)
        guard let old, bytes.count >= old.historyByteCount,
              sha256(bytes.prefix(old.historyByteCount)) == old.prefixSHA256 else {
            return full(input, bytes: bytes, imageHashes: images)
        }
        return incremental(String(decoding: bytes.dropFirst(old.historyByteCount), as: UTF8.self),
                           newImages: input.imagePaths.filter { images[$0] != old.attachmentSHA256[$0] },
                           checkpoint: checkpoint(bytes, images))
    }
}
```

- [ ] **Step 4: Run tests and commit**

Run: `swift test --package-path components/batch-source --filter HistoryContinuationTests && swift test --package-path components/batch-source`

```bash
git add components/batch-source/Sources/CustomerReplyBatchAppSupport/HistoryContinuation.swift components/batch-source/Tests/CustomerReplyBatchAppSupportTests/HistoryContinuationTests.swift
git commit -m "feat: compute incremental customer history submissions"
```

---

### Task 3: Persist exact UID session bindings and serialize each UID

**Files:**
- Create: `components/batch-source/Sources/CustomerReplyBatchAppSupport/CodexSessionRegistry.swift`
- Create: `components/batch-source/Sources/CustomerReplyBatchAppSupport/UIDGenerationGate.swift`
- Create: `components/batch-source/Tests/CustomerReplyBatchAppSupportTests/CodexSessionRegistryTests.swift`
- Create: `components/batch-source/Tests/CustomerReplyBatchAppSupportTests/UIDGenerationGateTests.swift`

**Interfaces:**
- Produces `CodexSessionBinding`, `CodexSessionPlan`, actor `CodexSessionRegistry`, and `UIDGenerationGate.withPermit(for:operation:)`.

- [ ] **Step 1: Write failing lease, isolation, corruption, and gate tests**

```swift
func testResumeBeforeHourAndExpireAtBoundary() async throws {
    try await registry.commit(uid: "u1", sessionID: "session-a", checkpoint: checkpoint,
                              promptVersion: "p1", knowledgeBaseVersion: "k1", at: now)
    XCTAssertEqual(await registry.plan(uid: "u1", promptVersion: "p1", knowledgeBaseVersion: "k1", at: now + 3599).sessionID, "session-a")
    XCTAssertTrue(await registry.plan(uid: "u1", promptVersion: "p1", knowledgeBaseVersion: "k1", at: now + 3600).requiresCreation)
}
```

Prove two `u1` operations serialize FIFO while `u2` enters immediately.

- [ ] **Step 2: Verify failure**

Run: `swift test --package-path components/batch-source --filter 'CodexSessionRegistryTests|UIDGenerationGateTests'`

- [ ] **Step 3: Implement atomic actor registry**

```swift
public struct CodexSessionBinding: Codable, Equatable, Sendable {
    public let uid: String
    public let sessionID: String
    public var createdAt: Date
    public var lastActivityAt: Date
    public var promptVersion: String
    public var knowledgeBaseVersion: String
    public var checkpoint: HistoryCheckpoint
    public var recoveryCount: Int
}
```

Persist atomically with mode `0600`. Corrupt JSON gets a dated diagnostic copy and an empty registry; it never produces a guessed session. Version mismatch or `>= 3600` idle seconds returns `.create`.

- [ ] **Step 4: Implement keyed actor permits**

```swift
public actor UIDGenerationGate {
    public func withPermit<T: Sendable>(for uid: String,
        operation: @Sendable () async throws -> T) async rethrows -> T {
        await acquire(uid)
        do { let value = try await operation(); release(uid); return value }
        catch { release(uid); throw error }
    }
}
```

- [ ] **Step 5: Run tests and commit**

Run: `swift test --package-path components/batch-source --filter 'CodexSessionRegistryTests|UIDGenerationGateTests' && swift test --package-path components/batch-source`

```bash
git add components/batch-source/Sources/CustomerReplyBatchAppSupport/CodexSessionRegistry.swift components/batch-source/Sources/CustomerReplyBatchAppSupport/UIDGenerationGate.swift components/batch-source/Tests/CustomerReplyBatchAppSupportTests/CodexSessionRegistryTests.swift components/batch-source/Tests/CustomerReplyBatchAppSupportTests/UIDGenerationGateTests.swift
git commit -m "feat: persist isolated per-user codex sessions"
```

---

### Task 4: Capture session IDs and build create/resume CLI commands

**Files:**
- Create: `components/batch-source/Sources/CustomerReplyBatchAppSupport/CodexInvocation.swift`
- Modify: `components/batch-source/Sources/CustomerReplyBatchAppSupport/CLIReplyHandoff.swift`
- Create: `components/batch-source/Tests/CustomerReplyBatchAppSupportTests/CodexInvocationTests.swift`
- Modify: `components/batch-source/Tests/CustomerReplyBatchAppSupportTests/CodexReplyGeneratorTests.swift`

**Interfaces:**
- Produces `CodexTurnMode.create` / `.resume(sessionID:)`, exact argv, and `CLIReplyStream.threadID`.

- [ ] **Step 1: Write failing argv and event tests**

```swift
func testCreatePersistsAndResumeUsesExactID() {
    XCTAssertFalse(create.arguments.contains("--ephemeral"))
    XCTAssertTrue(resume.arguments.contains("session-u1"))
    XCTAssertFalse(resume.arguments.contains("--last"))
}

func testStreamCapturesThreadID() {
    stream.consume(Data("{\"type\":\"thread.started\",\"thread_id\":\"session-u1\"}\n".utf8)) { _, _ in }
    XCTAssertEqual(stream.threadID, "session-u1")
}
```

- [ ] **Step 2: Verify failure**

Run: `swift test --package-path components/batch-source --filter 'CodexInvocationTests|CodexReplyGeneratorTests'`

- [ ] **Step 3: Implement exact command construction**

```swift
public enum CodexTurnMode: Equatable, Sendable { case create, resume(sessionID: String) }
```

Create mode keeps `-s read-only`, removes `--ephemeral`, and ends with `-`. Resume mode uses `exec resume`, the persisted ID, structured JSON/schema/output, model and medium reasoning; it never uses `--last`. Attach only the images selected by Task 2.

- [ ] **Step 4: Extend stream callback to `(ReplyEnvelope, String?)`**

Parse non-empty `thread.started.thread_id` without weakening agent-message schema checks, early handoff, failed-turn handling, or fully reaped fallback.

- [ ] **Step 5: Run tests and commit**

Run: `swift test --package-path components/batch-source --filter 'CodexInvocationTests|CodexReplyGeneratorTests'`

```bash
git add components/batch-source/Sources/CustomerReplyBatchAppSupport/CodexInvocation.swift components/batch-source/Sources/CustomerReplyBatchAppSupport/CLIReplyHandoff.swift components/batch-source/Tests/CustomerReplyBatchAppSupportTests/CodexInvocationTests.swift components/batch-source/Tests/CustomerReplyBatchAppSupportTests/CodexReplyGeneratorTests.swift
git commit -m "feat: create and resume exact codex sessions"
```

---

### Task 5: Integrate resumable sessions into reply generation

**Files:**
- Modify: `components/batch-source/Sources/CustomerReplyBatchAppSupport/PromptBuilder.swift`
- Modify: `components/batch-source/Sources/CustomerReplyBatchAppSupport/CodexReplyGenerator.swift`
- Modify: `components/batch-source/Sources/CustomerReplyBatchAppSupport/BatchCoordinator.swift`
- Modify: `components/batch-source/Sources/CustomerReplyBatchAppSupport/BatchTimingLogger.swift`
- Modify: `components/batch-source/Tests/CustomerReplyBatchAppSupportTests/PromptBuilderTests.swift`
- Create: `components/batch-source/Tests/CustomerReplyBatchAppSupportTests/PerUserSessionIntegrationTests.swift`

**Interfaces:**
- Produces `PromptBuilder.contractVersion`, `buildInitial`, `buildContinuation`, one-time resume recovery, and timing fields `sessionMode`, `submittedHistoryBytes`, `submittedImageCount`, `sessionRecoveryCount`.

- [ ] **Step 1: Write failing fake-CLI integration tests**

```swift
func testFollowUpResumesSameUIDWithSuffixOnly() async throws {
    _ = try await generator.generate(for: input(uid: "u1", history: "a\n"))
    _ = try await generator.generate(for: input(uid: "u1", history: "a\nb\n"))
    XCTAssertEqual(log[1].sessionID, "session-u1")
    XCTAssertEqual(log[1].stdinHistory, "b\n")
}
```

Also prove `u1`/`u2` isolation, one-hour rebuild, history-rewrite rebuild, same-UID serialization, and one fresh-create retry after resume failure.

- [ ] **Step 2: Verify failure**

Run: `swift test --package-path components/batch-source --filter PerUserSessionIntegrationTests`

- [ ] **Step 3: Split initial and continuation prompts**

```swift
public static let contractVersion = "tmall-grozziie-session-v1"

public static func buildContinuation(_ input: PromptInput, submission: HistorySubmission) -> String {
    """
    继续为同一个天猫客户 UID：\(input.uid) 服务。
    本地聊天记录是真实送达情况的唯一依据；先前生成但未出现在记录里的回复不得视为已送达。
    以下是新增消息和附件，请结合本会话已有上下文与知识库，回复最后一个尚未被客服回复的客户消息。
    <untrusted_chat_data>\(submission.historyJSONL)</untrusted_chat_data>
    """
}
```

- [ ] **Step 4: Integrate registry, gate, delta, and one-time recovery**

```swift
return try await gate.withPermit(for: input.uid) {
    let plan = await registry.plan(uid: input.uid,
        promptVersion: PromptBuilder.contractVersion,
        knowledgeBaseVersion: kbVersion(input.knowledgeBasePaths), at: now())
    do { return try await run(plan: plan, input: input) }
    catch where plan.isResume {
        await registry.invalidate(uid: input.uid, reason: "resume_failed")
        return try await run(plan: .create(reason: "resume_failed"), input: input)
    }
}
```

Commit the observed session ID and new checkpoint before accepting early handoff. Hash KB content once per path/size/mtime cache. Do not retry a failed fresh create here.

- [ ] **Step 5: Extend safe timing logs**

Add new/resumed/rehydrated mode, submitted bytes, image count, lease age, and recovery count. Do not log session IDs, chat content, URLs, prompts, or reasoning.

- [ ] **Step 6: Run tests and commit**

Run: `swift test --package-path components/batch-source --filter PerUserSessionIntegrationTests && swift test --package-path components/batch-source`

```bash
git add components/batch-source/Sources/CustomerReplyBatchAppSupport components/batch-source/Tests/CustomerReplyBatchAppSupportTests
git commit -m "feat: reuse codex context per tmall customer"
```

---

### Task 6: Replace fixed five with adaptive concurrency

**Files:**
- Modify: `components/batch-source/Sources/CustomerReplyBatchAppSupport/ConcurrencyPolicy.swift`
- Modify: `components/batch-source/Sources/CustomerReplyBatchAppSupport/BatchCoordinator.swift`
- Modify: `components/batch-source/Tests/CustomerReplyBatchAppSupportTests/ConcurrencyPolicyTests.swift`
- Modify: `components/batch-source/Tests/CustomerReplyBatchAppSupportTests/RollingBatchCoordinatorTests.swift`

**Interfaces:**
- Produces `AdaptiveConcurrencyPolicy.limit(queueDepth:availableMemoryBytes:activeCleanup:now:)`, `recordSuccess`, and `recordBackpressure`.

- [ ] **Step 1: Write failing adaptive tests**

```swift
func testFortyEightGiBCanRunMoreThanFiveUIDs() {
    let policy = AdaptiveConcurrencyPolicy(physicalMemoryBytes: 48 << 30, emergencyCeiling: 24)
    XCTAssertEqual(policy.limit(queueDepth: 10, availableMemoryBytes: 40 << 30, activeCleanup: 0, now: now), 10)
}
```

Also prove a 60-second explicit-backpressure cooldown halves capacity, low memory reduces it, cleanup consumes capacity, and one UID cannot occupy two slots.

- [ ] **Step 2: Verify failure**

Run: `swift test --package-path components/batch-source --filter 'ConcurrencyPolicyTests|RollingBatchCoordinatorTests'`

- [ ] **Step 3: Implement capacity formula**

Reserve 4 GiB, budget 1 GiB per live CLI/cleanup, and derive the default emergency ceiling as `min(24, max(6, physicalMemoryGiB / 2))`. Effective capacity is the minimum of ready distinct UIDs, memory capacity, and ceiling. Only explicit rate-limit/backpressure and process-resource launch errors activate cooldown.

- [ ] **Step 4: Remove `min(5, ...)` and keep rolling admission**

Count cleanup processes. Start the next distinct UID as soon as capacity becomes available; do not wait for a whole batch.

- [ ] **Step 5: Run tests and commit**

Run: `swift test --package-path components/batch-source --filter 'ConcurrencyPolicyTests|RollingBatchCoordinatorTests' && swift test --package-path components/batch-source`

```bash
git add components/batch-source/Sources/CustomerReplyBatchAppSupport/ConcurrencyPolicy.swift components/batch-source/Sources/CustomerReplyBatchAppSupport/BatchCoordinator.swift components/batch-source/Tests/CustomerReplyBatchAppSupportTests/ConcurrencyPolicyTests.swift components/batch-source/Tests/CustomerReplyBatchAppSupportTests/RollingBatchCoordinatorTests.swift
git commit -m "perf: scale codex workers by active customers"
```

---

### Task 7: Permit trusted image/video URLs in Tmall replies

**Files:**
- Modify: `components/batch-source/Sources/CustomerReplyBatchAppSupport/PromptBuilder.swift`
- Modify: `components/batch-source/Tests/CustomerReplyBatchAppSupportTests/PromptBuilderTests.swift`
- Modify only if the test exposes a defect: `components/sender-source/Sources/QianniuSenderCore/QianniuSendTransaction.swift`
- Modify: `components/sender-source/Tests/QianniuSenderCoreTests/QianniuSendTransactionTests.swift`

**Interfaces:**
- Existing structured `reply_text` carries explanatory text plus exact trusted HTTPS URLs.

- [ ] **Step 1: Write failing prompt and exact-send tests**

```swift
func testPromptAllowsOnlyVerbatimTrustedMediaLinks() {
    XCTAssertTrue(prompt.contains("图片或视频 HTTPS 链接"))
    XCTAssertTrue(prompt.contains("必须逐字来自可信知识库"))
    XCTAssertTrue(prompt.contains("不得编造、猜测或打开链接"))
}

func testSenderPreservesVideoURLExactly() async throws {
    let text = "安装视频：https://kb.example.com/video/m880.mp4?lang=zh-CN"
    try await transaction.send(uid: "test-user", text: text)
    XCTAssertEqual(fakeUI.insertedText, text)
}
```

- [ ] **Step 2: Verify failure**

Run: `swift test --package-path components/batch-source --filter PromptBuilderTests && swift test --package-path components/sender-source --filter QianniuSendTransactionTests`

- [ ] **Step 3: Add the same media rule to initial and continuation prompts**

```text
天猫回复可以在确有帮助时包含图片或视频 HTTPS 链接。链接必须逐字来自本轮查阅的可信知识库，不得编造、猜测、改写或打开链接。发送链接时用一句短说明标明内容；知识库没有可信链接时正常文字回答。
```

No URL rewriter and no post-generation approval gate.

- [ ] **Step 4: Run suites and commit**

Run: `swift test --package-path components/batch-source && swift test --package-path components/sender-source`

```bash
git add components/batch-source/Sources/CustomerReplyBatchAppSupport/PromptBuilder.swift components/batch-source/Tests/CustomerReplyBatchAppSupportTests/PromptBuilderTests.swift components/sender-source/Sources/QianniuSenderCore/QianniuSendTransaction.swift components/sender-source/Tests/QianniuSenderCoreTests/QianniuSendTransactionTests.swift
git commit -m "feat: allow trusted media links in tmall replies"
```

---

### Task 8: Show session and dynamic-worker status

**Files:**
- Modify: `Sources/AutoReplyCore/SchedulerModels.swift`
- Modify: `Sources/AutoReplyCore/AutoReplyScheduler.swift`
- Modify: `Sources/AutoReplyApp/AutoReplyFloatingProgress.swift`
- Modify: `Tests/AutoReplyCoreTests/SchedulerTests.swift`
- Modify: `Tests/AutoReplyAppTests/FloatingProgressPanelTests.swift`

**Interfaces:**
- Produces `generationCapacity`, per-UID session stage, and safe status events.

- [ ] **Step 1: Write failing presentation tests**

```swift
func testHeadlineShowsDynamicCapacityAndResume() {
    let text = headline(stage: "恢复客户会话 · 增量提交 2 条消息", active: 3, capacity: 10)
    XCTAssertTrue(text.contains("CLI 3/10"))
    XCTAssertTrue(text.contains("恢复客户会话"))
}
```

- [ ] **Step 2: Verify failure**

Run: `swift test --filter 'FloatingProgressPanelTests|SchedulerTests'`

- [ ] **Step 3: Add safe events and replace `/5` labels**

Display `新建客户会话`, `恢复客户会话`, `增量提交 N 条消息`, `会话过期，重载历史`, and `恢复失败，重建会话`. Never display session IDs, chat text, URLs, or reasoning. The overlay remains read-only and causes no OCR/UI work.

- [ ] **Step 4: Run tests and commit**

Run: `swift test --filter 'FloatingProgressPanelTests|SchedulerTests' && swift test && ! rg -n 'CLI .*?/5' Sources`

```bash
git add Sources/AutoReplyCore/SchedulerModels.swift Sources/AutoReplyCore/AutoReplyScheduler.swift Sources/AutoReplyApp/AutoReplyFloatingProgress.swift Tests/AutoReplyCoreTests/SchedulerTests.swift Tests/AutoReplyAppTests/FloatingProgressPanelTests.swift
git commit -m "feat: display per-user session lifecycle"
```

---

### Task 9: Package, benchmark, and validate with authorized self-accounts

**Files:**
- Modify: `README.md`
- Create: `docs/per-user-session-live-validation.md`
- Create at runtime: `output/千牛全自动客服-实验版.app`

**Interfaces:**
- Produces signed arm64 app, prompt-size/timing evidence, live delivery evidence, and rollback path.

- [ ] **Step 1: Run all non-live tests**

```bash
swift test --package-path components/batch-source
swift test --package-path components/sender-source
swift test --package-path components/ocr-source
swift test --package-path components/unread-source
swift test
python3 scripts/verify-baseline.py --self-test
```

Expected: PASS. Do not weaken the historical baseline manifest if it intentionally flags this new phase; verify Task 1's new snapshot separately.

- [ ] **Step 2: Benchmark two UIDs with ten turns each**

Record first-turn prompt bytes, median follow-up prompt bytes, session mode, wall time, and cross-UID mapping. Require median resumable prompt bytes below half the stateless fixture and zero cross-UID session reuse.

- [ ] **Step 3: Build and verify**

Run: `scripts/build-app.sh && codesign --verify --deep --strict --verbose=2 output/千牛全自动客服-实验版.app`

Run: `lipo -archs output/千牛全自动客服-实验版.app/Contents/MacOS/AutoReplyApp`

Expected: valid signature and exactly `arm64`; old output preserved under `output/previous-builds/`.

- [ ] **Step 4: Install without touching local history**

Stop the installed experimental app, move it to a timestamped recoverable backup, install the verified build, and preserve `/Users/scy/Desktop/AI客服记录-全自动版/用户` unchanged.

- [ ] **Step 5: Run Computer Use tests using only the two authorized self-accounts**

Verify: A first turn creates; A follow-up resumes; B overlaps independently; a new A message during generation never overlaps and supersedes stale output; forced one-hour expiry rehydrates; forced resume failure rebuilds once; image follow-up attaches only the new image; a KB-backed media URL arrives exactly in Tmall. Capture scheduler events, timings, and buyer-side arrival. Manual replies are not automation evidence.

- [ ] **Step 6: Document and commit evidence**

Record build hash, snapshot path, tests, prompt-byte comparison, timings, session lifecycle, media-link delivery, limitations, and rollback app path.

```bash
git add README.md docs/per-user-session-live-validation.md
git commit -m "docs: verify per-user tmall reply sessions"
```

- [ ] **Step 7: Final integrity review**

Run:

```bash
git diff --check HEAD~8..HEAD
git status --short
rg -n -- '--ephemeral|--last|CLI .*?/5' components/batch-source Sources
```

Expected: no whitespace errors, no `--last`, no customer-generation `--ephemeral`, no fixed `/5`. List unrelated pre-existing dirty files separately and leave them untouched.
