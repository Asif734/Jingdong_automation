# Verified Media Replies Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add verified Tmall/Taobao tutorial links, trusted time ranges, and up to two locally stored video screenshots to automatic Qianniu replies while preserving text-only behavior and scheduler progress.

**Architecture:** The existing V2 Python retriever builds a strict, cached media catalog from explicit evidence in the trusted knowledge-base ZIP and returns bounded structured candidates beside the unchanged text context. Codex may select one opaque media ID; Swift validates the selected record, renders only catalog-owned URLs/times, and passes a durable multipart plan to the scheduler. The scheduler confirms the text answer first, advances the customer cursor, then sends validated screenshots through a dedicated Qianniu image transaction without blocking global service on media failure.

**Tech Stack:** Swift 5.9, Swift Package Manager, Swift Concurrency, AppKit, macOS Accessibility API, NSPasteboard, Python 3.12, pytest/unittest, JSON Schema, SHA-256.

**Spec:** `docs/superpowers/specs/2026-08-28-verified-media-replies-design.md`

## Global Constraints

- Do not change unread detection, OCR parsing, customer identity rules, FIFO scheduling, frozen customer batches, per-user Codex sessions, or V2 text-answer ranking.
- Keep local Codex model `gpt-5.6-sol` and reasoning effort `medium`; do not call the OpenAI API.
- Send no more than one verified video and two verified screenshots per frozen customer batch.
- Do not permit model-authored URLs, timestamps, screenshot paths, model names, or platform substitutions.
- Tmall production replies may use only verified Tmall/Taobao HTTP or HTTPS resources.
- Text delivery succeeds independently of media delivery; media failure must not pause global unread scanning.
- Existing text-only scheduler records and CLI output without media IDs must remain decodable.
- Keep the current installed application recoverable; build and test only from the existing isolated worktree until acceptance passes.

---

## File Structure

### New files

- `Resources/V2Knowledge/media_catalog.py` — strict catalog construction, ZIP asset extraction, hashing, and candidate ranking.
- `Tests/V2KnowledgePythonTests/test_media_catalog.py` — Python catalog and candidate regression tests.
- `components/batch-source/Sources/CustomerReplyBatchAppSupport/VerifiedMediaPlanner.swift` — deterministic candidate validation and customer-facing rendering.
- `components/batch-source/Tests/CustomerReplyBatchAppSupportTests/VerifiedMediaPlannerTests.swift` — media planner tests.
- `components/sender-source/Sources/QianniuSenderCore/QianniuImageSendTransaction.swift` — image-only transactional sender state machine.
- `components/sender-source/Tests/QianniuSenderCoreTests/QianniuImageSendTransactionTests.swift` — image transaction tests.

### Modified files

- `Resources/V2Knowledge/retrieve_top12.py` — attach structured media candidates without changing text context ranking.
- `components/batch-source/Sources/CustomerReplyBatchAppSupport/V2KnowledgeRetriever.swift` — decode media candidates and pass a media cache directory.
- `components/batch-source/Sources/CustomerReplyBatchAppSupport/PromptBuilder.swift` — expose opaque candidate IDs and enforce selection rules.
- `components/batch-source/Sources/CustomerReplyBatchCore/QueueModels.swift` — decode optional selected media IDs in model replies.
- `components/batch-source/Sources/CustomerReplyBatchAppSupport/Resources/reply-output.schema.json` — permit at most one selected media ID.
- `components/batch-source/Sources/CustomerReplyBatchAppSupport/CLIReplyHandoff.swift` — accept both legacy four-key and new five-key replies.
- `components/batch-source/Sources/CustomerReplyBatchAppSupport/CodexReplyGenerator.swift` — resolve selected media before early handoff.
- `Sources/AutoReplyCore/SchedulerModels.swift` — persist the verified media plan and multipart progress.
- `Sources/AutoReplyCore/AutoReplyScheduler.swift` — deliver text first and media parts afterward.
- `Sources/AutoReplyApp/NativeAutomationDriver.swift` — bridge scheduler image delivery to native UI.
- `Sources/AutoReplyApp/LiveNativeUI.swift` — invoke the image transaction.
- `components/sender-source/Sources/QianniuSenderAppSupport/QianniuAXSession.swift` — place a validated image in the composer and verify the preview/send result.
- `Sources/AutoReplyApp/AutoReplyFloatingProgress.swift` — show media candidate, validation, and part delivery stages.
- `scripts/build-app.sh` — verify the new Python resource is packaged.
- Existing test files beside each modified target — compatibility, scheduler, UI, and packaging coverage.

