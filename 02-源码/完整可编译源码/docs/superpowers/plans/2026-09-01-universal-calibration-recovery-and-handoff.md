# 千牛通用自适应校准恢复与完整接管包 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复同事 B 真机上 40 个可按控件被误判为发送按钮的问题，使首次校准能够降级、预热并自动运行，同时生成可在任意同事 Mac 上由 Codex 完整接管和修改的 Git 交付包。

**Architecture:** 将通用“可按控件分类”、发送候选评分和发送策略决策拆成独立组件；校准始终输出可执行的发送策略和结构化诊断，只有输入框也无法定位时才阻塞。首次通用版安装通过一次性迁移标记保留聊天与判重数据、重置旧候选版临时停止偏好；打包阶段同时输出源码快照和可移植 Git bundle。

**Tech Stack:** Swift 5.9、SwiftPM、AppKit Accessibility、CoreGraphics、XCTest、zsh、Python 3 标准库、Git bundle、DMG/hdiutil、macOS 14+、Apple Silicon arm64。

**Spec:** `docs/superpowers/specs/2026-09-01-qianniu-universal-autoconfiguration-design.md`

## Global Constraints

- 版本 A 冻结包保持只读；全部改动只进入 `fix/conversation-node-classifier` 当前通用版分支。
- 一个 App 实例仍只绑定一个千牛接待窗口；不在本计划实现多账号总控。
- 不绕过辅助功能、屏幕录制、千牛登录或 Codex 登录。
- 同事 B 的发送控件歧义不得阻止 OCR/V2 预热或进入 `readOnlyReady`。
- 未唯一确认发送按钮时使用 `.returnKeyOnce`；不得把任意 `AXPress` 控件当成发送按钮。
- 首次通用版迁移保留聊天记录、图片指纹、身份映射和发送判重数据，不重放旧回复。
- 通用版首次安装默认 `autoStartWhenReady=true`；用户以后手动关闭后必须保持关闭。
- 交付包不得包含客户运行数据、聊天内容、图片指纹、登录凭证、个人 `~/.codex`、构建缓存或 linked-worktree 绝对 `.git` 指针。
- 内测包如未公证必须明确标注；没有 `NOTARIZATION_ACCEPTED=1` 时不得声称已公证。

## File Structure

- `Sources/AutoReplyApp/Autoconfiguration/CalibrationSnapshot.swift`：只负责把原始标签归类；普通可按按钮归入 `press-control`。
- `Sources/AutoReplyApp/Autoconfiguration/SendCandidateCalibration.swift`：新增；只负责发送候选评分、唯一性判断、降级策略和候选计数。
- `Sources/AutoReplyApp/Autoconfiguration/InteractionCalibration.swift`：组合聊天区、输入框和发送决策。
- `Sources/AutoReplyApp/Autoconfiguration/AutoconfigurationModels.swift`：保存结构化校准诊断和 profile schema。
- `Sources/AutoReplyApp/Autoconfiguration/AdaptiveCalibrationEngine.swift`：把发送决策映射到 capability/profile，保证歧义时仍有 `.returnKeyOnce`。
- `Sources/AutoReplyApp/Autoconfiguration/UniversalInstallMigration.swift`：新增；只负责通用版首次安装标记与 operator 偏好迁移。
- `Sources/AutoReplyApp/AutomationAppModel.swift`：在读取旧 operator 配置前执行一次迁移，复用现有恰好一次自动启动链路。
- `Sources/AutoReplyApp/Autoconfiguration/DiagnosticBundleExporter.swift`：导出结构化校准诊断。
- `Sources/AutoReplyApp/Autoconfiguration/FirstRunView.swift`：在高级区域展示策略、候选数量、是否可继续和下一步动作。
- `Tests/AutoReplyAppTests/ColleagueB40ControlFixture.swift`：新增；构造同事 B 已知的 40 个可按控件回归样本，不含客户信息。
- `scripts/build-developer-handoff.sh`：新增；生成 DMG、源码快照、完整 Git bundle、清单和 ZIP。
- `Tests/Packaging/developer_handoff_contract_test.py`：新增；真实 verify/clone Git bundle 并检查隐私边界。
- `docs/把这个文件交给Codex-项目完整接管与Debug手册.md`：更新接管、自动校准、预热和重新构建流程。

---

### Task 1: 用同事 B 的 40 控件结构建立失败回归

**Files:**
- Create: `Tests/AutoReplyAppTests/ColleagueB40ControlFixture.swift`
- Modify: `Tests/AutoReplyAppTests/InteractionCalibrationTests.swift`
- Modify: `Tests/AutoReplyAppTests/CompatibilityFixtureReplayTests.swift`
- Test: `Tests/AutoReplyAppTests/InteractionCalibrationTests.swift`
- Test: `Tests/AutoReplyAppTests/CompatibilityFixtureReplayTests.swift`

**Interfaces:**
- Consumes: 现有 `CalibrationSnapshot`、`CalibrationAXNode`、`AdaptiveCalibrationEngine.calibrate(snapshot:)`。
- Produces: `CalibrationSnapshot.colleagueB40Controls(exactSendLabel: Bool)`，供本计划所有发送校准测试复用。

