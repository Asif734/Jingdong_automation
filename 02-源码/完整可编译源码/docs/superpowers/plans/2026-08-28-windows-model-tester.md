# Windows 格志客服模型测试器 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 构建一个 Windows 10/11 x64 可携带客服模型模拟器，复用当前知识库、V2 top12 检索、`gpt-5.6-sol` 和 `medium` 推理合同，但不包含任何千牛自动化。

**Architecture:** 自包含 Windows .NET 启动器启动内置 CPython 后端，后端仅监听 `127.0.0.1` 并提供离线浏览器 UI。Python 业务层负责聊天存储、原样 V2 检索和原生 Windows Codex CLI 的 `exec`/`resume` 调用；构建脚本从 Mac 生成 Windows x64 便携 ZIP，并通过假 Codex 与资源审计完成跨平台可执行验证。

**Tech Stack:** .NET 8 self-contained win-x64 launcher, CPython 3.12 embeddable, Python 3.12 standard-library HTTP server, vanilla HTML/CSS/JavaScript, Codex CLI JSONL, ONNX Runtime/FastEmbed V2 retrieval, Python `unittest`.

**Spec:** `docs/superpowers/specs/2026-08-28-windows-model-tester-design.md`

## Global Constraints

- Target is Windows 10/11 x64 only.
- Artifact is `格志客服模型测试器-Windows-x64.zip`; launch entry is `格志客服模型测试器.exe`.
- Model is exactly `gpt-5.6-sol`; reasoning effort is exactly `medium`.
- Authentication is the local user's saved ChatGPT Codex login only; strip `OPENAI_API_KEY` and `CODEX_API_KEY` for every invocation.
- Retrieval is exactly `v2-top12` with the current knowledge ZIP, current retrieval scripts, and current seed cache.
- Do not include Qianniu, OCR, unread-dot scanning, queues, or automatic sending.
- Do not change the macOS tester or production assistant algorithms.
- Server binds only to `127.0.0.1`; no external CDN or hosted service.
- No auth files, API keys, Mac binaries, or `.app` payload may enter the Windows ZIP.

---

## File Structure

- `components/windows-model-tester-source/app/model.py`: immutable request/response and conversation dataclasses.
- `components/windows-model-tester-source/app/conversation_store.py`: atomic JSONL, image, and session persistence.
- `components/windows-model-tester-source/app/prompt_builder.py`: frozen initial/continuation customer-service prompts.
- `components/windows-model-tester-source/app/knowledge_retriever.py`: adapter around copied `retrieve_top12.py` plus fallback diagnostics.
- `components/windows-model-tester-source/app/codex_runner.py`: native Windows Codex discovery, login validation, command construction, JSONL parsing, and session handling.
- `components/windows-model-tester-source/app/service.py`: use-case orchestration and optimistic conversation-version gate.
- `components/windows-model-tester-source/app/server.py`: localhost HTTP/static/upload boundary and shutdown protocol.
- `components/windows-model-tester-source/web/index.html`: accessible static UI shell.
- `components/windows-model-tester-source/web/app.js`: API client, chat rendering, upload/drop, retry, and diagnostics.
- `components/windows-model-tester-source/web/styles.css`: responsive Windows browser UI.
- `components/windows-model-tester-source/launcher/GrozziieModelTesterLauncher.csproj`: self-contained win-x64 build contract.
- `components/windows-model-tester-source/launcher/Program.cs`: resource validation, child lifecycle, browser launch, and log surface.
- `components/windows-model-tester-source/resources/reply-output.schema.json`: copied structured reply contract.
- `components/windows-model-tester-source/resources/customer-reply-prompt.md`: canonical prompt text used by parity tests.
- `components/windows-model-tester-source/requirements-windows.lock`: exact Windows Python wheels and hashes.
- `components/windows-model-tester-source/scripts/build-windows-package.py`: deterministic resource acquisition, extraction, audit, manifest, and ZIP creation.
- `components/windows-model-tester-source/scripts/run-python-tests.sh`: host-Python test entry point.
- `components/windows-model-tester-source/tests/`: Python unit, integration, parity, and package audit tests.
- `components/windows-model-tester-source/README-Windows.txt`: end-user setup and troubleshooting.

