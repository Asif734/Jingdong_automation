# V2 Persistent Retriever Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace per-question V2 Python cold starts with one supervised persistent worker, versioned reusable indexes, and a production failure path that never exposes the full knowledge-base ZIP to Codex.

**Architecture:** Python owns a stateless `RetrieverEngine`, persistent lexical artifacts, and a JSONL worker protocol. Swift owns the worker process lifecycle, one-restart-per-query policy, startup status, and production fail-closed behavior. Packaging provides a trusted knowledge manifest so warm launches can select an index without hashing 228 MB again.

**Tech Stack:** Swift 5.9 actors and `Process`, Foundation pipes/JSON, Python 3.12, SQLite FTS5, FastEmbed/ONNX Runtime, NumPy, XCTest, Python `unittest`.

**Spec:** `docs/superpowers/specs/2026-08-31-v2-persistent-retriever-design.md`

## Global Constraints

- Preserve `BAAI/bge-small-zh-v1.5`, all ranking weights/constants, pinned/media rules, Top-12 selection, section caps, and 36,000-character context limit.
- Do not modify OCR, customer identity selection, foreground activation, Enter sending, FIFO, Codex model, reasoning effort, or customer-service Prompt wording.
- Production must never fall back to passing `knowledgeBasePaths` to Codex.
- A customer query may restart the worker at most once; the service may recover indefinitely in the background.
- Do not delete existing customer records, logs, knowledge ZIPs, or indexes.
- Every production change follows a witnessed RED → GREEN test cycle.

---

### Task 1: Extract a reusable stateless-query `RetrieverEngine`

**Files:**
- Modify: `Resources/V2Knowledge/retrieve_top12.py`
- Modify: `Tests/V2KnowledgePythonTests/test_retrieve_top12.py`

**Interfaces:**
- Consumes: existing `KnowledgeIndex`, `SemanticDocumentIndex`, ranking helpers, and request dictionary.
- Produces: `RetrieverEngine(lexical, semantic)`; `RetrieverEngine.from_paths(zip_path, writable_cache)`; `query(history_jsonl) -> dict`; compatible `retrieve(request) -> dict`.

- [ ] **Step 1: Write a failing parity/lifecycle test**

Add a test that replaces `KnowledgeIndex.build` and `SemanticDocumentIndex.build` with counting fakes, constructs one engine, calls `query()` twice, and asserts each build count is exactly one. Add a parity test comparing the old one-shot result fixture with `RetrieverEngine.query()` for the same history.

```python
engine = RetrieverEngine.from_paths(knowledge_base, writable_cache)
first = engine.query(history_jsonl)
second = engine.query(history_jsonl)
self.assertEqual(first, second)
self.assertEqual(build_counts, {"lexical": 1, "semantic": 1})
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
python3 -m unittest Tests/V2KnowledgePythonTests/test_retrieve_top12.py -v
```

Expected: FAIL because `RetrieverEngine` does not exist.

- [ ] **Step 3: Implement the minimal engine extraction**

Move only the per-query portion of current `retrieve()` into `RetrieverEngine.query()`. Keep constants and ranking expressions byte-for-byte equivalent. Make `retrieve(request)` construct an engine and call it once so existing callers remain compatible.

```python
class RetrieverEngine:
    def __init__(self, lexical, semantic):
        self.lexical = lexical
        self.semantic = semantic

    @classmethod
    def from_paths(cls, zip_path, writable_cache):
        lexical = KnowledgeIndex.build(zip_path)
        semantic = SemanticDocumentIndex.build(lexical.sections, writable_cache)
        return cls(lexical, semantic)

    def query(self, history_jsonl):
        history = load_history(history_jsonl)
        # existing ranking body, unchanged
```

- [ ] **Step 4: Run focused and full V2 Python tests**

Run:

```bash
python3 -m unittest discover -s Tests/V2KnowledgePythonTests -v
```