- [ ] **Step 1: 创建脱敏的 40 控件 fixture**

在 `ColleagueB40ControlFixture.swift` 定义：

```swift
import CoreGraphics
@testable import AutoReplyApp

extension CalibrationSnapshot {
    static func colleagueB40Controls(exactSendLabel: Bool) -> CalibrationSnapshot {
        var nodes = (0..<39).map { index in
            CalibrationAXNode(
                id: 100 + index,
                parentID: 1,
                role: "AXButton",
                actionNames: ["AXPress"],
                labelCategory: "press-control",
                relativeFrame: CGRect(
                    x: 0.70 + CGFloat(index % 5) * 0.045,
                    y: 0.05 + CGFloat(index / 5) * 0.045,
                    width: 0.035,
                    height: 0.025
                ),
                hasValue: true
            )
        }
        nodes += [
            CalibrationAXNode(
                id: 1, parentID: nil, role: "AXGroup", actionNames: [],
                labelCategory: "chat-region",
                relativeFrame: CGRect(x: 0.24, y: 0.12, width: 0.43, height: 0.72),
                hasValue: false
            ),
            CalibrationAXNode(
                id: 2, parentID: 1, role: "AXTextArea", actionNames: ["AXConfirm"],
                labelCategory: "input-control",
                relativeFrame: CGRect(x: 0.25, y: 0.70, width: 0.34, height: 0.10),
                hasValue: true
            ),
            CalibrationAXNode(
                id: 200, parentID: 1, role: "AXButton", actionNames: ["AXPress"],
                labelCategory: exactSendLabel ? "send-control" : "press-control",
                relativeFrame: CGRect(x: 0.60, y: 0.73, width: 0.06, height: 0.045),
                hasValue: true
            )
        ]
        return CalibrationSnapshot(
            macOSBuild: "25G83", architecture: "arm64",
            qianniuVersion: "9.97.74", qianniuBuild: "20260812105806",
            qianniuRuntimeArchitecture: "arm64",
            displays: [CalibrationDisplay(
                relativeFrame: CGRect(x: 0, y: 0, width: 1, height: 1), scale: 2
            )],
            windows: [CalibrationWindow(
                roleCategory: "reception",
                relativeFrame: CGRect(x: 0, y: 0, width: 1, height: 1),
                captureFrame: CGRect(x: 0, y: 0, width: 2, height: 2),
                minimized: false, focused: true,
                regionCategories: ["conversation-list", "chat", "composer"]
            )],
            nodes: nodes
        )
    }
}
```

- [ ] **Step 2: 写出旧代码必然失败的分类与 40 控件测试**

在 `InteractionCalibrationTests.swift` 添加：

```swift
func testGenericPressableButtonIsNotClassifiedAsSendControl() {
    XCTAssertEqual(
        CalibrationLabelCategory.classify(
            rawLabel: "刷新", role: "AXButton", actions: ["AXPress"]
        ),
        "press-control"
    )
}

func testFortyPressableControlsSelectOnlyExactNearbySendButton() throws {
    let policies = try InteractionCalibration.calibrate(
        snapshot: .colleagueB40Controls(exactSendLabel: true)
    )
    XCTAssertEqual(policies.sendTrigger, .accessibilityPress)
    XCTAssertEqual(policies.sendDiagnostic.rawPressableCount, 40)
    XCTAssertEqual(policies.sendDiagnostic.eligibleCandidateCount, 1)
    XCTAssertEqual(policies.sendDiagnostic.level, .verified)
}

func testAmbiguousFortyControlsFallBackToReturnInsteadOfFailingProfile() throws {
    let profile = try AdaptiveCalibrationEngine.calibrate(
        snapshot: .colleagueB40Controls(exactSendLabel: false)
    )
    XCTAssertEqual(profile.sendPolicy, .returnKeyOnce)
    XCTAssertFalse(profile.requiresFullAdaptiveCalibration)
    XCTAssertEqual(profile.capabilities["sendAX"]?.level, .fallback)
}
```

- [ ] **Step 3: 运行测试并确认 RED**

Run:

```bash
swift test --filter InteractionCalibrationTests
```

Expected: `testGenericPressableButtonIsNotClassifiedAsSendControl` 得到 `send-control` 而失败；`sendDiagnostic` 尚不存在而编译失败。

- [ ] **Step 4: 将 40 控件 fixture 纳入跨机器回放入口**

在 `CompatibilityFixtureReplayTests.swift` 新增独立测试：

```swift
func testColleagueB40ControlFixtureProducesRunnableProfile() throws {
    let profile = try AdaptiveCalibrationEngine.calibrate(
        snapshot: .colleagueB40Controls(exactSendLabel: true)
    )
    XCTAssertEqual(profile.sendPolicy, .accessibilityPress)
    XCTAssertFalse(profile.requiresFullAdaptiveCalibration)
}
```

- [ ] **Step 5: 提交回归测试**