---

### Task 1: Build a Strict Cached Media Catalog

**Files:**
- Create: `Resources/V2Knowledge/media_catalog.py`
- Create: `Tests/V2KnowledgePythonTests/test_media_catalog.py`
- Modify: `Resources/V2Knowledge/retrieve_top12.py`

**Interfaces:**
- Consumes: knowledge-base ZIP path, `KnowledgeIndex`, `QueryInfo`, and writable cache directory.
- Produces: `build_catalog(zip_path: Path, cache_root: Path) -> tuple[MediaRecord, ...]` and `retrieve_candidates(records, query, platform="tmall", limit=4) -> list[dict]`.

- [ ] **Step 1: Write failing catalog extraction tests**

Create a temporary ZIP containing one explicit Markdown section, one valid screenshot asset, and one ambiguous section. Require only the explicit section to become eligible:

```python
def test_catalog_requires_explicit_url_time_and_existing_same_video_screenshot(tmp_path):
    screenshot = b"trusted-image-bytes"
    markdown = """
## M880 不开机供电教程
- 适用型号：M880
- 适用问题：不开机、供电
- 天猫：https://cloud.video.taobao.com/vod/power.mp4
- 视频重点：00:50–00:54
- 截图1：assets/m880/power_52000ms.png。说明：检查电源指示灯。

## 模糊资料
- 视频可能有帮助：https://example.com/unknown.mp4
"""
    archive = tmp_path / "kb.zip"
    with zipfile.ZipFile(archive, "w") as output:
        output.writestr("qianniu_video_materials_kb.md", markdown)
        output.writestr("assets/m880/power_52000ms.png", screenshot)
    records = build_catalog(archive, tmp_path / "cache")
    assert len(records) == 1
    assert records[0].models == ("M880",)
    assert records[0].platform == "tmall"
    assert records[0].start_seconds == 50
    assert records[0].end_seconds == 54
    assert records[0].screenshots[0].sha256 == hashlib.sha256(screenshot).hexdigest()
```

Also test that missing assets, cross-platform-only links, and sections without explicit model/problem evidence become ineligible rather than guessed.

- [ ] **Step 2: Run the focused Python test and verify failure**

Run:

```bash
python3 -m unittest Tests/V2KnowledgePythonTests/test_media_catalog.py -v
```

Expected: FAIL because `media_catalog` does not exist.

- [ ] **Step 3: Implement strict parsing and content-addressed extraction**

Implement immutable dataclasses and helpers:

```python
@dataclass(frozen=True)
class MediaScreenshot:
    path: str
    timestamp_seconds: int
    caption: str
    sha256: str

@dataclass(frozen=True)
class MediaRecord:
    media_id: str
    brand: str
    models: tuple[str, ...]
    issues: tuple[str, ...]
    platform: str
    video_url: str
    start_seconds: int | None
    end_seconds: int | None
    screenshots: tuple[MediaScreenshot, ...]
    source_document: str
    source_ordinal: int
    source_sha256: str
    search_text: str
    evidence_level: str
```

Use `parse_markdown_sections` and `MODEL_RE` from `rag_b0.py`. Accept URLs only from explicit `天猫`/`天猫视频链接` labels, parse `MM:SS–MM:SS`, and accept screenshot paths only when the exact ZIP member exists under `assets/`. Extract accepted assets to:

```text
<cache_root>/verified-media/<zip_sha256>/<asset_sha256>-<safe-basename>
```

Create `media_id` from `zip_sha256 + document + ordinal + video_url`. Cache the final catalog as sorted JSON and rebuild only when the ZIP SHA-256 changes.

- [ ] **Step 4: Implement deterministic candidate filtering**

`retrieve_candidates` must:

```python
def retrieve_candidates(records, query, platform="tmall", limit=4):
    active = set(query.active_models)
    ranked = []
    for record in records:
        if record.platform != platform:
            continue
        exact_model = bool(active and active.intersection(record.models))
        if active and not exact_model:
            continue
        overlap = len(set(lexical_tokens(query.text)) & set(lexical_tokens(record.search_text)))
        if overlap == 0:
            continue
        ranked.append((exact_model, overlap, record.media_id, record))
    return [candidate_payload(row[-1], exact_model=row[0]) for row in sorted(ranked, reverse=True)[:limit]]
```

The payload contains catalog-owned URL/time/path data for Swift validation, but prompt rendering later exposes only ID and descriptive evidence.

- [ ] **Step 5: Attach candidates to V2 output without changing text context**

