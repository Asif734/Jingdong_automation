# `[图片]` 发送前复核 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 发送前继续完整 OCR 文本；无新红点时不复制旧图，有新红点时保留图片采集，并用左侧严格 `[图片]` 标记说明最后一条类型，避免漏掉“图片后紧跟文字”。

**Architecture:** 初次采集维持现状，仍识别并复制当前客户图片。发送前读取目标会话是否有新红点以及最新预览是否严格为 `[图片]`；OCR runner 接收是否采集图片的布尔策略。红点负责决定这一轮是否允许采图，因此图片+文字不会因最后预览变成文字而漏图；`[图片]` 用于确认和记录最后一条类型。文本、链接、身份核对、历史合并与发送逻辑保持不变。

**Tech Stack:** Swift 5.9、Swift Package Manager、macOS Accessibility、窗口截图红点检测、现有 PaddleOCR 与图片复制管线

**Spec:** 本对话中用户于 2026-08-27 明确要求“就按照 `[图片]` 来判断”，并说明连续图片会把上一张顶出当前可见区域。

## Global Constraints

- 不修改初次 OCR、消息解析、客户身份、红点检测、AI prompt、FIFO 或发送算法。
- 只读取左侧会话行中严格等于 `[图片]` 的预览标记，不读取任意聊天正文作为控制信号。
- 无新红点时，发送前 OCR 不得点击任何图片复制按钮。
- 有新红点时，发送前 OCR 保持现有图片复制行为；即使最新预览是文字，也必须覆盖此前紧邻发送的图片。
- 无法可靠定位目标会话行时不得猜测固定坐标。

---

### Task 1: 左侧行暴露严格图片预览

**Files:**
- Modify: `components/unread-source/Sources/UnreadCore/Models.swift`
- Modify: `components/unread-source/Sources/UnreadCore/ConversationLocator.swift`
- Modify: `Sources/AutoReplyApp/NativeSession.swift`
- Test: `components/unread-source/Tests/UnreadCoreTests/UnreadCoreTests.swift`

**Interfaces:**
- Produces: `ConversationRow.latestPreviewIsImage: Bool`

- [ ] 写失败测试：行的后代静态文本严格为 `[图片]` 时结果为 `true`，相似文本和其他区域为 `false`。
- [ ] 运行 UnreadCore 聚焦测试并确认因属性/行为缺失而失败。
- [ ] 最小实现：仅为左侧会话行后代暴露严格 `[图片]` 标签并由 locator 归属到对应 UID。
- [ ] 运行 UnreadCore 全量测试确认通过。

### Task 2: 发送前决定是否采集图片

**Files:**
- Modify: `Sources/AutoReplyCore/SchedulerModels.swift`
- Modify: `Sources/AutoReplyCore/AutoReplyScheduler.swift`
- Modify: `Sources/AutoReplyApp/NativeAutomationDriver.swift`
- Modify: `Sources/AutoReplyApp/LiveNativeUI.swift`
- Modify: `components/ocr-source/Sources/QianniuOCRAppSupport/LiveOCRRunner.swift`
- Test: `Tests/AutoReplyCoreTests/SchedulerTests.swift`
- Test: `Tests/AutoReplyAppTests/NativeAutomationDriverTests.swift`
- Test: `components/ocr-source/Tests/QianniuOCRAppSupportTests/LiveOCRRunnerTests.swift`

**Interfaces:**
- Produces: `AutomationDriver.captureBeforeDelivery(uid:)`
- Consumes: `ConversationRow.latestPreviewIsImage`

- [ ] 写失败测试：初次采集包含图片；发送前无图片型新未读时 runner 跳过图片 detector/copy resolver；图片型新未读时保留图片采集。
- [ ] 运行三个聚焦测试并分别确认正确失败。
- [ ] 最小实现：Live UI 用稳定前后场景、红点和严格 `[图片]` 计算布尔值；driver 仅把该布尔值传给 OCR runner；scheduler 只把发送前调用切换到新入口。
- [ ] 运行聚焦测试确认通过，并检查旧的补充消息、人工回复抑制和身份核对测试仍通过。

### Task 3: 完整验证与应用交付

**Files:**
- Verify only; do not change algorithms.

**Interfaces:**
- Consumes: Tasks 1–2 的已通过实现。

- [ ] 运行根包、Unread、OCR 三套完整测试。
- [ ] 运行发布构建与现有打包脚本。
- [ ] 安装并打开 `/Applications/千牛全自动客服-实验版.app`。
- [ ] 用用户视角验证：旧图可见但无新红点时不点复制；发送一张新图后左侧 `[图片]` 与红点触发一次图片采集；回复前不重复触发第二次 AI。
- [ ] 检查日志只出现预期的一次生成与一次发送，并报告实际证据与任何剩余限制。