```bash
git add Tests/AutoReplyAppTests/ColleagueB40ControlFixture.swift \
  Tests/AutoReplyAppTests/InteractionCalibrationTests.swift \
  Tests/AutoReplyAppTests/CompatibilityFixtureReplayTests.swift
git commit -m "test: reproduce colleague B send calibration failure"
```

---

### Task 2: 分离普通按钮与发送候选并实现可运行降级

**Files:**
- Create: `Sources/AutoReplyApp/Autoconfiguration/SendCandidateCalibration.swift`
- Modify: `Sources/AutoReplyApp/Autoconfiguration/CalibrationSnapshot.swift`
- Modify: `Sources/AutoReplyApp/Autoconfiguration/InteractionCalibration.swift`
- Modify: `Sources/AutoReplyApp/Autoconfiguration/AdaptiveCalibrationEngine.swift`
- Modify: `Sources/AutoReplyApp/Autoconfiguration/AutoconfigurationModels.swift`
- Test: `Tests/AutoReplyAppTests/InteractionCalibrationTests.swift`
- Test: `Tests/AutoReplyAppTests/RuntimeAdapterTests.swift`

**Interfaces:**
- Consumes: `CalibrationAXNode`, `QianniuSendTrigger`, 输入框绝对 `CGRect`。
- Produces: `SendCalibrationDiagnostic`、`SendCalibrationDecision`、`SendCandidateCalibration.decide(nodes:composerFrame:)`；`InteractionPolicies.sendDiagnostic`。

- [ ] **Step 1: 定义发送决策与结构化诊断类型**

在 `AutoconfigurationModels.swift` 增加：

```swift
struct SendCalibrationDiagnostic: Codable, Equatable, Sendable {
    let stage: String
    let rawPressableCount: Int
    let eligibleCandidateCount: Int
    let selectedStrategy: String
    let level: CapabilityLevel
    let canContinue: Bool
    let nextAction: String
}

struct SendCalibrationDecision: Equatable, Sendable {
    let trigger: QianniuSendTrigger
    let fallbackPoint: CGPoint?
    let diagnostic: SendCalibrationDiagnostic
}
```

给 `MachineCompatibilityProfile` 增加可选字段 `calibrationDiagnostics: [SendCalibrationDiagnostic]? = nil`，将 `schemaVersion` 提升到 `3`；可选字段保证 schema 2 的旧 JSON 能继续解码，新 profile 明确传入 `[interaction.sendDiagnostic]`。`requiresFullAdaptiveCalibration` 改为 `schemaVersion < 3`，其余非空策略门槛保持不变。`AutoconfigurationModels.swift` 同时增加 `import CoreGraphics`，供 `CGPoint` 使用。

- [ ] **Step 2: 修正标签分类**

将 `CalibrationLabelCategory.classify` 的发送分支改为：

```swift
if value == "发送" { return "send-control" }
if role.contains("Button") && actions.contains("AXPress") { return "press-control" }
```

输入框、聊天区和其他既有分类顺序保持不变。

- [ ] **Step 3: 实现独立候选评分器**

在 `SendCandidateCalibration.swift` 实现：

```swift
enum SendCandidateCalibration {
    static func decide(
        nodes: [CalibrationAXNode],
        composerFrame: CGRect
    ) -> SendCalibrationDecision
}
```

评分必须精确采用：

- `labelCategory == "send-control"`：`+100`；
- `role == "AXButton" && actionNames.contains("AXPress")`：`+20`；
- `role == "AXMenuButton"`：`+10`；
- 候选中心位于输入框右侧闭区间 `[composerFrame.maxX, composerFrame.maxX + 0.15]`，且垂直中心落在输入框上下各扩展 `0.06` 的区间：`+40`；
- 候选与输入框共同 `parentID`：`+20`；
- 候选中心 `y < composerFrame.minY - 0.10`：`-100`，排除上方工具栏；
- 只有总分 `>= 80` 才进入有效候选；
- 第一名必须比第二名至少高 `20` 分才是唯一候选；
- 唯一候选能通过 `ComposerSelectionPolicy.resolveSendTrigger` 解析时使用解析结果；唯一候选不能解析动作时仍使用 `.returnKeyOnce`，但把中心保存为 `fallbackPoint`；
- 没有唯一候选时使用 `.returnKeyOnce`、`fallbackPoint=nil`、`level=.fallback`、`canContinue=true`；
- `rawPressableCount` 只统计 `send-control`、`press-control` 或 `AXMenuButton`。

唯一候选诊断的 `nextAction` 为“首次真实发送后核对输入框清空或客服气泡”；降级诊断为“使用 Return 发送；首次真实发送后自动核对结果”。

- [ ] **Step 4: 让 InteractionCalibration 始终消费发送决策**

给 `InteractionPolicies` 增加：

```swift
let sendDiagnostic: SendCalibrationDiagnostic
```

用 `SendCandidateCalibration.decide(nodes:composerFrame:)` 替换现有 `sendNodes.count == 1` 逻辑；`sendTrigger` 总是使用 `decision.trigger`，composer fallback 使用 `decision.fallbackPoint`。