Expected: PASS, with existing retrieval outputs unchanged.

- [ ] **Step 5: Commit the isolated refactor**

```bash
git add Resources/V2Knowledge/retrieve_top12.py Tests/V2KnowledgePythonTests/test_retrieve_top12.py
git commit -m "refactor: extract reusable V2 retriever engine"
```

### Task 2: Add versioned persistent lexical artifacts

**Files:**
- Modify: `Resources/V2Knowledge/rag_b0.py`
- Create: `Tests/V2KnowledgePythonTests/test_persistent_index.py`

**Interfaces:**
- Consumes: `Section`, `KnowledgeIndex`, a trusted 64-character `knowledge_sha256`, and an `index_root` directory.
- Produces: `KnowledgeIndex.load_or_build(zip_path, index_root, knowledge_sha256, algorithm_version) -> KnowledgeIndex`; directory containing `manifest.json`, `sections.jsonl`, `lexical.sqlite`, and `ready.marker`.

- [ ] **Step 1: Write failing build/load/corruption tests**

Use a tiny ZIP containing two Markdown documents. First call must create all four artifacts. Patch `zipfile.ZipFile` to fail on the second call and assert the index still loads. Delete `ready.marker` and assert the next call rebuilds from ZIP. Change `algorithm_version` and assert a different version directory is selected.

```python
first = KnowledgeIndex.load_or_build(kb, root, digest, "v2-index-1")
with mock.patch("rag_b0.zipfile.ZipFile", side_effect=AssertionError("ZIP reopened")):
    second = KnowledgeIndex.load_or_build(kb, root, digest, "v2-index-1")
self.assertEqual(first.sections, second.sections)
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
python3 -m unittest Tests/V2KnowledgePythonTests/test_persistent_index.py -v
```

Expected: FAIL because `load_or_build` does not exist.

- [ ] **Step 3: Implement deterministic section serialization and atomic build**

Serialize every `Section` field explicitly. Build in `<version>.building-<uuid>`, close/sync SQLite, write the manifest, write `ready.marker` last, then rename to `<knowledge_sha256>-<algorithm_version>`. Loading validates every manifest field before opening SQLite.

```python
payload = {
    "document": section.document,
    "ordinal": section.ordinal,
    "heading_path": list(section.heading_path),
    "body": section.body,
    "context": section.context,
    "models": list(section.models),
    "heading_models": list(section.heading_models),
}
```

- [ ] **Step 4: Run persistent-index and existing Python tests**

Run:

```bash
python3 -m unittest discover -s Tests/V2KnowledgePythonTests -v
```

Expected: PASS.

- [ ] **Step 5: Commit the persistent index**

```bash
git add Resources/V2Knowledge/rag_b0.py Tests/V2KnowledgePythonTests/test_persistent_index.py
git commit -m "feat: persist V2 lexical index artifacts"
```

### Task 3: Add the long-running JSONL Python worker and lexical-only degradation

**Files:**
- Modify: `Resources/V2Knowledge/retrieve_top12.py`
- Create: `Resources/V2Knowledge/serve_top12.py`
- Create: `Tests/V2KnowledgePythonTests/test_serve_top12.py`
- Modify: `scripts/build-app.sh`

**Interfaces:**
- Consumes: `RetrieverEngine`, trusted knowledge SHA, index root, cache root, JSONL stdin.
- Produces: `serve(engine, input_stream, output_stream)` and protocol records `{type:"ready", version:...}`, `{id, ok:true, result}`, `{id, ok:false, error}`.

- [ ] **Step 1: Write failing protocol tests**

Use `StringIO` plus a counting fake engine. Assert one ready line, matching response IDs, two successful queries, and one malformed request error followed by another successful request. Add a fake semantic failure and assert `version == "v2-lexical-only"` with bounded context and no `.zip` path.

