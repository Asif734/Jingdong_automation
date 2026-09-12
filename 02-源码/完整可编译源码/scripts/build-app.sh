#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
OUTPUT_DIR="${AUTOREPLY_OUTPUT_DIR:-$PROJECT_ROOT/output}"
APP_NAME="${AUTOREPLY_APP_NAME:-千牛全自动客服-版本B.app}"
APP_PATH="$OUTPUT_DIR/$APP_NAME"
EXECUTABLE_NAME="AutoReplyApp"
BUNDLE_IDENTIFIER="${AUTOREPLY_BUNDLE_IDENTIFIER:-com.scy.qianniu-autoreply.version-b}"
DISPLAY_NAME="${APP_NAME%.app}"
SIGNING_IDENTITY="${AUTOREPLY_SIGNING_IDENTITY:-Apple Development: Chu Ye Shi (6Q9HFP6LJJ)}"
WEB_ROOT="$PROJECT_ROOT/components/ocr-source/Sources/QianniuOCRAppSupport/Resources/WebOCR"
V2_ROOT="$PROJECT_ROOT/Resources/V2Knowledge"
V2_RUNTIME_SOURCE="${AUTOREPLY_V2_RUNTIME_SOURCE:-}"
PYTHON_FRAMEWORK_SOURCE="${AUTOREPLY_PYTHON_FRAMEWORK_SOURCE:-/Library/Frameworks/Python.framework}"
KNOWLEDGE_BASE_SOURCE="${AUTOREPLY_KNOWLEDGE_BASE_SOURCE:-}"
V2_SITE_PACKAGES="$V2_RUNTIME_SOURCE/.venv/lib/python3.12/site-packages"
V2_SEED_CACHE="$V2_RUNTIME_SOURCE/cache"
OPENCV_SITE_PACKAGES_SOURCE="${AUTOREPLY_OPENCV_SITE_PACKAGES_SOURCE:-/Library/Frameworks/Python.framework/Versions/3.12/lib/python3.12/site-packages}"
OPENCV_SCRIPT="$PROJECT_ROOT/components/ocr-source/Sources/QianniuOCRAppSupport/Resources/OpenCV/video_play_locator.py"
SENSEVOICE_RUNTIME_SOURCE="${AUTOREPLY_SENSEVOICE_RUNTIME_SOURCE:-}"
SENSEVOICE_SCRIPT="$PROJECT_ROOT/Resources/SenseVoice/serve_sensevoice.py"
SENSEVOICE_SITE_PACKAGES="$SENSEVOICE_RUNTIME_SOURCE/venv/lib/python3.12/site-packages"
SENSEVOICE_MODEL="$SENSEVOICE_RUNTIME_SOURCE/model/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17"

required_web_files=(
  index.html
  ocr.js
  models/PP-OCRv5_mobile_det_onnx_infer.tar
  models/PP-OCRv5_mobile_rec_onnx_infer.tar
  ort/ort-wasm-simd-threaded.mjs
  ort/ort-wasm-simd-threaded.wasm
  ort/ort-wasm-simd-threaded.jsep.mjs
  ort/ort-wasm-simd-threaded.jsep.wasm
)

fail() { print -u2 -- "$*"; exit 1; }

validate_signing_identity() {
  if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    print -- "SIGNING_MODE=adhoc"
    return 0
  fi
  local identity_output
  identity_output=$(security find-identity -v -p codesigning)
  print -r -- "$identity_output" | grep -Fq -- "$SIGNING_IDENTITY" \
    || fail "缺少稳定签名证书：$SIGNING_IDENTITY"
  print -- "SIGNING_MODE=certificate"
}

SIGNING_OPTIONS=()
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
  SIGNING_OPTIONS=(--options runtime)
fi

if [[ "${AUTOREPLY_VALIDATE_SIGNING_ONLY:-0}" == "1" \
   || "${AUTOREPLY_PRINT_SIGNING_OPTIONS_ONLY:-0}" == "1" ]]; then
  validate_signing_identity
  if [[ "${AUTOREPLY_PRINT_SIGNING_OPTIONS_ONLY:-0}" == "1" ]]; then
    print -- "SIGNING_OPTIONS=${(j: :)SIGNING_OPTIONS}"
  fi
  exit 0
fi

[[ -n "$V2_RUNTIME_SOURCE" ]] \
  || fail "请设置 AUTOREPLY_V2_RUNTIME_SOURCE 指向 V2 本地运行目录"
[[ -n "$KNOWLEDGE_BASE_SOURCE" ]] \
  || fail "请设置 AUTOREPLY_KNOWLEDGE_BASE_SOURCE 指向知识库 ZIP"
