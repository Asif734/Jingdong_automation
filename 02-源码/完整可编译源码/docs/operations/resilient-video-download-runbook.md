# 千牛客户视频下载恢复运行手册

## 适用范围

本手册适用于“千牛全自动客服-通用自适应版”的客户视频链路。只有千牛日志中同时满足精确 `105` 与 `MESSAGETEMPLATETYPE_VIDEO` 的客户消息进入该链路。`101`/`IMAGETEXT` 不作为图片或视频的最终证据，仍走原有视觉图片流程。

## 正常流程

1. 视觉层先确认聊天区出现媒体块。
2. 日志层用同一消息标识的精确 105 证据确认它是视频。
3. 程序点击一次播放区域，并在点击前监听千牛新增日志。
4. 取得临时地址后立即关闭播放器；下载在后台继续，不占用千牛 UI。
5. 先走独立的系统 URLSession；失败后最多并行尝试三条经过校验的备用地址。
6. 文件必须通过 MP4、时长、画面尺寸和编解码检查，才进入证据提取和 AI 回答。

## 失败与恢复

- 第一次即时恢复总预算为 30 秒。
- 即时线路均失败后，只向客户发送一次：
  `亲，视频暂时加载失败，麻烦您重新发送一次或简单描述一下问题，我这边继续帮您查看。`
- 后台在约 60、180、600 秒后请求新的临时地址；每次有不超过 10% 的随机抖动。
- 单条视频失败不会占用 UI、Codex 槽位或阻塞其他客户。
- 后来下载成功仍会正常分析并回答视频；先前的失败提示不会把该视频标成已完成。
- 发送结果为“已发送”或“点击后不确定”时，视频分析任务都进入终态，禁止自动重发造成重复回复。

## 进度文字

- `正在打开客户视频`：已确认精确 105，准备取得临时地址。
- `视频正在后台下载`：播放器可以关闭，下载不再占用 UI。
- `视频已下载，正在校验`：文件尚未交给 AI。
- `CDN线路不可达，正在换线路`：本轮失败，后台等待或切换线路；其他客户照常运行。
- `视频已下载，正在准备回答`：正在提取关键帧/语音或等待 AI。
- `视频处理完成`：本条视频的分析回复已经完成终态记账。
- `视频暂时无法下载，已继续处理其他客户`：重试预算已用完，但全局程序没有停止。

## 本地状态位置

运行根目录：

`~/Library/Application Support/QianniuAutoReplyTaskIsolationCandidate/AI客服记录-任务隔离候选版`

关键文件：

- `运行状态/媒体路由/video-transfer-state-v2.json`：脱敏的持久化传输状态。
- `运行状态/媒体路由/video-analysis-inbox.json`：已下载视频的证据/AI 交接状态。
- `运行状态/媒体路由/video-open-attempts.json`：物理点击判重记录。
- `运行状态/媒体路由/processed-events.json`：旧媒体路由兼容记录。
- `收到的视频/<message-hash>.mp4`：通过校验的视频。
- `收到的视频证据/<message-hash>/`：关键帧、语音和清单。
- `运行状态/调度器/`：回复任务和终态发送记录。

状态文件只保存 SHA-256 标识、分类、次数、时间和安全文件名；不得保存或导出签名 URL、原始 messageId、鉴权参数。

## 自动配置能力

`运行状态/自动配置/machine-compatibility.json` 使用 schema 4，并包含：

- `videoDownloadSystem`：独立 URLSession 系统线路。
- `videoDownloadAlternate`：系统 `/usr/bin/curl`、`/usr/bin/dig` 的备用线路。

备用能力不可用时，只关闭备用线路，不影响文字、图片、OCR、知识库或系统视频线路。千牛、macOS、AX 结构或 profile schema 变化会触发重新校准。

## 诊断

先运行无外部副作用的自动测试：

```bash
swift test --package-path components/ocr-source --filter VideoTransferFaultInjectionTests
swift test --filter VideoAnalysisInboxTests
swift test --filter SchedulerTests
```

再检查状态中是否泄漏临时地址：

```bash
rg -n 'auth_key=|msg2\.cloudvideocdn.*\.mp4\?' \
  "$HOME/Library/Application Support/QianniuAutoReplyTaskIsolationCandidate/AI客服记录-任务隔离候选版/运行状态" \
  output-video-analysis
```

正常结果为空。导出诊断包时默认只导出环境、能力、失败分类、次数和阶段；只有用户明确选择原始证据时才包含截图/视频，仍不得包含签名 URL。

常见失败分类：`addressUnavailable`、`dnsResolution`、`connectTimeout`、`tlsFailure`、`offline`、`connectionReset`、`httpRejected`、`redirectRejected`、`responseTimeout`、`invalidContent`、`invalidVideo`、`localFile`、`retryBudgetExhausted`。

## 暂时关闭备用线路

运营界面暂未提供开关。诊断时通过依赖注入的故障测试关闭备用线路，不修改系统 DNS、`/etc/hosts` 或千牛文件。生产包如需紧急禁用，应回滚到安装前备份，不要删除状态文件。

## 回滚

1. 点击“停止”，确认 UI 操作和 CLI 均已释放。
2. 退出当前 App。
3. 将安装脚本创建的时间戳备份 App 复制回 `/Applications/千牛全自动客服-通用自适应版.app`。
4. 不删除运行根目录；聊天记录、图片指纹、视频、知识库索引和传输状态均应保留。
5. 验证签名后启动旧版：

```bash
codesign --verify --deep --strict '/Applications/千牛全自动客服-通用自适应版.app'
open '/Applications/千牛全自动客服-通用自适应版.app'
```

旧版不认识 schema 4 视频状态时应忽略该文件，不能手工降级或改写它。需要重新启用新版时，恢复新版 App 即可继续未完成的视频任务。
