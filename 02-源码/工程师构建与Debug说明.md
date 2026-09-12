# 版本 B 工程师构建与 Debug 说明

## 1. 恢复可修改的完整仓库

```bash
PACKAGE='/完整交付包的绝对路径'
git bundle verify "$PACKAGE/03-Git完整历史/千牛全自动客服.bundle"
git clone "$PACKAGE/03-Git完整历史/千牛全自动客服.bundle" "$PACKAGE/02-工作源码"
git -C "$PACKAGE/02-工作源码" rev-parse HEAD
```

将结果与 `06-校验/manifest.json` 的 `gitCommit` 对比。不要在 `02-源码/完整可编译源码` 上无历史地直接改；建议在克隆仓库中新建分支或 worktree。

## 2. 平台和依赖

- macOS 14 或更新；Apple Silicon `arm64`。
- Xcode Command Line Tools、Swift 5.9 或兼容版本。
- App 的大型离线依赖位于 DMG 中：Python.framework、Paddle OCR、ONNX/FastEmbed、V2 知识库、OpenCV 和 SenseVoice。Git 不重复塞入构建缓存或几百 MB 的可再分发副本。
- 构建脚本默认可从已安装的 `/Applications/千牛全自动客服-版本B.app` 自动发现这些资源；也可用脚本支持的 `AUTOREPLY_*_SOURCE` 环境变量显式传入。

## 3. 测试

```bash
cd "$PACKAGE/02-工作源码"
swift test
python3 -m unittest discover -s Tests/Packaging -p '*test.py'
python3 -m unittest discover -s Tests/Maintenance -p '*test.py'
```

修复 bug 时先加入能复现失败的测试，再做最小代码修改。不要只靠“能编译”判断真实千牛链路已通过。

## 4. 构建 App 与 DMG

固定产品身份：

```text
App: /Applications/千牛全自动客服-版本B.app
Bundle ID: com.scy.qianniu-autoreply.version-b
Architecture: arm64
```

典型构建：

```bash
cd "$PACKAGE/02-工作源码"
AUTOREPLY_APP_NAME='千牛全自动客服-版本B.app' \
AUTOREPLY_BUNDLE_IDENTIFIER='com.scy.qianniu-autoreply.version-b' \
scripts/build-installer-app.sh

scripts/build-distribution-dmg.sh
```

以脚本 `--help` 和 release manifest 为最终参数依据。DMG 构建后必须挂载验证，再检查：

```bash
codesign --verify --deep --strict '/构建结果/千牛全自动客服-版本B.app'
lipo -archs '/构建结果/千牛全自动客服-版本B.app/Contents/MacOS/AutoReplyApp'
```

如果更换签名身份或 Bundle ID，macOS 可能把它视为新应用并要求重新授权。为了复用同事已经给版本 B 的权限，保持 Bundle ID、固定安装路径和稳定签名身份不变。

## 5. Debug 顺序

先确定最早失败层：进程唯一性 → 权限 → 正确接待中心 → 文本模式 → 本机 profile → 红点/客户行 → 打开客户 → 截图/OCR → 图片或视频路由 → V2 → Codex → 输入 → 发送 → 转人工。

不要因后层错误去重写前层算法。新电脑结构差异先双击 `05-故障处理/一键导出诊断包.command`；诊断包不含客户聊天和凭据。需要更深证据时，获得用户授权后在该机生成脱敏 AX fixture，再为通用分类器补回归测试，禁止写某个 UID 或昵称专用分支。

运行数据根目录由当前用户动态生成：

```text
~/Library/Application Support/QianniuAutoReplyTaskIsolationCandidate/AI客服记录-任务隔离候选版/
```

不得写死 `/Users/scy` 或其他同事用户名。不要提交该运行目录、`auth.json`、客户历史、媒体、Token、Cookie、`.build`、构建缓存或旧实验 App。

## 6. 发布检查

发布前至少完成：全量 Swift/Python 测试、App 深度签名验证、arm64 验证、DMG 挂载、Git bundle 克隆、源码提交一致性、最终 ZIP SHA-256 复核和隐私路径扫描。保留上一版 App 备份；回滚只替换 App，不删除 Application Support。