[[ -n "$SENSEVOICE_RUNTIME_SOURCE" ]] \
  || fail "请设置 AUTOREPLY_SENSEVOICE_RUNTIME_SOURCE 指向 SenseVoice 隔离运行目录"
[[ -s "$KNOWLEDGE_BASE_SOURCE" ]] || fail "知识库不存在：$KNOWLEDGE_BASE_SOURCE"
[[ -x "$PYTHON_FRAMEWORK_SOURCE/Versions/3.12/bin/python3.12" ]] \
  || fail "缺少可移植 Python 3.12：$PYTHON_FRAMEWORK_SOURCE"

for relative_path in "${required_web_files[@]}"; do
  [[ -s "$WEB_ROOT/$relative_path" ]] || fail "缺少离线 OCR 资源：$relative_path"
done
for required_path in "$V2_ROOT/retrieve_top12.py" "$V2_ROOT/serve_top12.py" \
                     "$V2_ROOT/rag_b0.py" "$V2_ROOT/hybrid.py" \
                     "$V2_SITE_PACKAGES/fastembed" "$V2_SITE_PACKAGES/onnxruntime" \
                     "$V2_SEED_CACHE/models"; do
  [[ -e "$required_path" ]] || fail "缺少 V2 Top-12 本地检索资源：$required_path"
done
[[ -s "$OPENCV_SCRIPT" ]] || fail "缺少 OpenCV 播放按钮定位脚本"
[[ -d "$OPENCV_SITE_PACKAGES_SOURCE/cv2" ]] || fail "缺少 OpenCV Python 运行库：$OPENCV_SITE_PACKAGES_SOURCE/cv2"
[[ -s "$SENSEVOICE_SCRIPT" ]] || fail "缺少 SenseVoice 常驻 worker"
[[ -d "$SENSEVOICE_SITE_PACKAGES/numpy" ]] || fail "缺少 SenseVoice NumPy 运行库"
[[ -d "$SENSEVOICE_SITE_PACKAGES/sherpa_onnx" ]] || fail "缺少 sherpa-onnx 运行库"
[[ -s "$SENSEVOICE_MODEL/model.int8.onnx" ]] || fail "缺少 SenseVoice INT8 模型"
[[ -s "$SENSEVOICE_MODEL/tokens.txt" ]] || fail "缺少 SenseVoice tokens"

validate_signing_identity

mkdir -p "$OUTPUT_DIR"
if [[ -e "$APP_PATH" ]]; then
  [[ -d "$APP_PATH" ]] || fail "拒绝替换非应用输出：$APP_PATH"
  existing_id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)
  [[ "$existing_id" == "$BUNDLE_IDENTIFIER" ]] \
    || fail "拒绝替换无关应用：$APP_PATH"
  [[ ! -x "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME" ]] \
    || ! pgrep -f -- "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME" >/dev/null \
    || fail "新应用正在运行；未替换：$APP_PATH"
fi

scratch="${AUTOREPLY_SCRATCH_PATH:-${TMPDIR%/}/qianniu-autoreply-build-arm64}"
swift build --package-path "$PROJECT_ROOT" --scratch-path "$scratch" --configuration release --arch arm64 -Xswiftc -gnone
bin_dir=$(swift build --package-path "$PROJECT_ROOT" --scratch-path "$scratch" --configuration release --arch arm64 -Xswiftc -gnone --show-bin-path)
[[ -x "$bin_dir/$EXECUTABLE_NAME" ]] || fail "未找到构建产物：$bin_dir/$EXECUTABLE_NAME"
resource_bundle="$bin_dir/QianniuCodexBatchRunner_CustomerReplyBatchAppSupport.bundle"
[[ -d "$resource_bundle" ]] || fail "未找到回复 Schema 资源包：$resource_bundle"
[[ -s "$resource_bundle/reply-output.schema.json" ]] || fail "回复 Schema 资源包不完整"

temporary_root=$(mktemp -d "$OUTPUT_DIR/.autoreply-package.XXXXXX")
temporary_app="$temporary_root/$APP_NAME"
cleanup() { rm -rf -- "$temporary_root"; }
trap cleanup EXIT
mkdir -p "$temporary_app/Contents/MacOS" "$temporary_app/Contents/Resources"
cp "$PROJECT_ROOT/Packaging/Info.plist" "$temporary_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $DISPLAY_NAME" "$temporary_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $DISPLAY_NAME" "$temporary_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_IDENTIFIER" "$temporary_app/Contents/Info.plist"
cp "$PROJECT_ROOT/Packaging/AppIcon.icns" "$temporary_app/Contents/Resources/AppIcon.icns"
cp "$bin_dir/$EXECUTABLE_NAME" "$temporary_app/Contents/MacOS/$EXECUTABLE_NAME"
chmod 755 "$temporary_app/Contents/MacOS/$EXECUTABLE_NAME"
ditto "$resource_bundle" "$temporary_app/Contents/Resources/${resource_bundle:t}"
# ResourceRootSelection checks this installed root first, so do not also copy
# the SwiftPM fallback bundle containing the same large offline OCR payload.
ditto "$WEB_ROOT" "$temporary_app/Contents/Resources/WebOCR"
mkdir -p "$temporary_app/Contents/Resources/V2Knowledge"
rsync -a --exclude '__pycache__' --exclude '*.pyc' \
  "$V2_ROOT/" "$temporary_app/Contents/Resources/V2Knowledge/"