- [ ] **Step 5: 将诊断和降级状态写入 profile**

在 `AdaptiveCalibrationEngine`：

- `sendPolicy` 继续保存 `interaction.sendTrigger`；
- `calibrationDiagnostics` 保存 `[interaction.sendDiagnostic]`；
- `sendAX` 的 level 直接使用 `interaction.sendDiagnostic.level`；
- `sendAX.detail` 使用以下确定格式：

```swift
"发送校准：可按\(raw)个，有效\(eligible)个；\(selectedStrategy)；\(nextAction)"
```

fallback interaction 的 `sendTrigger` 保持 `.returnKeyOnce`，诊断明确 `raw=0`、`eligible=0`、`level=.fallback`、`canContinue=true`。

- [ ] **Step 6: 运行校准和运行时测试并确认 GREEN**

Run:

```bash
swift test --filter InteractionCalibrationTests
swift test --filter CompatibilityFixtureReplayTests
swift test --filter RuntimeAdapterTests
```

Expected: 全部 PASS；40 控件精确发送样本得到 `.accessibilityPress`，歧义样本得到 `.returnKeyOnce` 且 profile 可运行。

- [ ] **Step 7: 提交发送校准实现**

```bash
git add Sources/AutoReplyApp/Autoconfiguration/CalibrationSnapshot.swift \
  Sources/AutoReplyApp/Autoconfiguration/SendCandidateCalibration.swift \
  Sources/AutoReplyApp/Autoconfiguration/InteractionCalibration.swift \
  Sources/AutoReplyApp/Autoconfiguration/AdaptiveCalibrationEngine.swift \
  Sources/AutoReplyApp/Autoconfiguration/AutoconfigurationModels.swift
git commit -m "fix: make send calibration tolerant across Qianniu layouts"
```

---

### Task 3: 证明发送歧义不会阻止预热和自动开始

**Files:**
- Modify: `Tests/AutoReplyAppTests/FirstRunCoordinatorTests.swift`
- Modify: `Tests/AutoReplyAppTests/AutomationAppModelTests.swift`
- Modify: `Sources/AutoReplyApp/Autoconfiguration/FirstRunCoordinator.swift`
- Test: `Tests/AutoReplyAppTests/FirstRunCoordinatorTests.swift`
- Test: `Tests/AutoReplyAppTests/AutomationAppModelTests.swift`

**Interfaces:**
- Consumes: Task 2 的可运行 profile、`FirstRunCoordinator.advance(operatorConfig:)`、`AutomationAppModel.consumeReadinessChange()`。
- Produces: 40 控件歧义样本从校准到预热再到调度器恰好启动一次的集成契约。

- [ ] **Step 1: 写出预热必须继续的失败测试**

在 `FirstRunCoordinatorTests.swift` 增加一个记录调用次数的 `CountingReadinessPrewarmer`，并添加：

```swift
func testAmbiguousSendControlsStillPrewarmAndReachReadOnlyReady() async throws {
    let profile = try AdaptiveCalibrationEngine.calibrate(
        snapshot: .colleagueB40Controls(exactSendLabel: false)
    )
    let prewarmer = CountingReadinessPrewarmer(result: [
        "ocr": CapabilityStatus(level: .verified, strategy: "warm", detail: "ready"),
        "v2": CapabilityStatus(level: .verified, strategy: "persistent", detail: "ready")
    ])
    let coordinator = FirstRunCoordinator(
        checks: FakeFirstRunChecks(
            permission: PermissionState(accessibility: true, screenCapture: true),
            qianniuReady: true, codexReady: true
        ),
        calibration: FakeCalibrationProvider(result: profile),
        prewarmer: prewarmer
    )
    await coordinator.advance(
        operatorConfig: OperatorConfig(serviceAliases: ["小甘"], autoStartWhenReady: true)
    )
    XCTAssertEqual(await prewarmer.callCount(), 1)
    XCTAssertEqual(coordinator.phase, .readOnlyReady)
    XCTAssertEqual(coordinator.profile?.sendPolicy, .returnKeyOnce)
    XCTAssertTrue(coordinator.shouldAutoStart)
}
```

- [ ] **Step 2: 写出恰好启动一次的集成测试**

在 `AutomationAppModelTests.swift` 使用 `.colleagueB40Controls(exactSendLabel: false)` 生成 profile，再创建 coordinator 和 model，连续调用两次 `consumeReadinessChange()`：

先把测试 helper 改为可注入 profile，同时保留现有无参数调用：

```swift
private struct ReadyCalibration: CalibrationProviding {
    let profile: MachineCompatibilityProfile
    init(profile: MachineCompatibilityProfile = .empty) { self.profile = profile }
    func calibrate() async throws -> MachineCompatibilityProfile { profile }
}
```

测试主体为：