In `retrieve_top12.py`, call the catalog after the existing `focus` computation and add:

```python
"media_candidates": retrieve_candidates(
    build_catalog(zip_path, writable_cache), query, platform="tmall", limit=4
),
```

Do not modify `selected`, `focused_sections`, `compact_original_context`, ranking weights, or `MAX_CONTEXT_CHARACTERS`.

- [ ] **Step 6: Run Python tests**

Run:

```bash
python3 -m unittest discover -s Tests/V2KnowledgePythonTests -p 'test_*.py' -v
```

Expected: all Python retrieval and media catalog tests PASS.

- [ ] **Step 7: Commit**

```bash
git add Resources/V2Knowledge/media_catalog.py Resources/V2Knowledge/retrieve_top12.py Tests/V2KnowledgePythonTests/test_media_catalog.py
git commit -m "feat: build verified media catalog from knowledge evidence"
```

---

### Task 2: Decode and Prompt Opaque Media Candidates

**Files:**
- Modify: `components/batch-source/Sources/CustomerReplyBatchAppSupport/V2KnowledgeRetriever.swift`
- Modify: `components/batch-source/Sources/CustomerReplyBatchAppSupport/PromptBuilder.swift`
- Modify: `components/batch-source/Tests/CustomerReplyBatchAppSupportTests/V2KnowledgeRetrieverTests.swift`
- Modify: `components/batch-source/Tests/CustomerReplyBatchAppSupportTests/PromptBuilderTests.swift`

**Interfaces:**
- Consumes: Python `media_candidates` JSON.
- Produces: `RetrievedMediaCandidate`, `RetrievedMediaScreenshot`, `RetrievedKnowledge.mediaCandidates`, and `PromptInput.retrievedMediaCandidates`.

- [ ] **Step 1: Write failing Swift decoding tests**

Add a fixture result containing one candidate and assert complete decoding plus backward compatibility when the field is absent:

```swift
func testRetrievedKnowledgeDecodesOptionalMediaCandidates() throws {
    let data = Data(#"{"version":"v2-top12","documents":["kb.md"],"context":"evidence","media_candidates":[{"media_id":"m1","brand":"格志","models":["M880"],"issues":["不开机"],"platform":"tmall","video_url":"https://example.com/a.mp4","start_seconds":50,"end_seconds":54,"screenshots":[],"source_document":"kb.md","source_ordinal":2,"source_sha256":"abc","exact_model_match":true,"evidence_level":"complete"}]}"#.utf8)
    let value = try JSONDecoder().decode(RetrievedKnowledge.self, from: data)
    XCTAssertEqual(value.mediaCandidates.map(\.mediaID), ["m1"])
}
```

- [ ] **Step 2: Run focused tests and verify failure**

Run:

```bash
swift test --package-path components/batch-source --filter 'V2KnowledgeRetrieverTests|PromptBuilderTests'
```

Expected: FAIL because media candidate types and prompt fields are absent.

- [ ] **Step 3: Add Codable candidate models and compatibility decoder**

Define `RetrievedMediaScreenshot` and `RetrievedMediaCandidate` in `V2KnowledgeRetriever.swift`. Add `mediaCandidates` to `RetrievedKnowledge` and a custom decoder that defaults a missing `media_candidates` field to `[]`.

Add `mediaEnabled: Bool = false` to `V2KnowledgeRetriever`, include `"verified_media_replies": mediaEnabled` in the Python request, and change `retrieve_top12.py` to return an empty candidate array without building the catalog when the flag is false. Expose `V2KnowledgeRetriever.live(mediaEnabled: Bool = false)` so disabling the feature has no catalog I/O.

Add the candidate list to `PromptInput` and preserve it through `PromptBuilder.addingRetrievedKnowledge`.

- [ ] **Step 4: Render only safe candidate descriptors into the prompt**

Render a machine-readable block containing:

```text
media_id: m1
brand: 格志
models: M880
issues: 不开机
evidence_level: complete
has_verified_time: true
verified_screenshot_count: 1
```

Do not render `video_url`, absolute screenshot paths, or hashes to Codex. Add rules that Codex may return zero or one presented `media_id`, must keep the text answer complete, and must never write its own media URL/time/path.

- [ ] **Step 5: Run focused tests**

Run:

```bash
swift test --package-path components/batch-source --filter 'V2KnowledgeRetrieverTests|PromptBuilderTests'
```

Expected: PASS; prompt tests confirm IDs are present and URL/path/hash values are absent.