rsync -a --exclude '__pycache__' --exclude '*.pyc' \
  "$V2_SITE_PACKAGES/" "$temporary_app/Contents/Resources/V2Knowledge/site-packages/"
ditto "$V2_SEED_CACHE" "$temporary_app/Contents/Resources/V2Knowledge/cache"
mkdir -p "$temporary_app/Contents/Resources/OpenCV/site-packages"
ditto "$OPENCV_SCRIPT" "$temporary_app/Contents/Resources/OpenCV/video_play_locator.py"
ditto "$OPENCV_SITE_PACKAGES_SOURCE/cv2" "$temporary_app/Contents/Resources/OpenCV/site-packages/cv2"
for metadata in "$OPENCV_SITE_PACKAGES_SOURCE"/opencv_python-*.dist-info; do
  [[ -d "$metadata" ]] || continue
  ditto "$metadata" "$temporary_app/Contents/Resources/OpenCV/site-packages/${metadata:t}"
done
mkdir -p "$temporary_app/Contents/Resources/SenseVoice/site-packages" \
         "$temporary_app/Contents/Resources/SenseVoice/model"
ditto "$SENSEVOICE_SCRIPT" "$temporary_app/Contents/Resources/SenseVoice/serve_sensevoice.py"
ditto "$SENSEVOICE_SITE_PACKAGES/numpy" "$temporary_app/Contents/Resources/SenseVoice/site-packages/numpy"
ditto "$SENSEVOICE_SITE_PACKAGES/sherpa_onnx" "$temporary_app/Contents/Resources/SenseVoice/site-packages/sherpa_onnx"
ditto "$SENSEVOICE_MODEL/model.int8.onnx" "$temporary_app/Contents/Resources/SenseVoice/model/model.int8.onnx"
ditto "$SENSEVOICE_MODEL/tokens.txt" "$temporary_app/Contents/Resources/SenseVoice/model/tokens.txt"
mkdir -p "$temporary_app/Contents/Resources/KnowledgeBase" \
         "$temporary_app/Contents/Resources/Python.framework"
ditto "$KNOWLEDGE_BASE_SOURCE" \
      "$temporary_app/Contents/Resources/KnowledgeBase/Grozziie-China-KB.zip"
source_kb_hash=$(shasum -a 256 "$KNOWLEDGE_BASE_SOURCE" | awk '{print $1}')
/usr/bin/python3 - "$source_kb_hash" \
  "$temporary_app/Contents/Resources/KnowledgeBase/manifest.json" <<'PY'
import json
import pathlib
import sys

pathlib.Path(sys.argv[2]).write_text(json.dumps({
    "knowledge_sha256": sys.argv[1],
    "index_algorithm_version": "v2-index-1",
}, ensure_ascii=False, sort_keys=True) + "\n", encoding="utf-8")
PY
rsync -a \
  --exclude '/Versions/3.12/lib/python3.12/site-packages' \
  --exclude '/Versions/3.12/lib/python3.12/test' \
  --exclude '/Versions/3.12/lib/python3.12/idlelib' \
  --exclude '/Versions/3.12/lib/python3.12/tkinter' \
  --exclude '/Versions/3.12/lib/python3.12/turtledemo' \
  --exclude '/Versions/3.12/lib/python3.12/ensurepip' \
  "$PYTHON_FRAMEWORK_SOURCE/" \
  "$temporary_app/Contents/Resources/Python.framework/"
chmod 755 "$temporary_app/Contents/Resources/Python.framework/Versions/3.12/bin/python3.12"
/usr/bin/python3 "$PROJECT_ROOT/components/model-tester-source/scripts/relocate-python.py" \
  "$temporary_app/Contents/Resources"

# install_name_tool invalidates upstream signatures, and Python loads native
# extensions from site-packages in-process. Sign every packaged Mach-O with the
# same team before sealing the outer app; --deep alone does not reliably revisit
# arbitrary binaries that already carry a third-party seal.
while IFS= read -r -d '' candidate; do
  if /usr/bin/file "$candidate" | grep -q 'Mach-O'; then
    # Nested Python executables and extension modules must share the local
    # signer, but must not individually enable hardened runtime: doing so turns
    # on library validation before Python loads its sibling framework/modules.
    codesign --force --timestamp=none --sign "$SIGNING_IDENTITY" "$candidate"
  fi
