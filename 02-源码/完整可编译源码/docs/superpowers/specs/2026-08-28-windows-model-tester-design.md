# Windows 格志客服模型测试器设计规格

## 目标

制作一个可复制到 Windows 10/11 x64 电脑、解压后直接运行的格志客服模型模拟器。它只用于测试客服模型回答，不接入千牛，不包含 OCR、红点扫描或自动发送。

## 冻结的回答合同

- 模型固定为 `gpt-5.6-sol`。
- 推理强度固定为 `medium`。
- 使用同事电脑自己的 Codex ChatGPT 登录；程序启动 Codex CLI 的 `codex exec`，不得读取或使用 `OPENAI_API_KEY`、`CODEX_API_KEY`。
- Prompt 语义、结构化回答 Schema、V2 `top12` 混合检索算法、知识库 ZIP 和检索缓存必须与当前 macOS 测试器一致。
- 支持同一聊天连续追问；同一聊天保留 Codex session，删除聊天时同时删除聊天记录、附件和 session 绑定。
- 图片作为聊天消息和 Codex `-i` 附件传入；资料库中的视频、图片链接仍受当前可信链接规则约束。

## 用户体验

最终交付物名为 `格志客服模型测试器-Windows-x64.zip`。解压后双击 `格志客服模型测试器.exe`：

1. 启动器检查内置 Python、知识库、V2 检索资源和 Web 后端。
2. 启动仅绑定 `127.0.0.1` 的本地服务，自动选择空闲端口。
3. 启动器打开系统默认浏览器显示中文测试界面。
4. 界面显示 Codex 状态、固定模型、固定推理强度、检索阶段、生成阶段、总耗时和引用资料。
5. 用户可以发送文字、选择或拖入多张图片、新建聊天、删除当前聊天、删除全部聊天。
6. 关闭启动器窗口后，本地服务退出；浏览器页面显示服务已停止，而不是无限等待。

首次运行若未找到 Codex，界面明确显示安装说明；若找到但未登录，显示“请先在 PowerShell 运行 codex 并选择使用 ChatGPT 登录”。程序不得复制、打包或迁移任何人的 `%USERPROFILE%\.codex\auth.json`。

## 架构

### 1. Windows 启动器

一个自包含的 `win-x64` .NET 控制台启动器负责：

- 从可执行文件所在目录定位 `runtime\python.exe` 和 `app\server.py`；
- 使用随机握手令牌和动态端口启动后端；
- 轮询 `/api/health`，成功后打开浏览器；
- 将后端日志写入 `data\logs\launcher.log`；
- 后端异常退出时显示错误和日志路径；
- 启动器退出时终止其子进程。

启动器不实现客服算法，只负责可靠启动，因此不会导致 Mac 与 Windows 的回答行为分叉。

### 2. Python 本地后端

后端仅使用 Python 标准库提供 HTTP 服务和静态文件，业务模块分离为：

- `conversation_store.py`：聊天 JSONL、图片附件和 session 元数据的原子读写。
- `prompt_builder.py`：逐字保存并渲染当前客服 Prompt 合同。
- `knowledge_retriever.py`：调用未经修改的 `retrieve_top12.py`，返回 `v2-top12` 文档列表和上下文。
- `codex_runner.py`：发现原生 Windows Codex、校验 ChatGPT 登录、执行或恢复 `codex exec --json`，解析结构化结果与耗时。
- `service.py`：组合对话、检索、Codex 和诊断数据。
- `server.py`：HTTP 路由、上传限制和进程生命周期。

后端只监听回环地址，不接受局域网连接。所有用户文本、图片和导入资料都作为不可信数据放入 Prompt 的数据区，不能覆盖客服指令。

### 3. 浏览器 UI

前端是无外部 CDN、无网络依赖的 HTML/CSS/JavaScript：

- 左侧为聊天列表和新建/删除操作；
- 中间为按时间排列的客户与客服消息；
- 底部输入框支持 Enter 发送、Shift+Enter 换行、按钮选图和拖放图片；
- 右侧或折叠区域显示 Codex 登录状态、模型、检索引用和阶段耗时；
- 请求进行中禁止重复提交，但允许保留输入草稿；
- 错误保留在当前聊天中并允许一键重试，不把错误文本写成客服回答。

## Codex 集成