```swift
let profile = try AdaptiveCalibrationEngine.calibrate(
    snapshot: .colleagueB40Controls(exactSendLabel: false)
)
let firstRun = FirstRunCoordinator(
    checks: ReadyFirstRunChecks(),
    calibration: ReadyCalibration(profile: profile),
    prewarmer: ReadyPrewarmer()
)
await firstRun.advance(
    operatorConfig: OperatorConfig(serviceAliases: ["小甘"], autoStartWhenReady: true)
)
let model = try AutomationAppModel(
    root: root, ui: IdleUI(), generator: UnusedGenerator(),
    autoResume: false, firstRun: firstRun
)
model.setServiceAliasesText("小甘")
model.applyServiceAliases()
await model.consumeReadinessChange()
await model.consumeReadinessChange()
```

断言：

```swift
XCTAssertTrue(model.scheduler.isRunning)
XCTAssertEqual(model.automaticStartInvocationCountForTesting, 1)
```

- [ ] **Step 3: 运行测试确认 RED 或暴露 profile schema 传播缺口**

Run:

```bash
swift test --filter FirstRunCoordinatorTests
swift test --filter AutomationAppModelTests.testReadyCoordinatorStartsSchedulerExactlyOnce
```

Expected: 若 `FirstRunCoordinator` 重建 profile 时未复制 `calibrationDiagnostics`，测试编译或诊断断言失败；不得通过删除断言规避。

- [ ] **Step 4: 最小修复 profile 传播**

在 `FirstRunCoordinator` 创建 `readyProfile` 时复制：

```swift
calibrationDiagnostics: calibratedProfile.calibrationDiagnostics
```

保留现有 `shouldAutoStart = operatorConfig.autoStartWhenReady` 与恰好一次消费门禁，不新增第二套启动器。

- [ ] **Step 5: 运行集成测试并确认 GREEN**

Run:

```bash
swift test --filter FirstRunCoordinatorTests
swift test --filter AutomationAppModelTests
```

Expected: 全部 PASS；歧义发送样本预热一次、进入 `readOnlyReady`、调度器启动恰好一次。

- [ ] **Step 6: 提交就绪链路修复**

```bash
git add Sources/AutoReplyApp/Autoconfiguration/FirstRunCoordinator.swift \
  Tests/AutoReplyAppTests/FirstRunCoordinatorTests.swift \
  Tests/AutoReplyAppTests/AutomationAppModelTests.swift
git commit -m "test: keep prewarm and autostart alive after send fallback"
```

---

### Task 4: 首次通用版迁移默认自动运行但保留业务历史

**Files:**
- Create: `Sources/AutoReplyApp/Autoconfiguration/UniversalInstallMigration.swift`
- Modify: `Sources/AutoReplyApp/AutomationAppModel.swift`
- Modify: `Tests/AutoReplyAppTests/AutomationAppModelTests.swift`
- Test: `Tests/AutoReplyAppTests/AutomationAppModelTests.swift`

**Interfaces:**
- Consumes: `AtomicJSONStore<OperatorConfig>`、运行根目录。
- Produces: `UniversalInstallMigration.applyIfNeeded(root:operatorStore:) -> OperatorConfig?` 与原子 marker `运行状态/自动配置/universal-install-v1.json`。

- [ ] **Step 1: 写出首次迁移和用户偏好持久化测试**

添加三个测试；第一个测试的主体为：

```swift
func testUniversalFirstInstallOverridesLegacyStoppedPreferenceButKeepsAliases() throws {
    let root = temporaryModelRoot("universal-first-install")
    let store = AtomicJSONStore<OperatorConfig>(
        root: root.appendingPathComponent("运行状态/自动配置"), stem: "operator"
    )
    try store.saveCandidate(
        OperatorConfig(serviceAliases: ["小甘"], autoStartWhenReady: false),
        validate: { _ in true }
    )
    let model = try AutomationAppModel(
        root: root, ui: IdleUI(), generator: UnusedGenerator(), autoResume: false
    )
    XCTAssertEqual(model.serviceAliases, ["小甘"])
    XCTAssertTrue(model.autoStartWhenReady)
    XCTAssertTrue(FileManager.default.fileExists(
        atPath: root.appendingPathComponent(
            "运行状态/自动配置/universal-install-v1.json"
        ).path
    ))
}
```

第二个测试在 `用户/u1/history.jsonl` 和 `运行状态/图片指纹/u1.json` 写入固定字节，创建 model 后逐字节断言：

```swift
XCTAssertEqual(try Data(contentsOf: historyURL), Data("keep-history".utf8))
XCTAssertEqual(
    try Data(contentsOf: fingerprintURL),
    Data("keep-image-fingerprint".utf8)
)
```

第三个测试第一次创建 model、调用 `setAutoStartWhenReady(false)`，释放后再次创建 model：

```swift
var first: AutomationAppModel? = try AutomationAppModel(
    root: root, ui: IdleUI(), generator: UnusedGenerator(), autoResume: false
)
first?.setAutoStartWhenReady(false)
first = nil
let reopened = try AutomationAppModel(
    root: root, ui: IdleUI(), generator: UnusedGenerator(), autoResume: false
)
XCTAssertFalse(reopened.autoStartWhenReady)
```

在测试文件内增加 `temporaryModelRoot(_:)`，创建临时目录并通过 `addTeardownBlock` 删除，避免测试数据进入真实运行目录。