### Task 1: Freeze the Cross-Platform Contract

**Files:**
- Create: `components/windows-model-tester-source/app/model.py`
- Create: `components/windows-model-tester-source/app/prompt_builder.py`
- Create: `components/windows-model-tester-source/resources/customer-reply-prompt.md`
- Create: `components/windows-model-tester-source/resources/reply-output.schema.json`
- Create: `components/windows-model-tester-source/tests/test_prompt_builder.py`

**Interfaces:**
- Produces: `ChatMessage`, `PromptInput`, `PromptSubmission`, `build_initial_prompt(input, submission) -> str`, `build_continuation_prompt(input, submission) -> str`.
- Consumes: frozen strings and schema from `components/batch-source/Sources/CustomerReplyBatchAppSupport/PromptBuilder.swift` and its resource bundle.

- [ ] **Step 1: Write failing prompt parity tests**

Create tests that assert exact model-facing rules, untrusted data boundaries, full-history/target-batch placement, image ordering, trusted-media rule, initial prompt and continuation prompt. Add fixtures containing Chinese text, a malicious customer message that says “ignore previous instructions”, and two Windows image paths.

- [ ] **Step 2: Run tests and verify failure**

Run: `python3 -m unittest components/windows-model-tester-source/tests/test_prompt_builder.py -v`

Expected: import failure because `app.prompt_builder` does not exist.

- [ ] **Step 3: Implement immutable model types and prompt builder**

Use frozen dataclasses. Read the canonical prompt resource as UTF-8; render data only inside `<untrusted_chat_data>`. Keep `MODEL = "gpt-5.6-sol"`, `REASONING_EFFORT = "medium"`, and `CONTRACT_VERSION = "tmall-grozziie-session-v5-top12"` as asserted constants.

- [ ] **Step 4: Run prompt tests**

Run: `python3 -m unittest components/windows-model-tester-source/tests/test_prompt_builder.py -v`

Expected: all tests pass.

- [ ] **Step 5: Commit contract layer**

```bash
git add components/windows-model-tester-source/app/model.py components/windows-model-tester-source/app/prompt_builder.py components/windows-model-tester-source/resources components/windows-model-tester-source/tests/test_prompt_builder.py
git commit -m "feat: freeze Windows model tester prompt contract"
```

### Task 2: Add Atomic Conversation and Attachment Storage

**Files:**
- Create: `components/windows-model-tester-source/app/conversation_store.py`
- Create: `components/windows-model-tester-source/tests/test_conversation_store.py`

**Interfaces:**
- Consumes: `ChatMessage` from Task 1.
- Produces: `ConversationStore(root: Path)`, `create() -> Conversation`, `append_customer(id, text, uploads, expected_version) -> ConversationSnapshot`, `append_service(id, text, expected_version) -> ConversationSnapshot`, `delete(id)`, `delete_all()`, `prompt_input(id, kb_zip) -> PromptInput`.

- [ ] **Step 1: Write failing storage tests**

Cover UUID conversation creation, monotonic version, atomic JSONL writes, filename sanitization, SHA-256-based image names, 20 MB/type rejection, same-image deduplication within one message, stale-version rejection, current deletion, all deletion, and recovery from a temporary file left by interruption.

- [ ] **Step 2: Verify failure**

Run: `python3 -m unittest components/windows-model-tester-source/tests/test_conversation_store.py -v`

Expected: import failure.

- [ ] **Step 3: Implement minimal storage**

Write JSON with `ensure_ascii=False`, flush and `os.fsync`, then `os.replace`. Copy images into `data/conversations/<id>/images`; write image paths into customer JSONL records. Delete via rename to `.deleting-<uuid>` followed by `shutil.rmtree`.

- [ ] **Step 4: Run storage tests**