- [ ] **Step 6: Commit**

```bash
git add components/batch-source/Sources/CustomerReplyBatchAppSupport/V2KnowledgeRetriever.swift components/batch-source/Sources/CustomerReplyBatchAppSupport/PromptBuilder.swift components/batch-source/Tests/CustomerReplyBatchAppSupportTests/V2KnowledgeRetrieverTests.swift components/batch-source/Tests/CustomerReplyBatchAppSupportTests/PromptBuilderTests.swift
git commit -m "feat: expose opaque verified media candidates to Codex"
```

---

### Task 3: Extend the CLI Reply Contract Safely

**Files:**
- Modify: `components/batch-source/Sources/CustomerReplyBatchCore/QueueModels.swift`
- Modify: `components/batch-source/Sources/CustomerReplyBatchAppSupport/Resources/reply-output.schema.json`
- Modify: `components/batch-source/Sources/CustomerReplyBatchAppSupport/CLIReplyHandoff.swift`
- Modify: `components/batch-source/Tests/CustomerReplyBatchAppSupportTests/ReplySchemaTests.swift`
- Modify: `components/batch-source/Tests/CustomerReplyBatchAppSupportTests/EarlyReplyHandoffTests.swift`

**Interfaces:**
- Consumes: optional model output `selected_media_ids`.
- Produces: `ReplyEnvelope.selectedMediaIDs: [String]`, defaulting to `[]`.

- [ ] **Step 1: Write failing schema and stream tests**

Require the schema to accept zero or one nonempty ID, reject two IDs, and require no change for legacy output:

```swift
func testEarlyHandoffAcceptsOneSelectedMediaID() throws {
    let reply = #"{"decision":"auto_send","risk_level":"low","reply_text":"请检查电源。","reason":"普通排障","selected_media_ids":["m1"]}"#
    // Feed a completed agent_message and assert ready receives selectedMediaIDs == ["m1"].
}

func testLegacyReplyDefaultsToNoSelectedMedia() throws {
    let data = Data(#"{"decision":"auto_send","risk_level":"low","reply_text":"您好","reason":"普通咨询"}"#.utf8)
    XCTAssertEqual(try JSONDecoder().decode(ReplyEnvelope.self, from: data).selectedMediaIDs, [])
}
```

- [ ] **Step 2: Run focused tests and verify failure**

Run:

```bash
swift test --package-path components/batch-source --filter 'ReplySchemaTests|EarlyReplyHandoffTests'
```

Expected: FAIL because the schema and exact-key stream gate accept only four keys.

- [ ] **Step 3: Add the optional model field**

Extend `ReplyEnvelope` with a custom decoder:

```swift
public let selectedMediaIDs: [String]

selectedMediaIDs = try values.decodeIfPresent([String].self, forKey: .selectedMediaIDs) ?? []
```

Add `selected_media_ids` to the JSON Schema with `maxItems: 1`, `uniqueItems: true`, and nonempty string items. Do not make it required.

Extend the public initializer with `selectedMediaIDs: [String] = []` so all existing call sites compile unchanged.

- [ ] **Step 4: Update the early handoff key gate**

Accept exactly either the legacy key set or the legacy set plus `selected_media_ids`; continue rejecting every other extra key. Keep the `.autoSend`, nonempty text, final-answer phase, and running-item gates unchanged.

- [ ] **Step 5: Run focused tests**

Run:

```bash
swift test --package-path components/batch-source --filter 'ReplySchemaTests|EarlyReplyHandoffTests'
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add components/batch-source/Sources/CustomerReplyBatchCore/QueueModels.swift components/batch-source/Sources/CustomerReplyBatchAppSupport/Resources/reply-output.schema.json components/batch-source/Sources/CustomerReplyBatchAppSupport/CLIReplyHandoff.swift components/batch-source/Tests/CustomerReplyBatchAppSupportTests/ReplySchemaTests.swift components/batch-source/Tests/CustomerReplyBatchAppSupportTests/EarlyReplyHandoffTests.swift
git commit -m "feat: accept one opaque media selection in CLI replies"
```

---

### Task 4: Validate Media and Render the Final Text Locally

**Files:**
- Create: `components/batch-source/Sources/CustomerReplyBatchAppSupport/VerifiedMediaPlanner.swift`
- Create: `components/batch-source/Tests/CustomerReplyBatchAppSupportTests/VerifiedMediaPlannerTests.swift`
- Modify: `components/batch-source/Sources/CustomerReplyBatchAppSupport/CodexReplyGenerator.swift`
- Modify: `components/batch-source/Tests/CustomerReplyBatchAppSupportTests/CodexReplyGeneratorTests.swift`