- [ ] **Step 2: 运行测试确认 RED**

Run:

```bash
swift test --filter AutomationAppModelTests.testUniversal
swift test --filter AutomationAppModelTests.testUserDisablingAutostartAfterMigration
```

Expected: 旧 `autoStartWhenReady=false` 被直接继承，首次迁移测试失败。

- [ ] **Step 3: 实现一次性迁移器**

`UniversalInstallMigration.applyIfNeeded` 必须：

1. marker 已存在时只返回 `operatorStore.load()`，不改配置；
2. marker 不存在时读取旧 operator；
3. 使用以下代码写入新 operator：

```swift
let migrated = OperatorConfig(
    serviceAliases: old?.serviceAliases ?? [],
    autoStartWhenReady: true
)
try operatorStore.saveCandidate(migrated, validate: { _ in true })
```
4. 使用 `Data.write(options:.atomic)` 写入 JSON marker：

```json
{"schemaVersion":1,"migration":"universal-install","completed":true}
```

5. 不遍历、不移动、不删除运行根目录中的其他文件。

任何写入失败必须抛错并且不伪造 marker。

- [ ] **Step 4: 在 AutomationAppModel 初始化早期调用迁移**

创建 `operatorConfigStore` 后、第一次读取 stored operator 前调用：

```swift
let migratedOperator = try UniversalInstallMigration.applyIfNeeded(
    root: root,
    operatorStore: operatorConfigStore
)
if let storedOperator = migratedOperator ?? (try? operatorConfigStore.load()) {
    autoStartWhenReady = storedOperator.autoStartWhenReady
}
```

客服 aliases 的既有选择顺序保持不变；不得重置 `CapturedHistory`、scheduler store 或图片指纹。

- [ ] **Step 5: 运行迁移和既有恢复测试**

Run:

```bash
swift test --filter AutomationAppModelTests
swift test --filter AutomationRunIntentTests
swift test --filter CapturedHistoryTests
```

Expected: 全部 PASS；首次通用版默认自动启动，用户关闭偏好可持久保存，历史与判重不变。

- [ ] **Step 6: 提交迁移实现**

```bash
git add Sources/AutoReplyApp/Autoconfiguration/UniversalInstallMigration.swift \
  Sources/AutoReplyApp/AutomationAppModel.swift \
  Tests/AutoReplyAppTests/AutomationAppModelTests.swift
git commit -m "feat: migrate universal install to autostart safely"
```

---

### Task 5: 导出并展示可执行的中文校准诊断

**Files:**
- Modify: `Sources/AutoReplyApp/Autoconfiguration/DiagnosticBundleExporter.swift`
- Modify: `Sources/AutoReplyApp/Autoconfiguration/FirstRunView.swift`
- Modify: `Tests/AutoReplyAppTests/DiagnosticBundleExporterTests.swift`
- Modify: `Tests/AutoReplyAppTests/FirstRunViewModelTests.swift`
- Test: `Tests/AutoReplyAppTests/DiagnosticBundleExporterTests.swift`
- Test: `Tests/AutoReplyAppTests/FirstRunViewModelTests.swift`

**Interfaces:**
- Consumes: `MachineCompatibilityProfile.calibrationDiagnostics`、`CapabilityStatus`。
- Produces: 诊断包内 `calibration-diagnostics.json` 和 UI 高级状态文本。

- [ ] **Step 1: 写诊断导出失败测试**

在 `DiagnosticBundleExporterTests.swift` 构造带以下诊断的 profile：

```swift
SendCalibrationDiagnostic(
    stage: "发送控件校准",
    rawPressableCount: 40,
    eligibleCandidateCount: 0,
    selectedStrategy: "returnKeyOnce",
    level: .fallback,
    canContinue: true,
    nextAction: "使用 Return 发送；首次真实发送后自动核对结果"
)
```

导出后解码 `calibration-diagnostics.json`，逐字段断言候选数量、策略、可继续和下一步动作；同时扫描整个默认诊断包不含 `tb-secret`、客户昵称或 token。

- [ ] **Step 2: 运行诊断测试确认 RED**

Run:

```bash
swift test --filter DiagnosticBundleExporterTests
```

Expected: `calibration-diagnostics.json` 不存在而失败。

- [ ] **Step 3: 导出结构化诊断**

在 `DiagnosticBundleExporter.export` 中始终写入：

```swift
try write(
    profile.calibrationDiagnostics ?? [],
    to: output.appendingPathComponent("calibration-diagnostics.json")
)
```

该文件只包含结构化计数和固定中文动作，不包含原始 AX 标签或客户文字。

- [ ] **Step 4: 在首次向导高级区域展示发送策略**

在 `FirstRunViewModel` 增加可独立测试的 formatter：

```swift
static func capabilitySummary(key: String, status: CapabilityStatus) -> String {
    let suffix = status.level == .fallback ? "；可继续运行" : ""
    return "\(key) · \(status.strategy) · \(status.detail)\(suffix)"
}
```

