#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
OUTPUT_DIR="${AUTOREPLY_OUTPUT_DIR:-$PROJECT_ROOT/build-output}"
INSTALLER_NAME="安装并启动.app"
PAYLOAD_NAME="${AUTOREPLY_APP_NAME:-千牛全自动客服-版本B.app}"
PAYLOAD_BUNDLE_IDENTIFIER="${AUTOREPLY_BUNDLE_IDENTIFIER:-com.scy.qianniu-autoreply.version-b}"
INSTALLER_PATH="$OUTPUT_DIR/$INSTALLER_NAME"
SIGNING_IDENTITY="${AUTOREPLY_SIGNING_IDENTITY:--}"
VERSION="${AUTOREPLY_APP_VERSION:-1.0}"
SEED_APP="${AUTOREPLY_RESOURCE_APP:-}"

fail() { print -u2 -- "$*"; exit 1; }
scratch_root=$(mktemp -d "${TMPDIR%/}/qianniu-installer-build.XXXXXX")
cleanup() { rm -rf -- "$scratch_root"; }
trap cleanup EXIT

if [[ -z "$SEED_APP" ]]; then
  for candidate in \
    "/Applications/千牛全自动客服-版本B.app" \
    "$HOME/Applications/千牛全自动客服-版本B.app" \
    "$PROJECT_ROOT/build-output/千牛全自动客服-版本B.app" \
    "$PROJECT_ROOT/output/千牛全自动客服-版本B.app"; do
    if [[ -d "$candidate" ]]; then SEED_APP="$candidate"; break; fi
  done
fi
[[ -d "$SEED_APP" ]] || fail "缺少版本 B 资源种子 App；请先安装版本 B 或设置 AUTOREPLY_RESOURCE_APP"

if [[ -z "${AUTOREPLY_V2_RUNTIME_SOURCE:-}" && -d "$SEED_APP/Contents/Resources/V2Knowledge" ]]; then
  mkdir -p "$scratch_root/v2-runtime/.venv/lib/python3.12"
  ln -s "$SEED_APP/Contents/Resources/V2Knowledge/site-packages" \
    "$scratch_root/v2-runtime/.venv/lib/python3.12/site-packages"
  ln -s "$SEED_APP/Contents/Resources/V2Knowledge/cache" "$scratch_root/v2-runtime/cache"
  export AUTOREPLY_V2_RUNTIME_SOURCE="$scratch_root/v2-runtime"
fi
if [[ -z "${AUTOREPLY_PYTHON_FRAMEWORK_SOURCE:-}" && -d "$SEED_APP/Contents/Resources/Python.framework" ]]; then
  export AUTOREPLY_PYTHON_FRAMEWORK_SOURCE="$SEED_APP/Contents/Resources/Python.framework"
fi
if [[ -z "${AUTOREPLY_KNOWLEDGE_BASE_SOURCE:-}" && -s "$SEED_APP/Contents/Resources/KnowledgeBase/Grozziie-China-KB.zip" ]]; then
  export AUTOREPLY_KNOWLEDGE_BASE_SOURCE="$SEED_APP/Contents/Resources/KnowledgeBase/Grozziie-China-KB.zip"
fi
if [[ -z "${AUTOREPLY_OPENCV_SITE_PACKAGES_SOURCE:-}" && -d "$SEED_APP/Contents/Resources/OpenCV/site-packages/cv2" ]]; then
  export AUTOREPLY_OPENCV_SITE_PACKAGES_SOURCE="$SEED_APP/Contents/Resources/OpenCV/site-packages"
fi
if [[ -z "${AUTOREPLY_SENSEVOICE_RUNTIME_SOURCE:-}" \
   && -d "$SEED_APP/Contents/Resources/SenseVoice/site-packages/numpy" \
   && -s "$SEED_APP/Contents/Resources/SenseVoice/model/model.int8.onnx" \
   && -s "$SEED_APP/Contents/Resources/SenseVoice/model/tokens.txt" ]]; then
  sensevoice_seed="$scratch_root/sensevoice-runtime"
  model_name="sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17"
  mkdir -p "$sensevoice_seed/venv/lib/python3.12" "$sensevoice_seed/model/$model_name"
  ln -s "$SEED_APP/Contents/Resources/SenseVoice/site-packages" \
    "$sensevoice_seed/venv/lib/python3.12/site-packages"
  ln -s "$SEED_APP/Contents/Resources/SenseVoice/model/model.int8.onnx" \
    "$sensevoice_seed/model/$model_name/model.int8.onnx"
  ln -s "$SEED_APP/Contents/Resources/SenseVoice/model/tokens.txt" \
    "$sensevoice_seed/model/$model_name/tokens.txt"
  export AUTOREPLY_SENSEVOICE_RUNTIME_SOURCE="$sensevoice_seed"
