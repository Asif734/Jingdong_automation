#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
REPO_ROOT="$(cd "$PROJECT_ROOT/../.." && pwd -P)"
OUTPUT_DIR="${MODEL_TESTER_OUTPUT_DIR:-$REPO_ROOT/output/model-tester}"
APP_PATH="$OUTPUT_DIR/格志客服模型测试器.app"
EXECUTABLE="GrozziieModelTesterApp"
KB_PATH="${MODEL_TESTER_KB_PATH:-/Users/scy/Desktop/AI客服记录/知识库/Grozziie-China-KB-2026-08-24.zip}"
V2_ROOT="${MODEL_TESTER_V2_ROOT:-$REPO_ROOT/output/千牛全自动客服-实验版.app/Contents/Resources/V2Knowledge}"
PYTHON_FRAMEWORK="${MODEL_TESTER_PYTHON_FRAMEWORK:-/Library/Frameworks/Python.framework}"
SIGNING_IDENTITY="${MODEL_TESTER_SIGNING_IDENTITY:--}"

fail() { print -u2 -- "$*"; exit 1; }
[[ -s "$KB_PATH" ]] || fail "缺少知识库：$KB_PATH"
[[ -s "$V2_ROOT/retrieve_top12.py" ]] || fail "缺少V2检索资源：$V2_ROOT"
[[ -x "$PYTHON_FRAMEWORK/Versions/3.12/bin/python3.12" ]] || fail "缺少Python 3.12运行时"

mkdir -p "$OUTPUT_DIR"
SCRATCH="$PROJECT_ROOT/.build-package-arm64"
swift build --package-path "$PROJECT_ROOT" --scratch-path "$SCRATCH" \
  --configuration release --arch arm64 -Xswiftc -gnone
BIN_DIR=$(swift build --package-path "$PROJECT_ROOT" --scratch-path "$SCRATCH" \
  --configuration release --arch arm64 -Xswiftc -gnone --show-bin-path)
[[ -x "$BIN_DIR/$EXECUTABLE" ]] || fail "未找到构建产物"
RESOURCE_BUNDLE="$BIN_DIR/QianniuCodexBatchRunner_CustomerReplyBatchAppSupport.bundle"
[[ -s "$RESOURCE_BUNDLE/reply-output.schema.json" ]] || fail "缺少回复Schema资源包"

TEMP_ROOT=$(mktemp -d "$OUTPUT_DIR/.model-tester-package.XXXXXX")
TEMP_APP="$TEMP_ROOT/格志客服模型测试器.app"
cleanup() { rm -rf -- "$TEMP_ROOT"; }
trap cleanup EXIT
mkdir -p "$TEMP_APP/Contents/MacOS" "$TEMP_APP/Contents/Resources"
ditto "$PROJECT_ROOT/Packaging/Info.plist.template" "$TEMP_APP/Contents/Info.plist"
ditto "$BIN_DIR/$EXECUTABLE" "$TEMP_APP/Contents/MacOS/$EXECUTABLE"
chmod 755 "$TEMP_APP/Contents/MacOS/$EXECUTABLE"
ditto "$RESOURCE_BUNDLE" "$TEMP_APP/Contents/Resources/${RESOURCE_BUNDLE:t}"

KB_HASH=$(shasum -a 256 "$KB_PATH" | awk '{print $1}')
"$PROJECT_ROOT/scripts/prepare-resources.sh" \
  "$TEMP_APP/Contents/Resources" "$KB_PATH" "$V2_ROOT" "$PYTHON_FRAMEWORK" "$KB_HASH"
/usr/bin/python3 "$PROJECT_ROOT/scripts/relocate-python.py" "$TEMP_APP/Contents/Resources"

plutil -lint "$TEMP_APP/Contents/Info.plist"
# prepare-resources relocates Python and deliberately trims its original signed
# framework payload. Sign every relocated Mach-O dependency before sealing the
# framework and outer app; --deep alone does not replace all vendor signatures.
find "$TEMP_APP/Contents/Resources" -type f -print0 | while IFS= read -r -d '' candidate; do
  if file "$candidate" | grep -q 'Mach-O'; then
    codesign --force --options runtime --timestamp=none --sign "$SIGNING_IDENTITY" "$candidate"
  fi
done
codesign --force --deep --options runtime --timestamp=none --sign "$SIGNING_IDENTITY" \
  "$TEMP_APP/Contents/Resources/Python.framework"
codesign --force --deep --options runtime --timestamp=none --sign "$SIGNING_IDENTITY" "$TEMP_APP"
codesign --verify --deep --strict --verbose=2 "$TEMP_APP"
lipo -archs "$TEMP_APP/Contents/MacOS/$EXECUTABLE" | grep -qx arm64 \
  || fail "应用主程序不是arm64"
[[ ! -e "$TEMP_APP/Contents/Resources/WebOCR" ]] || fail "独立测试器错误包含OCR资源"
[[ ! -e "$TEMP_APP/Contents/Resources/auth.json" ]] || fail "独立测试器错误包含Codex凭据"

if [[ -e "$APP_PATH" ]]; then
  existing_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)
  [[ "$existing_id" == "com.scy.grozziie-model-tester" ]] || fail "拒绝覆盖无关应用：$APP_PATH"
  mv "$APP_PATH" "$OUTPUT_DIR/格志客服模型测试器-previous-$(date +%Y%m%d-%H%M%S).app"
fi
mv "$TEMP_APP" "$APP_PATH"
print -- "APP_PATH=$APP_PATH"