`FirstRunView` 的高级能力列表使用该 formatter 展示 `sendAX` 的 `level`、`strategy` 和 `detail`。fallback 图标使用橙色；`unavailable` 才使用红色。

在 `FirstRunViewModelTests.swift` 增加：

```swift
func testSendFallbackSummaryExplainsThatRunCanContinue() {
    let text = FirstRunViewModel.capabilitySummary(
        key: "sendAX",
        status: CapabilityStatus(
            level: .fallback,
            strategy: "returnKeyOnce",
            detail: "发送校准：可按40个，有效0个"
        )
    )
    XCTAssertTrue(text.contains("可按40个"))
    XCTAssertTrue(text.contains("有效0个"))
    XCTAssertTrue(text.contains("可继续运行"))
}
```

phase 是否仍为 `.readOnlyReady` 已由 Task 3 的 coordinator 测试负责，UI 测试不重复模拟整个状态机。

- [ ] **Step 5: 运行诊断与 UI 测试**

Run:

```bash
swift test --filter DiagnosticBundleExporterTests
swift test --filter FirstRunViewModelTests
```

Expected: 全部 PASS；诊断可读且不会把可降级发送误报为整机阻塞。

- [ ] **Step 6: 提交诊断实现**

```bash
git add Sources/AutoReplyApp/Autoconfiguration/DiagnosticBundleExporter.swift \
  Sources/AutoReplyApp/Autoconfiguration/FirstRunView.swift \
  Tests/AutoReplyAppTests/DiagnosticBundleExporterTests.swift \
  Tests/AutoReplyAppTests/FirstRunViewModelTests.swift
git commit -m "feat: explain adaptive calibration decisions"
```

---

### Task 6: 生成可移植 Git 接管包并完成发布验收

**Files:**
- Create: `scripts/build-developer-handoff.sh`
- Create: `Tests/Packaging/developer_handoff_contract_test.py`
- Create: `docs/releases/2026-09-01-universal-calibration-recovery.md`
- Modify: `docs/把这个文件交给Codex-项目完整接管与Debug手册.md`
- Modify: `Packaging/首次安装说明.txt`
- Test: `Tests/Packaging/developer_handoff_contract_test.py`

**Interfaces:**
- Consumes: 当前 Git 仓库、已生成 DMG、发布提交。
- Produces: `千牛全自动客服-通用自适应版-完整开发交付包.zip`，内含 DMG、源码快照、`千牛全自动客服-完整历史.bundle`、手册、manifest 和 SHA-256。

- [ ] **Step 1: 写接管包契约测试**

`developer_handoff_contract_test.py` 使用临时目录和当前仓库执行脚本，传入一个固定测试 DMG 文件；测试必须：

```python
subprocess.run([script, "--dmg", str(fake_dmg), "--output", str(out)], check=True)
subprocess.run(["git", "bundle", "verify", str(bundle)], check=True)
subprocess.run(["git", "clone", str(bundle), str(clone)], check=True)
assert git(clone, "rev-parse", "HEAD") == manifest["releaseCommit"]
assert (package / "02-源码快照.zip").is_file()
assert (package / "03-Git完整历史" / "千牛全自动客服-完整历史.bundle").is_file()
assert (package / "00-先把这个文件交给Codex" / "把这个文件交给Codex-项目完整接管与Debug手册.md").is_file()
```

然后检查交付文件树中不存在实际的 `auth.json`、`history.jsonl`、`运行状态/图片指纹/*.json` 或 `data/conversations`；只扫描发布 manifest、SHA 清单和接管手册，断言不包含 `access_token`、`refresh_token` 或 `/Users/scy/`。源码可以合法包含这些文件名的防护代码和测试文字，因此不能用全包字符串搜索制造误报。

- [ ] **Step 2: 运行契约测试确认 RED**

Run:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 Tests/Packaging/developer_handoff_contract_test.py
```

Expected: `scripts/build-developer-handoff.sh` 不存在而失败。

- [ ] **Step 3: 实现接管包脚本**

脚本参数固定为：

```text
build-developer-handoff.sh --dmg <absolute-path> --output <absolute-directory>
```

脚本必须依次：

1. `git status --porcelain` 只允许已知构建缓存未跟踪目录，不允许已跟踪文件脏改动；
2. 读取 `git rev-parse HEAD` 和 `git branch --show-current`；
3. `git archive --format=zip --output 02-源码快照.zip HEAD`；
4. `git bundle create 03-Git完整历史/千牛全自动客服-完整历史.bundle --all`；
5. `git bundle verify`；
6. 在 `mktemp -d` 中 clone bundle 并确认 clone HEAD 等于发布提交；
7. 复制 DMG、接管手册、首次安装说明；
8. 生成 `release-manifest.json`，字段固定为 `schemaVersion`、`releaseCommit`、`releaseBranch`、`createdAtUTC`、`notarizationClaim`；
9. 对 DMG、源码 ZIP、bundle、手册和 manifest 生成 `SHA256SUMS.txt`；
10. 使用 `ditto -c -k --sequesterRsrc --keepParent` 生成最终 ZIP；
11. 临时目录使用 trap 删除。

`notarizationClaim` 默认为 `not-notarized-internal-test`；只有外部显式传入 `AUTOREPLY_NOTARIZATION_ACCEPTED=1` 才写 `notarized`。

- [ ] **Step 4: 更新 Codex 接管手册**

将手册中“必须收到 `.git` 目录”的表述替换为：

```bash
git bundle verify '03-Git完整历史/千牛全自动客服-完整历史.bundle'
git clone '03-Git完整历史/千牛全自动客服-完整历史.bundle' '千牛全自动客服-可修改源码'
cd '千牛全自动客服-可修改源码'
git rev-parse HEAD
```

手册要求接管 Codex 自动执行：校验哈希、备份旧 App、检查权限、只读导出 AX、生成本机 fixture、先写失败测试、修复、全量测试、构建安装、OCR/V2/Codex 预热、确认 `readOnlyReady`，最后才根据用户设置自动运行。

明确写出：Codex 不能替用户开启 macOS 权限、登录千牛或提供 Developer ID；遇到这些外部前置时显示具体中文动作并持续等待。

- [ ] **Step 5: 运行接管包契约测试并确认 GREEN**

Run:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 Tests/Packaging/developer_handoff_contract_test.py
```

