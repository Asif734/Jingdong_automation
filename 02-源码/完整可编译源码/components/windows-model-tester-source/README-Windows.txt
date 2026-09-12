格志客服模型测试器（Windows 10/11 x64）

用途：仅测试格志客服模型回答，不连接千牛，不会自动发送消息。

启动：
1. 完整解压 ZIP，不要直接在压缩包预览中运行。
2. 确认本机已经安装 Codex，并在 PowerShell 运行 codex，选择“使用 ChatGPT 登录”。
3. 双击“格志客服模型测试器.exe”。程序会在默认浏览器打开本地测试页面。
4. 关闭黑色启动窗口即可停止测试器。

固定配置：gpt-5.6-sol；推理强度 medium；V2 top12 知识库检索。
程序不使用 API Key，也不会复制或打包任何 Codex 登录文件。

数据位置：解压目录\data。删除聊天按钮会同时删除该聊天的本地图片。
日志位置：解压目录\data\logs\launcher.log 和 data\traces。

常见问题：
- 显示“未找到 Codex”：在 PowerShell 确认 codex 命令可以运行；若用 npm 安装，确认 %APPDATA%\npm 在 PATH。
- 显示“必须使用 ChatGPT 登录”：运行 codex logout，再运行 codex 并选择 ChatGPT 登录。
- Windows SmartScreen：核对文件来源后选择“更多信息→仍要运行”。本测试包目前未使用商业代码签名证书。
- 页面打不开：关闭旧启动窗口后重新双击；查看 data\logs\launcher.log。
