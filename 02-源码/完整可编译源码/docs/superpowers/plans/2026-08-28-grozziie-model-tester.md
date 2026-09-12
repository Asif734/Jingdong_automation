# 格志客服模型测试器 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 构建一个不连接千牛、可分发给同事、复用当前模型与知识库检索的独立 macOS 客服模型测试器。

**Architecture:** 新建独立 Swift Package，并依赖现有 batch-source 的 Prompt、Codex和V2检索接口。应用用本地 JSONL 保存测试会话，调用同事电脑上已登录的 Codex；构建脚本将固定知识库和检索资源装入 App Resources。

**Tech Stack:** Swift 5.9、SwiftUI、Swift Package Manager、Codex CLI、现有 Python V2 Top-12 检索器、shell打包脚本。

**Spec:** `docs/superpowers/specs/2026-08-28-grozziie-model-tester-design.md`

## Global Constraints

- 模型固定为 `gpt-5.6-sol`，推理强度固定为 `medium`，不可静默降级。
- 第一版仅支持 Apple Silicon 和 macOS 14+。
- 不依赖千牛、OCR、未读助手或发送器。
- 不读取、复制、打包或导出 Codex 凭据。
- 不依赖用户桌面上的固定路径。
- 必须复用现有 PromptBuilder、CodexReplyGenerator 和 V2KnowledgeRetriever。

---

### Task 1: 独立核心数据与会话存储

**Files:**
- Create: `components/model-tester-source/Package.swift`
- Create: `components/model-tester-source/Sources/GrozziieModelTesterCore/TestConversation.swift`
- Create: `components/model-tester-source/Sources/GrozziieModelTesterCore/TestConversationStore.swift`
- Test: `components/model-tester-source/Tests/GrozziieModelTesterCoreTests/TestConversationStoreTests.swift`

**Interfaces:**
- Produces: `TestConversation`, `TestMessage`, `TestConversationStore.create()`, `appendCustomer(...)`, `appendService(...)`, `promptInput(...)`。
- Consumes: `PromptInput` from `CustomerReplyBatchAppSupport`。

- [ ] **Step 1: Write failing tests** covering a new conversation, customer/service JSONL ordering, a unique UID, and a fresh conversation not inheriting prior history.
- [ ] **Step 2: Run** `swift test --package-path components/model-tester-source --filter TestConversationStoreTests` and confirm failure because the production types do not exist.
- [ ] **Step 3: Implement minimal Codable conversation types and atomic JSONL persistence under an injected root URL.**
- [ ] **Step 4: Re-run the focused test and the package test suite; expect zero failures.**

### Task 2: Codex发现、登录状态与固定配置

**Files:**
- Create: `components/model-tester-source/Sources/GrozziieModelTesterCore/CodexInstallation.swift`
- Test: `components/model-tester-source/Tests/GrozziieModelTesterCoreTests/CodexInstallationTests.swift`

**Interfaces:**
- Produces: `CodexInstallationLocator.resolve(existingPaths:pathLookup:) -> URL?` and `ModelConfiguration.production`。

- [ ] **Step 1: Write failing table-driven tests** for ChatGPT.app precedence, Homebrew fallback, PATH fallback, missing executable, and exact fixed model/reasoning values.
- [ ] **Step 2: Run the focused tests and confirm the expected missing-symbol failures.**
- [ ] **Step 3: Implement deterministic executable discovery without reading authentication files.**
- [ ] **Step 4: Run focused and full package tests; expect zero failures.**

### Task 3: 测试生成协调器与诊断数据

**Files:**
- Create: `components/model-tester-source/Sources/GrozziieModelTesterCore/ModelTestCoordinator.swift`
- Create: `components/model-tester-source/Sources/GrozziieModelTesterCore/RunDiagnostic.swift`
- Test: `components/model-tester-source/Tests/GrozziieModelTesterCoreTests/ModelTestCoordinatorTests.swift`

**Interfaces:**
- Consumes: `ReplyGenerating`, `TestConversationStore`。
- Produces: `send(text:imagePaths:) async -> ModelTestResult` with answer, timing, citations and persisted service history.

- [ ] **Step 1: Write failing tests** proving one generation per customer turn, persisted replies, error preservation, and no history loss after generation failure.
- [ ] **Step 2: Run focused tests and confirm failures are due to the absent coordinator.**
- [ ] **Step 3: Implement the coordinator using a narrowly scoped fake `ReplyGenerating` only at the external model boundary.**
- [ ] **Step 4: Run focused and full tests; expect zero failures.**