```python
serve(fake_engine, StringIO('{"id":"a","history_jsonl":"..."}\n'), output)
records = [json.loads(line) for line in output.getvalue().splitlines()]
self.assertEqual(records[1]["id"], "a")
self.assertTrue(records[1]["ok"])
```

- [ ] **Step 2: Run the worker test and verify RED**

Run:

```bash
python3 -m unittest Tests/V2KnowledgePythonTests/test_serve_top12.py -v
```

Expected: FAIL because `serve_top12` does not exist.

- [ ] **Step 3: Implement the worker and lexical-only engine path**

Keep protocol JSON exclusively on stdout and diagnostics on stderr. Add `RetrieverEngine.query_lexical_only()` using the existing lexical rank/model-route rules and the same context limiter; it must never return a filesystem path.

```python
for line in input_stream:
    request = json.loads(line)
    request_id = request["id"]
    try:
        result = engine.query(request["history_jsonl"])
        emit({"id": request_id, "ok": True, "result": result})
    except Exception as error:
        emit({"id": request_id, "ok": False, "error": str(error)})
```

Update packaging validation so the built App must contain `serve_top12.py`.

- [ ] **Step 4: Run worker, full Python, and packaging fixture tests**

Run:

```bash
python3 -m unittest discover -s Tests/V2KnowledgePythonTests -v
bash Tests/Packaging/app_icon_test.sh
```

Expected: PASS.

- [ ] **Step 5: Commit the worker**

```bash
git add Resources/V2Knowledge/retrieve_top12.py Resources/V2Knowledge/serve_top12.py Tests/V2KnowledgePythonTests/test_serve_top12.py scripts/build-app.sh
git commit -m "feat: add persistent V2 JSONL worker"
```

### Task 4: Generate and install a trusted knowledge manifest

**Files:**
- Modify: `scripts/build-app.sh`
- Modify: `Sources/AutoReplyApp/PortableRuntimeResources.swift`
- Modify: `Tests/AutoReplyAppTests/PortableRuntimeResourcesTests.swift`

**Interfaces:**
- Consumes: bundled `Grozziie-China-KB.zip` and its build-time SHA-256.
- Produces: bundled `KnowledgeBase/manifest.json`; `PortableRuntimeResources.knowledgeBaseSHA256`; `indexRootURL`; atomically synchronized local ZIP/manifest.

- [ ] **Step 1: Write failing install/update tests**

Cover first install, identical manifest preserving the existing file, changed manifest atomically replacing the local file, malformed SHA rejection, and returned `indexRootURL`.

```swift
let first = try PortableRuntimeResources.resolve(...)
XCTAssertEqual(first.knowledgeBaseSHA256, expectedHash)
try Data("new bundled kb".utf8).write(to: seedKnowledge)
// update manifest, resolve again, assert current.zip now equals new bytes
```

- [ ] **Step 2: Run focused Swift test and verify RED**

Run:

```bash
swift test --filter PortableRuntimeResourcesTests
```

Expected: FAIL because manifest fields and update behavior do not exist.

- [ ] **Step 3: Implement manifest generation and atomic synchronization**

`build-app.sh` writes compact JSON containing `knowledge_sha256` and `index_algorithm_version`. Runtime validates the 64 lowercase hex hash, copies to a sibling temporary file, verifies bytes once, then uses `replaceItemAt`/rename and writes the local manifest atomically.

```swift
struct BundledKnowledgeManifest: Decodable {
    let knowledgeSHA256: String
    let indexAlgorithmVersion: String
}
```

- [ ] **Step 4: Run focused tests and build-script static checks**

Run:

```bash
swift test --filter PortableRuntimeResourcesTests
bash -n scripts/build-app.sh
```

Expected: PASS.

- [ ] **Step 5: Commit manifest handling**

```bash
git add scripts/build-app.sh Sources/AutoReplyApp/PortableRuntimeResources.swift Tests/AutoReplyAppTests/PortableRuntimeResourcesTests.swift
git commit -m "feat: version packaged knowledge resources"
```