Run: `python3 -m unittest components/windows-model-tester-source/tests/test_conversation_store.py -v`

Expected: all pass.

- [ ] **Step 5: Commit storage**

```bash
git add components/windows-model-tester-source/app/conversation_store.py components/windows-model-tester-source/tests/test_conversation_store.py
git commit -m "feat: persist Windows tester conversations atomically"
```

### Task 3: Port V2 Retrieval Without Algorithm Changes

**Files:**
- Create: `components/windows-model-tester-source/app/knowledge_retriever.py`
- Create: `components/windows-model-tester-source/tests/test_knowledge_retriever.py`
- Create: `components/windows-model-tester-source/tests/test_retrieval_parity.py`

**Interfaces:**
- Produces: `KnowledgeResult(version: str, documents: tuple[str, ...], context: str, mode: str)`, `KnowledgeRetriever.retrieve(history_jsonl, kb_zip) -> KnowledgeResult`.
- Consumes: unchanged `Resources/V2Knowledge/retrieve_top12.py`, `hybrid.py`, `rag_b0.py`, seed cache, and current KB ZIP.

- [ ] **Step 1: Write failing adapter and fallback tests**

Use a fake retriever module to assert request keys, writable cache, seed cache, UTF-8 JSON, `v2-top12` validation, and a `full-zip-fallback` result that never invents retrieved context.

- [ ] **Step 2: Write a 10-query parity test**

Freeze ten representative questions including TD630 power, M880 power outage, TP732 macOS, calibration, media request, and ambiguous follow-up. Compare selected document names and SHA-256 of context against the current script invoked by host Python.

- [ ] **Step 3: Verify failure**

Run: `python3 -m unittest components/windows-model-tester-source/tests/test_knowledge_retriever.py components/windows-model-tester-source/tests/test_retrieval_parity.py -v`

Expected: adapter import failure.

- [ ] **Step 4: Implement adapter only**

Do not edit ranking weights, limits, pinned documents, section selection, media detection, or maximum context. Load and call the copied `retrieve_top12.retrieve(request)` function; serialize access with one process-level lock.

- [ ] **Step 5: Run retrieval tests**

Run the command from Step 3.

Expected: all pass and all ten parity hashes match.

- [ ] **Step 6: Commit retrieval port**

```bash
git add components/windows-model-tester-source/app/knowledge_retriever.py components/windows-model-tester-source/tests/test_knowledge_retriever.py components/windows-model-tester-source/tests/test_retrieval_parity.py
git commit -m "feat: preserve V2 retrieval in Windows tester"
```

### Task 4: Implement Native Windows Codex Execution

**Files:**
- Create: `components/windows-model-tester-source/app/codex_runner.py`
- Create: `components/windows-model-tester-source/tests/fakes/fake_codex.py`
- Create: `components/windows-model-tester-source/tests/test_codex_runner.py`

**Interfaces:**
- Produces: `CodexLocator.resolve(env, path_lookup) -> CodexCommand | None`, `CodexRunner.check_login() -> LoginStatus`, `CodexRunner.generate(prompt, image_paths, session_id) -> CodexResult`.
- `CodexResult` contains `reply_text`, `session_id`, `events`, `timing`, and structured diagnostic fields.

- [ ] **Step 1: Write failing locator and command tests**

Assert precedence for explicit path, `PATH`, `%APPDATA%\npm\codex.cmd`; exact `-a never exec`, `--json`, ignored config/rules, model, reasoning, read-only sandbox, schema, result, `-i`, `resume`, session id, and stdin sentinel. Assert WSL-only detection returns guidance instead of running it.

- [ ] **Step 2: Write failing process tests with fake Codex**

The fake executable emits `thread.started`, an agent message, `turn.completed` usage, and a schema result file. Cover login success, API environment stripping, malformed JSONL, missing result, nonzero exit, Unicode, timeout, and process cancellation.

- [ ] **Step 3: Verify failure**

Run: `python3 -m unittest components/windows-model-tester-source/tests/test_codex_runner.py -v`

