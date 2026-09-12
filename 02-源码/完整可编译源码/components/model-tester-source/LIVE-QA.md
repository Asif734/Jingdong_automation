# 格志客服模型测试器 LIVE QA

日期：2026-08-28

## 构建与自动测试

- `swift test --package-path components/model-tester-source`
- 结果：16 tests，0 failures。
- `Tests/PackagingTests/prepare_resources_test.sh`：通过。
- `Tests/PackagingTests/build_app_test.sh`：通过。
- `codesign --verify --deep --strict`：通过。
- 主程序架构：arm64。
- 最低系统：macOS 14.0。
- App体积：532 MB。
- DMG体积：295 MB。
- DMG SHA-256：`c0728307a079eb32a2b101abd266c9f8f49d0839e2497fbe250d2db56207f67b`。

## 自带运行环境验证

- 包内Python能够独立导入 `ssl`、`fastembed` 和 `onnxruntime`。
- 包内 `retrieve_top12.py` 直接读取包内知识库 ZIP 成功。
- 返回版本：`v2-top12`。
- 测试问题：`TP732支持Mac吗`。
- 返回资料数：14。
- 聚焦上下文字符数：6344。

## 用户视角验证

通过Computer Use关闭旧进程并打开最终App：

- 顶部显示“只测试模型，不连接千牛”。
- 模型显示 `GPT-5.6 Sol · 中`。
- 知识库显示“随包知识库”。
- 图片附件按钮可见。
- 新建测试会清空旧界面历史。

真实问答一：

- 客户：`TP732支持Mac吗？`
- 回答：`亲，TP732 不支持原生 macOS，仅支持 Windows 电脑使用哦。`
- 连续追问：`那Windows 11呢？`
- 回答：`亲，TP732 支持 Windows 11，可以连接电脑安装对应驱动使用哦。`
- 第二轮会话状态：`resumed`，证明连续追问复用会话。

最终构建真实问答：

- 客户：`M880停电后不工作怎么办？`
- 回答：`亲，请先看一下机器背面标签，型号是 M880 还是 M880D？普通 M880 不支持停电打卡；M880D 是带备用电池的款式。`
- 总耗时：8.96秒。
- Codex：8.89秒。
- 登录检查：0.06秒。
- 会话：`new`。
- UI显示13份本次引用资料，包括 `attendance_machine_m880_after_sales_issues_kb.md`、`printernoble_m880_official_specs_kb.md` 和 `m880_attendance_machine_kb.md`。

## 安全检查

- App不包含 `WebOCR`。
- App不包含千牛未读助手或发送器资源。
- App不包含 `auth.json`。
- App不包含API Key。
- 应用不申请辅助功能或屏幕录制权限。