### Task 5: Replace one-shot Swift retrieval with a supervised persistent worker

**Files:**
- Create: `components/batch-source/Sources/CustomerReplyBatchAppSupport/PersistentJSONLWorker.swift`
- Modify: `components/batch-source/Sources/CustomerReplyBatchAppSupport/V2KnowledgeRetriever.swift`
- Modify: `components/batch-source/Tests/CustomerReplyBatchAppSupportTests/V2KnowledgeRetrieverTests.swift`

**Interfaces:**
- Consumes: bundled Python and `serve_top12.py`, knowledge SHA, cache/index roots.
- Produces: `V2KnowledgeRetriever.prepare() async throws`; persistent `retrieve(...)`; `shutdown()`; `V2RetrievalStatus` values `stopped`, `starting`, `ready`, `lexicalOnly`, `recovering(String)`.

- [ ] **Step 1: Write failing single-process and one-restart tests**

Create an executable fake Python worker script that appends one line to a launch-count file, emits ready, echoes valid JSON responses, and optionally exits on the first query. Assert two retrieves launch once; crash mode launches exactly twice and returns after one retry; permanent crash launches exactly twice and throws.

```swift
try await retriever.prepare()
_ = try await retriever.retrieve(historyJSONL: first, knowledgeBasePaths: [zip.path])
_ = try await retriever.retrieve(historyJSONL: second, knowledgeBasePaths: [zip.path])
XCTAssertEqual(try launchCount(), 1)
```

- [ ] **Step 2: Run focused test and verify RED**

Run:

```bash
swift test --package-path components/batch-source --filter V2KnowledgeRetrieverTests
```

Expected: FAIL because `prepare`, persistent pipes, and restart policy do not exist.

- [ ] **Step 3: Implement the process owner and actor lifecycle**

`PersistentJSONLWorker` is the only owner of `Process`, stdin, stdout, and stderr. Because `V2KnowledgeRetriever` is an actor, requests remain serialized. Each response ID must match the sent request ID. A timeout terminates the worker so a blocked reader is released. Error text uses configured duration, never a hard-coded “5 秒”.

```swift
public func retrieve(...) async throws -> RetrievedKnowledge {
    for attempt in 0...1 {
        do {
            try await prepare()
            return try await request(historyJSONL: historyJSONL)
        } catch where attempt == 0 {
            await resetWorker(status: .recovering(error.localizedDescription))
        }
    }
    throw lastError
}
```

- [ ] **Step 4: Run component tests**

Run:

```bash
swift test --package-path components/batch-source
```

Expected: PASS.

- [ ] **Step 5: Commit persistent Swift worker**

```bash
git add components/batch-source/Sources/CustomerReplyBatchAppSupport/PersistentJSONLWorker.swift components/batch-source/Sources/CustomerReplyBatchAppSupport/V2KnowledgeRetriever.swift components/batch-source/Tests/CustomerReplyBatchAppSupportTests/V2KnowledgeRetrieverTests.swift
git commit -m "feat: supervise one persistent V2 worker"
```

### Task 6: Remove the production full-ZIP fallback

**Files:**
- Modify: `components/batch-source/Sources/CustomerReplyBatchAppSupport/CodexReplyGenerator.swift`
- Modify: `components/batch-source/Tests/CustomerReplyBatchAppSupportTests/CodexReplyGeneratorTests.swift`
- Modify: `Sources/AutoReplyApp/AutomationAppModel.swift`
- Modify: `Tests/AutoReplyAppTests/AutomationAppModelTests.swift`

**Interfaces:**
- Consumes: `KnowledgeContextRetrieving` returning `v2-top12` or `v2-lexical-only`.
- Produces: production `.failClosed` policy; no Codex invocation after retrieval failure; no full ZIP path in a production Prompt.

- [ ] **Step 1: Replace the existing fallback expectation with failing fail-closed tests**