Expected: import failure.

- [ ] **Step 4: Implement Codex runner**

On Windows invoke `.cmd` through `%COMSPEC% /d /s /c`; invoke `.exe` directly. Drain stdout and stderr concurrently, write prompt through stdin, parse JSONL incrementally, and keep the final schema file authoritative. Cache a successful ChatGPT login check for five minutes but never cache a failure.

- [ ] **Step 5: Run Codex tests**

Run the command from Step 3.

Expected: all pass.

- [ ] **Step 6: Commit Codex integration**

```bash
git add components/windows-model-tester-source/app/codex_runner.py components/windows-model-tester-source/tests/fakes components/windows-model-tester-source/tests/test_codex_runner.py
git commit -m "feat: run local Codex from Windows tester"
```

### Task 5: Orchestrate One Complete Model Turn

**Files:**
- Create: `components/windows-model-tester-source/app/service.py`
- Create: `components/windows-model-tester-source/tests/test_service.py`

**Interfaces:**
- Produces: `ModelTesterService.send(conversation_id, text, uploads, expected_version) -> SendResult`, plus create/list/delete/status methods.
- Consumes: `ConversationStore`, `KnowledgeRetriever`, `CodexRunner`, and prompt functions.

- [ ] **Step 1: Write failing service tests**

Assert customer message is persisted before generation; retrieval sees focused history; success writes exactly one service message; session id commits only after valid reply; Codex failure keeps customer message and permits retry; V2 failure uses full ZIP fallback; stale duplicate submission is rejected; new/continued session prompt selection is correct.

- [ ] **Step 2: Verify failure**

Run: `python3 -m unittest components/windows-model-tester-source/tests/test_service.py -v`

Expected: import failure.

- [ ] **Step 3: Implement orchestration**

Use per-conversation locks. Record retrieval, login, Codex, decode and total durations. Never write error text as a service message. Return citations from `KnowledgeResult.documents` and `mode` in every result.

- [ ] **Step 4: Run service tests**

Run the command from Step 2.

Expected: all pass.

- [ ] **Step 5: Commit service**

```bash
git add components/windows-model-tester-source/app/service.py components/windows-model-tester-source/tests/test_service.py
git commit -m "feat: orchestrate Windows model tester turns"
```

### Task 6: Expose the Local HTTP Boundary

**Files:**
- Create: `components/windows-model-tester-source/app/server.py`
- Create: `components/windows-model-tester-source/tests/test_server.py`

**Interfaces:**
- Produces endpoints `GET /api/health`, `GET /api/status`, `GET/POST /api/conversations`, `GET/DELETE /api/conversations/{id}`, `POST /api/conversations/{id}/messages`, `DELETE /api/conversations`, and `POST /api/shutdown`.
- Consumes: `ModelTesterService`.

- [ ] **Step 1: Write failing HTTP integration tests**

Start on `127.0.0.1:0` with a fake service. Verify JSON UTF-8, multipart text/multiple images, 20 MB limit, unsupported method, traversal rejection, handshake token on shutdown, no permissive CORS, version conflict as HTTP 409, and graceful close.

- [ ] **Step 2: Verify failure**

Run: `python3 -m unittest components/windows-model-tester-source/tests/test_server.py -v`

Expected: import failure.

- [ ] **Step 3: Implement the HTTP server**

Use `ThreadingHTTPServer` with `allow_reuse_address = False`; bind only to `127.0.0.1`; add `Cache-Control: no-store` for APIs and a strict Content Security Policy for static files. Write a one-line ready record containing port and handshake token to the launcher pipe/file.

- [ ] **Step 4: Run server tests**

Run the command from Step 2.

Expected: all pass.

- [ ] **Step 5: Commit server**

```bash
git add components/windows-model-tester-source/app/server.py components/windows-model-tester-source/tests/test_server.py
git commit -m "feat: serve Windows tester on localhost"
```

### Task 7: Build the Offline Browser UI