fi

payload_output="$scratch_root/payload"
AUTOREPLY_OUTPUT_DIR="$payload_output" \
AUTOREPLY_APP_NAME="$PAYLOAD_NAME" \
AUTOREPLY_BUNDLE_IDENTIFIER="$PAYLOAD_BUNDLE_IDENTIFIER" \
AUTOREPLY_SIGNING_IDENTITY="$SIGNING_IDENTITY" \
  "$PROJECT_ROOT/scripts/build-app.sh"
payload="$payload_output/$PAYLOAD_NAME"
[[ -d "$payload" ]] || fail "主程序构建失败：$payload"

installer_scratch="${AUTOREPLY_INSTALLER_SCRATCH_PATH:-$scratch_root/swift}"
swift build --package-path "$PROJECT_ROOT" --scratch-path "$installer_scratch" \
  --configuration release --arch arm64 --product QianniuInstallerApp -Xswiftc -gnone
bin_dir=$(swift build --package-path "$PROJECT_ROOT" --scratch-path "$installer_scratch" \
  --configuration release --arch arm64 --product QianniuInstallerApp -Xswiftc -gnone --show-bin-path)
[[ -x "$bin_dir/QianniuInstallerApp" ]] || fail "安装器可执行文件缺失"

candidate="$scratch_root/$INSTALLER_NAME"
mkdir -p "$candidate/Contents/MacOS" "$candidate/Contents/Resources"
cp "$bin_dir/QianniuInstallerApp" "$candidate/Contents/MacOS/QianniuInstallerApp"
chmod 755 "$candidate/Contents/MacOS/QianniuInstallerApp"
ditto "$payload" "$candidate/Contents/Resources/$PAYLOAD_NAME"

/usr/bin/python3 - "$candidate/Contents/Info.plist" "$VERSION" <<'PY'
import plistlib, pathlib, sys
path = pathlib.Path(sys.argv[1])
with path.open("wb") as handle:
    plistlib.dump({
        "CFBundleDevelopmentRegion": "zh_CN",
        "CFBundleDisplayName": "安装并启动",
        "CFBundleExecutable": "QianniuInstallerApp",
        "CFBundleIdentifier": "com.scy.qianniu-autoreply.version-b-installer",
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "安装并启动",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": sys.argv[2],
        "CFBundleVersion": "1",
        "LSMinimumSystemVersion": "14.0",
        "NSHighResolutionCapable": True,
        "NSPrincipalClass": "NSApplication",
    }, handle)
PY

/usr/bin/python3 - "$candidate/Contents/Resources/$PAYLOAD_NAME" \
  "$candidate/Contents/Resources/distribution-manifest.json" "$VERSION" <<'PY'
import hashlib, json, pathlib, sys
root, output, version = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
files = []
for path in sorted(root.rglob("*")):
    relative = path.relative_to(root)
    if (path.is_file() and not path.is_symlink()
            and all(not part.startswith(".") for part in relative.parts)):
        files.append({
            "path": relative.as_posix(),
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        })
output.write_text(json.dumps({
    "schemaVersion": 1,
    "appVersion": version,
    "architecture": "arm64",
    "files": files,
}, ensure_ascii=False, sort_keys=True) + "\n", encoding="utf-8")
PY

sign_options=()
[[ "$SIGNING_IDENTITY" == "-" ]] || sign_options=(--options runtime)
codesign --force "${sign_options[@]}" --timestamp=none --sign "$SIGNING_IDENTITY" "$candidate"
codesign --verify --deep --strict --verbose=2 "$candidate"
[[ $(lipo -archs "$candidate/Contents/MacOS/QianniuInstallerApp") == "arm64" ]] \
  || fail "安装器不是 arm64"

mkdir -p "$OUTPUT_DIR"
if [[ -e "$INSTALLER_PATH" ]]; then
  [[ -d "$INSTALLER_PATH" ]] || fail "拒绝覆盖非应用文件：$INSTALLER_PATH"
  rm -rf -- "$INSTALLER_PATH"
fi
mv "$candidate" "$INSTALLER_PATH"
print -- "INSTALLER_APP=$INSTALLER_PATH"