### Task 4: 简洁 SwiftUI 测试界面

**Files:**
- Create: `components/model-tester-source/Sources/GrozziieModelTesterApp/GrozziieModelTesterApplication.swift`
- Create: `components/model-tester-source/Sources/GrozziieModelTesterApp/ModelTesterViewModel.swift`
- Create: `components/model-tester-source/Sources/GrozziieModelTesterApp/ContentView.swift`
- Test: `components/model-tester-source/Tests/GrozziieModelTesterAppTests/ModelTesterViewModelTests.swift`

**Interfaces:**
- Consumes: `ModelTestCoordinator`, `CodexInstallationLocator`, `V2KnowledgeRetriever`, `CodexReplyGenerator`。
- Produces: visible login/model/KB status, chat list, input, image attachments, diagnostics, new conversation and report export actions.

- [ ] **Step 1: Write failing view-model tests** for disabled send on empty input, progress status, success/error rendering, new-conversation reset and exact model label.
- [ ] **Step 2: Run focused tests and verify missing production behavior causes the failures.**
- [ ] **Step 3: Implement the view model and a single-window SwiftUI view without Qianniu-related imports or permissions.**
- [ ] **Step 4: Run focused and full tests; expect zero failures.**

### Task 5: 自带知识库、运行资源与版本清单

**Files:**
- Create: `components/model-tester-source/Sources/GrozziieModelTesterCore/BundledResources.swift`
- Create: `components/model-tester-source/Sources/GrozziieModelTesterApp/Resources/model-tester-manifest.json`
- Create: `components/model-tester-source/scripts/prepare-resources.sh`
- Test: `components/model-tester-source/Tests/GrozziieModelTesterCoreTests/BundledResourcesTests.swift`
- Test: `components/model-tester-source/Tests/PackagingTests/prepare_resources_test.sh`

**Interfaces:**
- Produces: resolved bundled KB URL, V2 retriever configuration, manifest version/hash, writable Application Support cache URL.

- [ ] **Step 1: Write failing unit and shell tests** using temporary fixture ZIP/resources to prove no desktop path is required and a wrong SHA-256 aborts packaging.
- [ ] **Step 2: Run both tests and confirm the missing resolver/script failures.**
- [ ] **Step 3: Implement resource resolution and a copy/verification script that packages only KB and V2 resources.**
- [ ] **Step 4: Re-run focused tests and the full Swift suite; expect zero failures.**

### Task 6: 可分享 App 与 DMG 构建

**Files:**
- Create: `components/model-tester-source/scripts/build-app.sh`
- Create: `components/model-tester-source/scripts/build-dmg.sh`
- Create: `components/model-tester-source/Packaging/Info.plist.template`
- Test: `components/model-tester-source/Tests/PackagingTests/build_app_test.sh`

**Interfaces:**
- Produces: `output/格志客服模型测试器.app` and, when signing/notarization inputs are present, `output/格志客服模型测试器.dmg`。

- [ ] **Step 1: Write failing packaging test** proving the built app is arm64, macOS 14+, contains KB/manifest/V2 resources, omits Qianniu/OCR artifacts, and contains no `auth.json` or API key.
- [ ] **Step 2: Run it and confirm failure because the build scripts are absent.**
- [ ] **Step 3: Implement release build, development signing fallback, optional Developer ID notarization and DMG creation.**
- [ ] **Step 4: Run Swift tests, packaging tests, `plutil -lint`, `codesign --verify --deep --strict`, architecture inspection and a clean-machine-path smoke test.**

### Task 7: 真人可用性验证

**Files:**
- Create: `components/model-tester-source/LIVE-QA.md`

**Interfaces:**
- Consumes: packaged app and a locally logged-in Codex account.
- Produces: evidence for login detection, one-turn reply, follow-up context, new-conversation isolation, citation display, report export, and no Qianniu permissions.

- [ ] **Step 1: Launch the packaged app and verify the visible fixed model/KB status.**
- [ ] **Step 2: Submit one text question and one follow-up; record response and timing.**
- [ ] **Step 3: Start a new test and prove the prior conversation is not inherited.**
- [ ] **Step 4: Export a report and scan it and the app bundle for credentials.**
- [ ] **Step 5: Record exact commands, hashes and outcomes in LIVE-QA.md.**