Add a generator test using a throwing retriever and a fake Codex executable marker. Assert generation throws and the Codex marker is absent. Change the app test to require `.failClosed`.

```swift
await XCTAssertThrowsErrorAsync {
    _ = try await generator.generate(for: input)
}
XCTAssertFalse(FileManager.default.fileExists(atPath: codexMarker.path))
```

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```bash
swift test --filter AutomationAppModelTests.testLiveConfigurationNeverFallsBackToFullKnowledgeBase
swift test --package-path components/batch-source --filter CodexReplyGeneratorTests
```

Expected: FAIL because production still uses `.fallbackToFullInput`.

- [ ] **Step 3: Set production to fail closed and accept bounded lexical mode**

Set `liveKnowledgeRetrievalFailurePolicy = .failClosed`. Validate worker results against an allowlist of `v2-top12` and `v2-lexical-only`; both must contain nonempty context. Keep generic fallback support only for non-production compatibility until its callers are migrated, but make the live path impossible to select it.

- [ ] **Step 4: Run main and component tests**

Run:

```bash
swift test
swift test --package-path components/batch-source
```

Expected: PASS.

- [ ] **Step 5: Commit production fail-closed behavior**

```bash
git add components/batch-source/Sources/CustomerReplyBatchAppSupport/CodexReplyGenerator.swift components/batch-source/Tests/CustomerReplyBatchAppSupportTests/CodexReplyGeneratorTests.swift Sources/AutoReplyApp/AutomationAppModel.swift Tests/AutoReplyAppTests/AutomationAppModelTests.swift
git commit -m "fix: prevent full knowledge ZIP fallback"
```

### Task 7: Prewarm the worker and expose retrieval state without blocking UI work

**Files:**
- Modify: `Sources/AutoReplyApp/AutomationAppModel.swift`
- Modify: `Sources/AutoReplyApp/AutoReplyApplication.swift`
- Modify: `Sources/AutoReplyApp/AutoReplyFloatingProgress.swift`
- Modify: `Tests/AutoReplyAppTests/AutomationAppModelTests.swift`
- Modify: `Tests/AutoReplyAppTests/FloatingProgressPanelTests.swift`

**Interfaces:**
- Consumes: the same `V2KnowledgeRetriever` instance passed to `CodexReplyGenerator`.
- Produces: `@Published retrievalStatusText`; startup prewarm Task; background retry delays `1,2,5,10,30,60...`; no UI lease held by prewarm.

- [ ] **Step 1: Write failing status and retry-policy tests**

Inject a `KnowledgePreparing` fake that fails twice then succeeds. Start the model and assert status transitions `启动中 → 后台恢复 → 已就绪`, scheduler remains responsive, and delays are `1,2`. Add a pure presentation test for lexical-only and recovering labels.

```swift
model.start()
await fulfillment(of: [readyExpectation], timeout: 1)
XCTAssertEqual(model.retrievalStatusText, "知识库检索已就绪")
XCTAssertEqual(recordedSleeps, [1, 2])
```

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```bash
swift test --filter AutomationAppModelTests
swift test --filter FloatingProgressPanelTests
```

Expected: FAIL because the model has no retrieval prewarmer/status.

- [ ] **Step 3: Implement shared prewarm and capped background recovery**

Create the retriever once in `live()`, pass it both to generator and model. Starting/resuming launches a MainActor-owned retry Task that calls `prepare()` without acquiring any QianNiu UI lease. Stopping cancels the retry Task but may leave a ready worker alive. Termination calls `shutdown()`.

```swift
private func startRetrievalRecovery() {
    retrievalTask = Task { [weak self] in
        var failures = 0
        while !Task.isCancelled {
            let schedule: [TimeInterval] = [0, 1, 2, 5, 10, 30, 60]
            let delay = schedule[min(failures, schedule.count - 1)]
            if delay > 0 { await self?.retrySleep(delay) }
            do {
                try await self?.knowledgePreparer.prepare()
                await self?.setRetrievalStatus(.ready)
                return
            } catch {
                failures += 1
                await self?.setRetrievalStatus(.recovering(error.localizedDescription))
            }
        }
    }
}
```