**Interfaces:**
- Consumes: `ReplyEnvelope` and immutable `[RetrievedMediaCandidate]` from the same retrieval snapshot.
- Produces: `ResolvedReply(reply: ReplyEnvelope, mediaPlan: VerifiedMediaPlan?)` where rendered `replyText` contains only catalog-owned link/time and `mediaPlan` contains up to two validated screenshots.

- [ ] **Step 1: Write failing validator tests**

Cover accepted complete media, link-only fallback, unknown ID, wrong platform, absent file, wrong hash, two selected IDs, and cross-video screenshot data. A valid test must assert exact customer text:

```swift
func testPlannerRendersCatalogURLAndTimeAndKeepsTwoVerifiedScreenshots() throws {
    let resolved = try planner.resolve(
        reply: ReplyEnvelope(decision: .autoSend, riskLevel: .low,
            replyText: "亲，请检查电源指示灯。", reason: "普通排障", selectedMediaIDs: ["m1"]),
        candidates: [candidate]
    )
    XCTAssertEqual(resolved.reply.replyText,
        "亲，请检查电源指示灯。\n\n🎥 查看 M880 开机供电说明视频：https://example.com/m880.mp4\n建议观看 00:50–00:54。")
    XCTAssertEqual(resolved.mediaPlan?.screenshots.count, 2)
}
```

Invalid media must return the unchanged text reply and `mediaPlan == nil`; it must not throw away the answer.

- [ ] **Step 2: Run tests and verify failure**

Run:

```bash
swift test --package-path components/batch-source --filter VerifiedMediaPlannerTests
```

Expected: FAIL because the planner types do not exist.

- [ ] **Step 3: Implement planner value types and SHA-256 validation**

Define:

```swift
public struct VerifiedMediaScreenshot: Codable, Equatable, Sendable {
    public let path: String
    public let timestampSeconds: Int
    public let caption: String
    public let sha256: String
}

public struct VerifiedMediaPlan: Codable, Equatable, Sendable {
    public let mediaID: String
    public let videoURL: String
    public let startSeconds: Int?
    public let endSeconds: Int?
    public let screenshots: [VerifiedMediaScreenshot]
}
```

Initialize the planner as `VerifiedMediaPlanner(allowedCacheRoot: URL)`. Validate URL scheme/host, candidate platform, exact model match when the query contained a model, evidence level, local file containment under that resolved V2 cache root, file SHA-256, maximum count, and screenshot timestamp proximity to the selected range.

- [ ] **Step 4: Integrate planner before early reply handoff**

Preserve the retrieval snapshot in `preparedInput.retrievedMediaCandidates`. In `CodexReplyGenerator.runTurn`, wrap the streamed reply before `handoff.offer`:

```swift
let resolved = VerifiedMediaPlanner().resolveOrDrop(
    reply: reply,
    candidates: input.retrievedMediaCandidates
)
handoff.offer(generated(
    resolved.reply,
    mediaPlan: resolved.mediaPlan,
    sessionID: sessionID,
    exec: elapsed,
    decode: milliseconds(from: decodeStart, to: clock.now)
))
```

Add `mediaPlan` to `GeneratedReply`. Validation stays local and must not add a second model call.

- [ ] **Step 5: Run planner and generator tests**

Run:

```bash
swift test --package-path components/batch-source --filter 'VerifiedMediaPlannerTests|CodexReplyGeneratorTests|EarlyReplyHandoffTests'
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add components/batch-source/Sources/CustomerReplyBatchAppSupport/VerifiedMediaPlanner.swift components/batch-source/Sources/CustomerReplyBatchAppSupport/CodexReplyGenerator.swift components/batch-source/Tests/CustomerReplyBatchAppSupportTests/VerifiedMediaPlannerTests.swift components/batch-source/Tests/CustomerReplyBatchAppSupportTests/CodexReplyGeneratorTests.swift
git commit -m "feat: validate and render selected media outside the model"
```

---

### Task 5: Persist Multipart Progress and Preserve Text-First Semantics

**Files:**
- Modify: `Sources/AutoReplyCore/SchedulerModels.swift`
- Modify: `Sources/AutoReplyCore/AutoReplyScheduler.swift`
- Modify: `Tests/AutoReplyCoreTests/AutoReplySchedulerTests.swift`
- Modify: `Tests/AutoReplyCoreTests/SchedulerStoreTests.swift`