**Files:**
- Create: `components/windows-model-tester-source/web/index.html`
- Create: `components/windows-model-tester-source/web/app.js`
- Create: `components/windows-model-tester-source/web/styles.css`
- Create: `components/windows-model-tester-source/tests/test_web_assets.py`

**Interfaces:**
- Consumes: Task 6 HTTP endpoints.
- Produces: no-build static UI.

- [ ] **Step 1: Write failing asset contract tests**

Parse assets and assert there are no `http://`/`https://` external resources, every control has Chinese text/ARIA label, file input accepts images and multiple selection, drag/drop handlers exist, status exposes model/reasoning/retriever, delete actions require confirmation, and JavaScript sends `expected_version`.

- [ ] **Step 2: Verify failure**

Run: `python3 -m unittest components/windows-model-tester-source/tests/test_web_assets.py -v`

Expected: assets missing.

- [ ] **Step 3: Implement UI shell and behavior**

Render message text with `textContent`, never `innerHTML`. Show selected image thumbnails using object URLs and revoke them. Preserve draft on failure. Disable only the current send action. Present citations and timings in a collapsible detail panel.

- [ ] **Step 4: Run UI tests**

Run the command from Step 2.

Expected: all pass.

- [ ] **Step 5: Commit UI**

```bash
git add components/windows-model-tester-source/web components/windows-model-tester-source/tests/test_web_assets.py
git commit -m "feat: add offline Windows tester UI"
```

### Task 8: Add the Self-Contained Windows Launcher

**Files:**
- Create: `components/windows-model-tester-source/launcher/GrozziieModelTesterLauncher.csproj`
- Create: `components/windows-model-tester-source/launcher/Program.cs`
- Create: `components/windows-model-tester-source/tests/test_launcher_contract.py`

**Interfaces:**
- Produces: `格志客服模型测试器.exe` accepting optional `--no-browser` and `--port 0` for tests.
- Consumes: packaged `runtime/python.exe`, `app/server.py`, `web`, `resources`, and `data`.

- [ ] **Step 1: Write failing launcher source tests**

Assert self-contained win-x64 project settings, base directory resolution, quoted argument list, random token, dynamic port, health deadline, browser `UseShellExecute`, child-tree termination, and actionable log/error messages.

- [ ] **Step 2: Verify failure**

Run: `python3 -m unittest components/windows-model-tester-source/tests/test_launcher_contract.py -v`

Expected: launcher files missing.

- [ ] **Step 3: Implement launcher**

Use `ProcessStartInfo.ArgumentList` instead of command string concatenation. Create `data/logs`; redirect child stdout/stderr; poll health for 30 seconds; open the browser only after health success; register Ctrl+C, process-exit, and Windows job-object cleanup.

- [ ] **Step 4: Run launcher contract tests**

Run the command from Step 2.

Expected: all pass.

- [ ] **Step 5: Cross-publish launcher**

Run: `dotnet publish components/windows-model-tester-source/launcher/GrozziieModelTesterLauncher.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true`

Expected: a PE32+ `格志客服模型测试器.exe` is produced.

- [ ] **Step 6: Commit launcher**

```bash
git add components/windows-model-tester-source/launcher components/windows-model-tester-source/tests/test_launcher_contract.py
git commit -m "feat: add Windows tester launcher"
```

### Task 9: Build and Audit the Portable Windows Package

**Files:**
- Create: `components/windows-model-tester-source/requirements-windows.lock`
- Create: `components/windows-model-tester-source/scripts/build-windows-package.py`
- Create: `components/windows-model-tester-source/scripts/run-python-tests.sh`
- Create: `components/windows-model-tester-source/tests/test_package_builder.py`
- Create: `components/windows-model-tester-source/README-Windows.txt`

**Interfaces:**
- Produces: `output/windows-model-tester/格志客服模型测试器-Windows-x64.zip` and `output/windows-model-tester/package-audit.json`.
- Consumes: all previous artifacts, current KB, V2 scripts/cache, CPython embeddable archive, locked Windows wheels, and launcher publish output.