done < <(find "$temporary_app/Contents/Resources" -type f -print0)

plutil -lint "$temporary_app/Contents/Info.plist"
[[ $(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$temporary_app/Contents/Info.plist") == "$BUNDLE_IDENTIFIER" ]] \
  || fail "应用标识符不匹配"
codesign --force --deep "${SIGNING_OPTIONS[@]}" --timestamp=none --sign "$SIGNING_IDENTITY" "$temporary_app"
codesign --verify --deep --strict --verbose=2 "$temporary_app"
PYTHONDONTWRITEBYTECODE=1 \
PYTHONPATH="$temporary_app/Contents/Resources/SenseVoice/site-packages:$temporary_app/Contents/Resources/OpenCV/site-packages:$temporary_app/Contents/Resources/V2Knowledge/site-packages" \
  "$temporary_app/Contents/Resources/Python.framework/Versions/3.12/bin/python3.12" \
  -c 'import cv2, fastembed, numpy, onnxruntime, sherpa_onnx' \
  || fail "打包后 Python/V2 原生依赖无法加载"
lipo -archs "$temporary_app/Contents/MacOS/$EXECUTABLE_NAME" | grep -qx 'arm64' \
  || fail "构建不是仅 arm64：$(lipo -archs "$temporary_app/Contents/MacOS/$EXECUTABLE_NAME")"
for relative_path in "${required_web_files[@]}"; do
  [[ -s "$temporary_app/Contents/Resources/WebOCR/$relative_path" ]] || fail "打包后 OCR 资源缺失：$relative_path"
done
[[ -s "$temporary_app/Contents/Resources/${resource_bundle:t}/reply-output.schema.json" ]] \
  || fail "打包后回复 Schema 缺失"
[[ -s "$temporary_app/Contents/Resources/V2Knowledge/retrieve_top12.py" ]] \
  || fail "打包后 V2 Top-12 检索器缺失"
[[ -s "$temporary_app/Contents/Resources/V2Knowledge/serve_top12.py" ]] \
  || fail "打包后 V2 常驻检索 worker 缺失"
[[ -d "$temporary_app/Contents/Resources/V2Knowledge/site-packages/fastembed" ]] \
  || fail "打包后 V2 Python 运行库缺失"
[[ -d "$temporary_app/Contents/Resources/V2Knowledge/cache/models" ]] \
  || fail "打包后 V2 本地模型缺失"
[[ -s "$temporary_app/Contents/Resources/OpenCV/site-packages/cv2/cv2.abi3.so" ]] \
  || fail "打包后 OpenCV 运行库缺失"
[[ -s "$temporary_app/Contents/Resources/SenseVoice/serve_sensevoice.py" ]] \
  || fail "打包后 SenseVoice worker 缺失"
[[ -s "$temporary_app/Contents/Resources/SenseVoice/model/model.int8.onnx" ]] \
  || fail "打包后 SenseVoice INT8 模型缺失"
[[ -s "$temporary_app/Contents/Resources/SenseVoice/model/tokens.txt" ]] \
  || fail "打包后 SenseVoice tokens 缺失"
[[ -x "$temporary_app/Contents/Resources/Python.framework/Versions/3.12/bin/python3.12" ]] \
  || fail "打包后 Python 3.12 缺失"
[[ -s "$temporary_app/Contents/Resources/KnowledgeBase/Grozziie-China-KB.zip" ]] \
  || fail "打包后知识库种子缺失"
[[ -s "$temporary_app/Contents/Resources/KnowledgeBase/manifest.json" ]] \
  || fail "打包后知识库 manifest 缺失"
packaged_kb_hash=$(shasum -a 256 \
  "$temporary_app/Contents/Resources/KnowledgeBase/Grozziie-China-KB.zip" | awk '{print $1}')
[[ "$packaged_kb_hash" == "$source_kb_hash" ]] \
  || fail "打包后知识库校验失败"

if [[ -e "$APP_PATH" ]]; then
  backup_dir="$OUTPUT_DIR/previous-builds"
  mkdir -p "$backup_dir"
  stamp=$(date +%Y%m%d-%H%M%S)
  backup="$backup_dir/${APP_NAME%.app}-$stamp.app"
  while [[ -e "$backup" ]]; do
    backup="$backup_dir/${APP_NAME%.app}-$stamp-$RANDOM.app"
  done
  mv "$APP_PATH" "$backup"
  print -- "PRESERVED_PREVIOUS_BUILD=$backup"
fi
mv "$temporary_app" "$APP_PATH"
print -- "APP_PATH=$APP_PATH"