Render `retrievalStatusText` in the main and floating windows.

- [ ] **Step 4: Run main tests**

Run:

```bash
swift test
```

Expected: PASS.

- [ ] **Step 5: Commit prewarm/status behavior**

```bash
git add Sources/AutoReplyApp/AutomationAppModel.swift Sources/AutoReplyApp/AutoReplyApplication.swift Sources/AutoReplyApp/AutoReplyFloatingProgress.swift Tests/AutoReplyAppTests/AutomationAppModelTests.swift Tests/AutoReplyAppTests/FloatingProgressPanelTests.swift
git commit -m "feat: prewarm and report V2 retrieval service"
```

### Task 8: Parity, performance, packaging, and installation verification

**Files:**
- Create: `Tests/V2KnowledgePythonTests/test_persistent_retrieval_parity.py`
- Modify: `Tests/Packaging/verify_baseline_test.py`
- Modify: `docs/把这个文件交给Codex-项目完整接管与Debug手册.md`

**Interfaces:**
- Consumes: built App, real bundled knowledge ZIP/cache, legacy one-shot retriever, persistent worker.
- Produces: parity hashes, cold/warm timing evidence, packaging assertions, updated operator diagnostics.

- [ ] **Step 1: Write failing packaging and parity assertions**

Assert the App contains `serve_top12.py` and knowledge manifest. For each existing frozen V2 fixture, compare one-shot and persistent `documents` plus SHA-256 of `context`. Add instrumentation to assert one worker PID and no ZIP open after ready across 100 queries.

```python
self.assertEqual(legacy["documents"], persistent["documents"])
self.assertEqual(sha256(legacy["context"]), sha256(persistent["context"]))
self.assertEqual(metrics["zip_opens_after_ready"], 0)
```

- [ ] **Step 2: Run parity/packaging tests and verify RED if any contract is missing**

Run:

```bash
python3 -m unittest Tests/V2KnowledgePythonTests/test_persistent_retrieval_parity.py -v
python3 Tests/Packaging/verify_baseline_test.py
```

Expected before final integration: any missing metric or packaged resource assertion fails.

- [ ] **Step 3: Add only the required instrumentation and handbook updates**

Document status meanings, index location, worker restart policy, how to identify lexical-only mode, and the invariant that CLI traces must not contain configured-knowledge-base unzip commands.

- [ ] **Step 4: Run the complete verification matrix**

Run:

```bash
python3 -m unittest discover -s Tests/V2KnowledgePythonTests -v
swift test --package-path components/batch-source
swift test
git diff --check
```

Build with the existing portable runtime, knowledge ZIP, Python framework, and ad-hoc signing environment. Then run `plutil -lint`, `codesign --verify --deep --strict`, and compare the built/installed executable SHA-256.

- [ ] **Step 5: Preserve the installed old build and install the verified new build**

Stop the running old app only at this point. Copy the existing installed App into the timestamped preservation directory already used by this worktree, install the new App, restore required macOS permissions if its signature identity changed, and leave automatic sending stopped until the user separately approves the live-message test.

- [ ] **Step 6: Run one action-time-confirmed live test**

After explicit user confirmation, start automation, verify target `tb263147182`, receive one new small-account message, and confirm the chain: capture → retrieval mode/timing → Codex → composer → one Enter → visible sent reply/confirmation. Do not manually send on behalf of the program.

- [ ] **Step 7: Commit final verification assets and documentation**

```bash
git add Tests/V2KnowledgePythonTests/test_persistent_retrieval_parity.py Tests/Packaging/verify_baseline_test.py docs/把这个文件交给Codex-项目完整接管与Debug手册.md
git commit -m "test: verify persistent V2 retrieval delivery"
```