- [ ] **Step 1: Write failing package tests**

Assert deterministic layout, exact manifest fields/hashes, enabled `import site` in `python312._pth`, Windows wheels only, PE launcher, KB SHA match, required cache files, Chinese README, and bans for `.app`, Mach-O magic, macOS `.so`, `auth.json`, `.codex`, `OPENAI_API_KEY`, and `CODEX_API_KEY` values.

- [ ] **Step 2: Verify failure**

Run: `python3 -m unittest components/windows-model-tester-source/tests/test_package_builder.py -v`

Expected: builder import failure.

- [ ] **Step 3: Implement deterministic builder**

Pin download URLs and SHA-256 for CPython and every wheel. Download into a content-addressed cache; verify before extraction. Copy V2 Python sources byte-for-byte. Generate `manifest.json` and audit JSON; set stable ZIP timestamps and sorted entries.

- [ ] **Step 4: Run all host tests**

Run: `bash components/windows-model-tester-source/scripts/run-python-tests.sh`

Expected: all tests pass.

- [ ] **Step 5: Build Windows ZIP**

Run: `python3 components/windows-model-tester-source/scripts/build-windows-package.py`

Expected: ZIP and audit report produced with zero banned findings.

- [ ] **Step 6: Smoke-test packaged backend with fake Codex**

Run packaged Python under a Windows runner or Wine when available: start with `--no-browser`, call health, create conversation, upload text and two images, receive fake answer, continue same session, delete chat, and shut down.

Expected: every endpoint succeeds and fake Codex records `gpt-5.6-sol`, `medium`, two `-i` arguments, and no API key environment.

- [ ] **Step 7: Commit package system**

```bash
git add components/windows-model-tester-source/requirements-windows.lock components/windows-model-tester-source/scripts components/windows-model-tester-source/tests/test_package_builder.py components/windows-model-tester-source/README-Windows.txt
git commit -m "build: package portable Windows model tester"
```

### Task 10: Verify on a Real Windows Machine

**Files:**
- Create: `components/windows-model-tester-source/WINDOWS-QA.md`

**Interfaces:**
- Consumes: packaged ZIP from Task 9 and the tester's own local Codex ChatGPT login.
- Produces: signed-off QA record containing OS build, Codex version, manifest hash, tests, timings, and screenshots.

- [ ] **Step 1: Write the explicit QA checklist**

Include fresh unzip, no-admin launch, missing-Codex diagnostic, logged-out diagnostic, ChatGPT login, first text answer, follow-up session, image, two images, citations, timings, new/delete chat, service shutdown, offline failure, and relaunch persistence.

- [ ] **Step 2: Execute on Windows 10 or 11 x64**

Record each observed result and attach screenshot paths; do not mark a row passed from Mac-only evidence.

- [ ] **Step 3: Compare answer contract**

Ask the same ten parity questions in Mac and Windows testers. Confirm model/reasoning/retriever manifest fields match and verify retrieved document lists match; manually review any wording difference without requiring byte-identical model prose.

- [ ] **Step 4: Run package audit once more**

Run the bundled audit command from README on Windows.

Expected: zero banned files, all hashes match.

- [ ] **Step 5: Commit QA record**

```bash
git add components/windows-model-tester-source/WINDOWS-QA.md
git commit -m "test: verify Windows model tester end to end"
```

## Self-Review Record

- Spec coverage: every goal, frozen contract, UI behavior, auth rule, storage rule, fallback, packaging constraint, and Windows QA item maps to Tasks 1–10.
- Placeholder scan: no TBD/TODO/“implement later” instructions remain.
- Type consistency: Tasks 1–7 consistently use `PromptInput`, `PromptSubmission`, `KnowledgeResult`, `CodexResult`, `ConversationStore`, and `ModelTesterService` with the signatures declared in their interface blocks.
- Scope: no task modifies Qianniu, OCR, unread scanning, production queues, macOS tester logic, or API authentication.