Codex CLI 使用官方非交互模式：

- 新聊天：`codex -a never exec --json --ignore-user-config --ignore-rules -m gpt-5.6-sol -c model_reasoning_effort=\"medium\" --skip-git-repo-check -s read-only --output-schema ... -o ... -`
- 连续聊天：使用 `codex exec resume <session-id>`，继续同一个会话。
- 图片使用重复的 `-i <absolute-path>` 参数。
- 从标准输入传入 Prompt；标准输出按 JSONL 增量读取，标准错误单独保存。
- 每次启动 Codex 子进程前删除 `OPENAI_API_KEY` 与 `CODEX_API_KEY` 环境变量。

Windows 原生 Codex 候选位置按以下顺序查找：显式配置、`PATH` 中的 `codex.exe`/`codex.cmd`、`%APPDATA%\npm\codex.cmd`。第一版不自动切换 WSL，以避免 Windows 路径、图片附件和登录目录出现两套状态；检测到只有 WSL Codex 时给出迁移说明。

官方依据：

- <https://learn.chatgpt.com/docs/non-interactive-mode>
- <https://learn.chatgpt.com/docs/windows/windows-app>
- <https://learn.chatgpt.com/docs/windows/wsl>

## 资源与打包

- 内置 CPython 3.12 Windows embeddable x64 运行时。
- Windows `cp312-win_amd64` 依赖从锁定清单下载并离线展开；不得复用 macOS `.so` 文件。
- 内置当前知识库 ZIP、V2 检索脚本、跨平台 ONNX/Tokenizer 模型缓存和 Windows ONNX Runtime/Numpy/Tokenizer 等 wheels。
- `manifest.json` 固定记录应用版本、知识库 SHA-256、模型、推理强度、检索器版本、Python 版本和依赖锁文件 SHA-256。
- 构建过程验证 ZIP 中不存在 `.app`、Mach-O、macOS `.so`、认证文件或 API Key。

## 本地数据

所有运行数据写到解压目录的 `data`：

- `data\conversations\<conversation-id>\history.jsonl`
- `data\conversations\<conversation-id>\images\...`
- `data\sessions.json`
- `data\v2-cache\...`
- `data\traces\...`
- `data\logs\...`

这样用户可以整体移动测试器，也能明确删除测试数据。删除当前或全部聊天必须使用原子改名后再删除，避免中断时留下半份索引。

## 错误处理

- 资源缺失或哈希错误：拒绝启动并指出具体文件。
- Codex 不存在/未登录：允许进入界面，但发送按钮显示可修复的诊断信息。
- V2 检索失败：为保持与现有实现一致，回退到完整知识库 ZIP 路径，并明确在诊断区标记 `full-zip-fallback`。
- Codex 失败或结构化输出无效：保留客户消息，绝不写入空客服消息；允许重试。
- 图片不存在、超过 20 MB 或类型不受支持：发送前拒绝，并保留文字草稿。
- 浏览器重复打开页面：后端以 conversation version 防止同一请求重复写入。

## 验证标准

### Mac 构建机可自动验证

- Python 单元测试覆盖聊天存储、Prompt、路径/命令构造、Codex JSONL 解析、重复提交、删除和错误回退。
- 使用假的 Codex 可执行文件完成端到端 HTTP 测试。
- 使用当前 10 个固定客服问题对 Windows 后端的 V2 检索结果与 Mac 当前实现做文档列表和上下文哈希对照。
- 构建测试验证 Windows Python/PE 启动器、资源哈希、无 macOS 二进制、无认证材料。

### 真实 Windows 电脑必须验证

- Windows 10/11 x64 解压启动，无需管理员权限。
- 本地 Codex ChatGPT 登录检测正确。
- 文字首轮、连续追问、单图、多图均能回答。
- 新建聊天、删除当前聊天、删除全部聊天正确。
- 模型显示 `gpt-5.6-sol · 中`，引用资料和耗时可见。
- 断网、Codex 未登录和后端异常均给出可读错误。

## 非目标

- 不接千牛。
- 不做 OCR、红点识别、队列调度或自动发送。
- 不提供 API Key 模式。
- 不自动安装 Codex，不复制 Codex 登录状态。
- 不支持 Windows ARM64 或 32 位。
- 不修改当前 macOS 测试器和生产客服助手的算法。