**Interfaces:**
- Consumes: `GeneratedReply.mediaPlan`.
- Produces: persisted `SchedulerRecord.mediaPlan`, `textDeliveryConfirmed`, and `mediaPartProgress`, plus `AutomationDriver.sendImage(uid:path:)`.

- [ ] **Step 1: Write failing scheduler tests**

Use a fake driver recording ordered actions. Assert:

```swift
XCTAssertEqual(driver.actions, [
    .sendText(uid: "buyer", text: expectedRenderedText),
    .sendImage(uid: "buyer", path: image1),
    .sendText(uid: "buyer", text: caption1),
    .sendImage(uid: "buyer", path: image2),
    .sendText(uid: "buyer", text: caption2),
])
```

Also assert:

- cursor advances immediately after confirmed text;
- a failed/uncertain image leaves the job completed with text delivery outcome `.sent` and records media error;
- another ready customer can send after media failure;
- restart skips confirmed parts and never repeats a part marked attempted-but-uncertain;
- legacy persisted records decode with empty media progress.

- [ ] **Step 2: Run scheduler tests and verify failure**

Run:

```bash
swift test --filter 'AutoReplySchedulerTests|SchedulerStoreTests'
```

Expected: FAIL because records and drivers are text-only.

- [ ] **Step 3: Add backward-compatible persisted progress**

Add optional/defaulted fields:

```swift
public var mediaPlan: VerifiedMediaPlan?
public var textDeliveryConfirmed: Bool?
public var mediaPartProgress: [MediaPartProgress]?

public struct MediaPartProgress: Codable, Equatable, Sendable {
    public let partID: String
    public var attempted: Bool
    public var confirmed: Bool
    public var uncertain: Bool
}
```

The decoder defaults missing values to no media and false/empty progress. Store the resolved plan when `received` transitions a record to `.ready`.

- [ ] **Step 4: Split delivery into text and media phases**

Keep the existing text transaction unchanged. After `.sent`, persist `textDeliveryConfirmed = true`, advance the answered cursor, and schedule any customer tail capture exactly as today. Then process media parts one at a time:

```swift
markPartAttempted(recordID, partID)
let result = await driver.sendImage(uid: record.uid, path: screenshot.path)
switch result {
case .sent:
    markPartConfirmed(recordID, partID)
    if !screenshot.caption.isEmpty { send caption with existing text transaction }
case .failedBeforeSend(let reason), .uncertain(let reason):
    closeRemainingMedia(recordID, reason: reason)
}
```

Do not regenerate the customer answer when media fails. Do not hold discovery after the media loop returns.

- [ ] **Step 5: Define restart behavior**

During `recoverInterruptedWork`:

- If `.sending` and `textDeliveryConfirmed != true`, retain existing uncertain text behavior.
- If text is confirmed, resume only unattempted media parts.
- If a media part was attempted but not confirmed, mark it uncertain and skip it to prevent duplication.

- [ ] **Step 6: Run scheduler tests**

Run:

```bash
swift test --filter 'AutoReplySchedulerTests|SchedulerStoreTests'
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/AutoReplyCore/SchedulerModels.swift Sources/AutoReplyCore/AutoReplyScheduler.swift Tests/AutoReplyCoreTests/AutoReplySchedulerTests.swift Tests/AutoReplyCoreTests/SchedulerStoreTests.swift
git commit -m "feat: persist text-first multipart reply delivery"
```

---

### Task 6: Add a Dedicated Qianniu Image Transaction

**Files:**
- Create: `components/sender-source/Sources/QianniuSenderCore/QianniuImageSendTransaction.swift`
- Create: `components/sender-source/Tests/QianniuSenderCoreTests/QianniuImageSendTransactionTests.swift`
- Modify: `components/sender-source/Sources/QianniuSenderAppSupport/QianniuAXSession.swift`
- Modify: `components/sender-source/Tests/QianniuSenderAppSupportTests/QianniuAXSessionTests.swift`
- Modify: `Sources/AutoReplyApp/NativeAutomationDriver.swift`
- Modify: `Sources/AutoReplyApp/LiveNativeUI.swift`

**Interfaces:**
- Consumes: validated local JPEG/PNG absolute path.
- Produces: `DeliveryResult` from `AutomationDriver.sendImage(uid:path:)`.

- [ ] **Step 1: Write failing image transaction state-machine tests**

Define a fake `QianniuImageSendingSession` and assert the exact sequence:

```swift
XCTAssertEqual(session.calls, [
    .activate,
    .searchAndOpen("buyer"),
    .currentChatUID,
    .setImageInput(imagePath),
    .currentChatUID,
    .recordMarker,
    .pressSend,
    .verifyImageSent,
])
```

Test wrong UID before paste, wrong UID after preview, paste failure, send exception, delayed confirmation, and no retry after uncertain send.

- [ ] **Step 2: Run sender tests and verify failure**

Run:

```bash
swift test --package-path components/sender-source --filter QianniuImageSendTransactionTests
```

Expected: FAIL because the image transaction does not exist.

- [ ] **Step 3: Implement the core image transaction**

Mirror the text transaction safety gates, but call:

```swift
func setImageInput(fileURL: URL) async throws
func verifyImagePreview() async throws -> Bool
func verifyImageSent() async throws -> Bool
func recheckImageSent() async throws -> Bool
```

Write an attempt marker containing UID, SHA-256, basename, and phase immediately before the send action; do not write raw image bytes into logs.

- [ ] **Step 4: Implement clipboard image placement in `QianniuAXSession`**

Validate file extension, decode `NSImage(contentsOf:)`, focus the resolved message input, place the `NSImage` on a private snapshot of `NSPasteboard.general`, post Command-V, and wait a bounded interval. Verify a new image/attachment node appears in the composer region before allowing `pressSend`.

Always restore the prior clipboard contents after paste preparation. Do not click chat images, product cards, or fixed screen coordinates.

- [ ] **Step 5: Implement image send confirmation**

Capture the outgoing chat evidence before paste and after send. Success requires exact UID plus disappearance of the composer preview and either a new outgoing image node or a stable cleared composer. Use the same bounded delayed recheck pattern as text sending; never click send twice.

- [ ] **Step 6: Bridge the root application**

Add `sendImage(uid:path:)` to `AutomationDriver`, `NativeUIAutomation`, `NativeAutomationDriver`, and `LiveNativeUI`. `LiveNativeUI` validates the path is a regular file before calling `QianniuImageSendTransaction`.

- [ ] **Step 7: Run sender and root tests**

Run:

```bash
swift test --package-path components/sender-source
swift test --filter 'NativeAutomationDriverTests|AutoReplySchedulerTests'
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add components/sender-source/Sources/QianniuSenderCore/QianniuImageSendTransaction.swift components/sender-source/Tests/QianniuSenderCoreTests/QianniuImageSendTransactionTests.swift components/sender-source/Sources/QianniuSenderAppSupport/QianniuAXSession.swift components/sender-source/Tests/QianniuSenderAppSupportTests/QianniuAXSessionTests.swift Sources/AutoReplyApp/NativeAutomationDriver.swift Sources/AutoReplyApp/LiveNativeUI.swift
git commit -m "feat: send validated image attachments through Qianniu"
```

---

### Task 7: Add Feature Flag, Status, and Packaging Checks

**Files:**
- Modify: `Sources/AutoReplyApp/AutomationAppModel.swift`
- Modify: `Sources/AutoReplyApp/AutoReplyFloatingProgress.swift`
- Modify: `Tests/AutoReplyAppTests/FloatingProgressPanelTests.swift`
- Modify: `scripts/build-app.sh`

**Interfaces:**
- Consumes: scheduler media events and application setting `verified_media_replies`.
- Produces: visible media stages and a test-time kill switch that restores text-only behavior.

- [ ] **Step 1: Write failing status and flag tests**

Assert the floating panel maps events to readable stages:

```swift
XCTAssertEqual(label(for: "Media candidates: 2"), "找到 2 个媒体候选")
XCTAssertEqual(label(for: "Media selected: m1"), "已选择并核验教程")
XCTAssertEqual(label(for: "Media screenshot 1 sent"), "截图 1 已发送")
XCTAssertEqual(label(for: "Media dropped: hash mismatch"), "媒体校验失败，已保留文字回复")
```

Also assert disabling the flag causes the generator to omit candidates and the scheduler to receive no media plan.

- [ ] **Step 2: Run focused tests and verify failure**

Run:

```bash
swift test --filter FloatingProgressPanelTests
```

Expected: FAIL because media stages are not mapped.

- [ ] **Step 3: Add the feature flag and event messages**

Read `UserDefaults.standard.object(forKey: "verified_media_replies") as? Bool ?? false` in `AutomationAppModel.live`. Pass the value to `V2KnowledgeRetriever.live(mediaEnabled:)`; the planner uses the same retriever cache root already encoded in candidate paths. During isolated acceptance, set it explicitly to true for the test build; do not change OCR or discovery configuration.