Expected: bundle verify、clone、HEAD 比对、隐私扫描和文件结构全部 PASS。

- [ ] **Step 6: 提交接管包实现**

```bash
git add scripts/build-developer-handoff.sh \
  Tests/Packaging/developer_handoff_contract_test.py \
  docs/把这个文件交给Codex-项目完整接管与Debug手册.md \
  Packaging/首次安装说明.txt
git commit -m "feat: package portable Git handoff for colleague Macs"
```

- [ ] **Step 7: 运行全部自动化测试**

Run:

```bash
swift test
swift test --package-path components/batch-source
swift test --package-path components/ocr-source
swift test --package-path components/sender-source
swift test --package-path components/unread-source
PYTHONDONTWRITEBYTECODE=1 python3 Tests/BaselineScriptsTests/freeze_per_user_session_baseline_test.py
PYTHONDONTWRITEBYTECODE=1 python3 Tests/Packaging/verify_baseline_test.py
PYTHONDONTWRITEBYTECODE=1 python3 Tests/Packaging/developer_handoff_contract_test.py
```

Expected: 所有测试退出码 0；既有 A/B/current fixture 全部通过；无测试改动版本 A。

- [ ] **Step 8: 构建、挂载并校验最终 DMG**

Run:

```bash
AUTOREPLY_SIGNING_IDENTITY=- scripts/build-distribution-dmg.sh
```

挂载 DMG 后验证：

```bash
codesign --verify --deep --strict '/Volumes/千牛全自动客服-通用自适应版/安装并启动.app'
file '/Volumes/千牛全自动客服-通用自适应版/安装并启动.app/Contents/MacOS/QianniuInstallerApp'
```

Expected: 签名校验通过；可执行文件包含 `arm64`；输出明确 `NOTARIZATION=not_requested_adhoc`。

- [ ] **Step 9: 生成最终完整开发交付包**

Run:

```bash
scripts/build-developer-handoff.sh \
  --dmg "$PWD/build-output/千牛全自动客服-通用自适应版.dmg" \
  --output "$PWD/build-output/handoff"
```

Expected: 生成 `千牛全自动客服-通用自适应版-完整开发交付包.zip`；bundle 可独立 clone；manifest 的 `releaseCommit` 等于最终 HEAD。

- [ ] **Step 10: 同事 B 真机验收后再标记可投入运行**

同事 B 使用最终 ZIP 完成：安装、两项权限、客服名、Codex 登录、自动校准、OCR/V2 预热。只读验收必须显示：

```text
发送校准：可按40个；已选择发送按钮
```

或：

```text
发送校准：可按40个；使用Return降级；可继续运行
```

随后用测试客户发送一条文字，确认发现、OCR、V2、Codex、输入、发送和发送后核对全部完成。只有该真机测试通过后，才将同事 B 标记为已验证；同事 A 在其真机测试通过前保持“离线 fixture 兼容、真机待验收”。

- [ ] **Step 11: 提交发布清单与验收记录**

将不含客户内容的测试计数、DMG SHA-256、交付 ZIP SHA-256、release commit 和 A/B 验收状态写入 `docs/releases/2026-09-01-universal-calibration-recovery.md`，然后：

```bash
git add docs/releases/2026-09-01-universal-calibration-recovery.md
git commit -m "docs: record universal calibration release evidence"
```

---

## Plan Self-Review Mapping

- 发送候选误判与 Return 降级：Tasks 1–2。
- 歧义不阻塞预热、恰好自动启动一次：Task 3。
- 旧候选版偏好迁移且保留业务历史：Task 4。
- 中文结构化诊断与 UI：Task 5。
- Git bundle、源码快照、接管手册、隐私边界和 DMG：Task 6。
- A/B/current 离线回归和同事 B 真机门禁：Tasks 1、2、6。