Emit concise scheduler events for candidate count, selected ID, validation drop, text sent, screenshot progress, and final media status.

- [ ] **Step 4: Add packaging assertions**

Require `Resources/V2Knowledge/media_catalog.py` before build and verify it exists inside the signed app. Keep all existing OCR and V2 resource checks.

- [ ] **Step 5: Run focused tests and build-script syntax check**

Run:

```bash
swift test --filter FloatingProgressPanelTests
zsh -n scripts/build-app.sh
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/AutoReplyApp/AutomationAppModel.swift Sources/AutoReplyApp/AutoReplyFloatingProgress.swift Tests/AutoReplyAppTests/FloatingProgressPanelTests.swift scripts/build-app.sh
git commit -m "feat: expose verified media reply progress and kill switch"
```

---

### Task 8: Full Regression, Blind Evaluation, Build, and Computer Use Acceptance

**Files:**
- Modify only if failures reveal an implementation defect in files already listed above.
- Create: `Tests/V2KnowledgePythonTests/verified-media-evaluation.json`
- Create: `Tests/V2KnowledgePythonTests/verified-media-acceptance-report.json`

**Interfaces:**
- Consumes: completed feature implementation and frozen current application.
- Produces: automated evidence, latency comparison, signed isolated app, and real-account acceptance evidence.

- [ ] **Step 1: Run all automated suites**

Run:

```bash
swift test
swift test --package-path components/batch-source
swift test --package-path components/sender-source
swift test --package-path components/ocr-source
swift test --package-path components/unread-source
python3 -m unittest discover -s Tests/V2KnowledgePythonTests -p 'test_*.py' -v
```

Expected: all tests PASS; explicit real-Codex tests may skip only when their documented environment flag is absent.

- [ ] **Step 2: Run a blind text-only regression**

Use the existing fixed hard-question set plus at least 60 no-media questions. Randomize answer labels before scoring. Compare feature-off and feature-on answers for correctness and measure local retrieval overhead. Acceptance:

```text
No-media accuracy regression: 0 accepted failures attributable to media changes
No-media added local median latency: <= 200 ms
Fabricated media fields: 0
```

Save question ID, hidden variant label, timings, score, and judge reason to `verified-media-evaluation.json`.

- [ ] **Step 3: Run adversarial media cases**

Test exact video, link-only, one screenshot, two screenshots, missing screenshot, wrong hash, wrong model, wrong platform, similar model, malicious customer URL, malicious attachment text, multi-question batch, and later troubleshooting step. Require zero mismatched or fabricated assets.

- [ ] **Step 4: Build and verify the signed isolated app**

Run:

```bash
./scripts/build-app.sh
codesign --verify --deep --strict --verbose=2 output/千牛全自动客服-实验版.app
```

Expected: build succeeds and signature verification passes.

- [ ] **Step 5: Freeze the currently installed app before replacement**

Copy `/Applications/千牛全自动客服-实验版.app` to a timestamped backup under `output/installed-previous-builds/` using `ditto`, verify its bundle identifier, and record its path. Do not delete or overwrite the backup.

- [ ] **Step 6: Install and enable only the isolated test build**

Install the newly signed app, set `verified_media_replies=true`, launch it, and verify Accessibility and Screen Recording permissions use the same stable bundle identifier/signature.

- [ ] **Step 7: Perform Computer Use acceptance with test buyer accounts**

Run these user-visible cases:

1. text only;
2. text plus verified video/time;
3. text plus one screenshot and caption;
4. text plus two screenshots and captions;
5. new customer message arriving during multipart delivery;
6. second customer unread while first media is sending;
7. Qianniu initially backgrounded;
8. image file removed before send;
9. repeat warning;
10. application restart between media parts.

For every case, compare Qianniu chat, scheduler state, media part journal, and local customer history. Never use real customers.

- [ ] **Step 8: Save acceptance evidence**

Write `verified-media-acceptance-report.json` with build hash, app signature, test case, expected result, actual result, timings, sent asset hashes, and final scheduler state. Do not store customer secrets.

- [ ] **Step 9: Re-run full automated suites after any acceptance fix**

If any implementation file changes during Computer Use acceptance, repeat Step 1 and rebuild before claiming completion.

- [ ] **Step 10: Commit final evidence**

```bash
git add Tests/V2KnowledgePythonTests/verified-media-evaluation.json Tests/V2KnowledgePythonTests/verified-media-acceptance-report.json
git commit -m "test: verify end-to-end media reply delivery"
```
