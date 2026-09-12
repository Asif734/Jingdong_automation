#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
OUTPUT_DIR="${PROJECT_ROOT:h:h}/outputs"
APP_PATH="$OUTPUT_DIR/千牛右侧面板OCR.app"
EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/千牛右侧面板OCR"
NODE_BIN="/Users/scy/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node"
WEB_RUNTIME="$PROJECT_ROOT/Sources/QianniuOCRAppSupport/Resources/WebOCR"
SIGNING_IDENTITY="${QIANNIU_OCR_SIGN_IDENTITY:-Apple Development: Chu Ye Shi (6Q9HFP6LJJ)}"

mkdir -p "$OUTPUT_DIR"

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

if [[ "${REBUILD_WEB:-0}" == "1" ]]; then
  PATH="${NODE_BIN:h}:$PATH" "$NODE_BIN" "$PROJECT_ROOT/WebOCR/scripts/build.mjs"
fi

for relative_path in "${required_web_files[@]}"; do
  if [[ ! -s "$WEB_RUNTIME/$relative_path" ]]; then
    print -u2 "缺少离线 OCR 资源：$relative_path（可设置 REBUILD_WEB=1 重新生成）"
    exit 1
  fi
done

swift build \
  --package-path "$PROJECT_ROOT" \
  --scratch-path "$PROJECT_ROOT/.build-universal-arm64" \
  --configuration release \
  --arch arm64 \
  -Xswiftc -gnone

swift build \
  --package-path "$PROJECT_ROOT" \
  --scratch-path "$PROJECT_ROOT/.build-universal-x86_64" \
  --configuration release \
  --arch x86_64 \
  -Xswiftc -gnone

ARM_BIN_DIR=$(swift build \
  --package-path "$PROJECT_ROOT" \
  --scratch-path "$PROJECT_ROOT/.build-universal-arm64" \
  --configuration release \
  --arch arm64 \
  -Xswiftc -gnone \
  --show-bin-path)

INTEL_BIN_DIR=$(swift build \
  --package-path "$PROJECT_ROOT" \
  --scratch-path "$PROJECT_ROOT/.build-universal-x86_64" \
  --configuration release \
  --arch x86_64 \
  -Xswiftc -gnone \
  --show-bin-path)

rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$PROJECT_ROOT/Packaging/Info.plist" "$APP_PATH/Contents/Info.plist"
lipo -create \
  "$ARM_BIN_DIR/QianniuOCRApp" \
  "$INTEL_BIN_DIR/QianniuOCRApp" \
  -output "$EXECUTABLE_PATH"
chmod 755 "$EXECUTABLE_PATH"
ditto \
  "$PROJECT_ROOT/Sources/QianniuOCRAppSupport/Resources/WebOCR" \
  "$APP_PATH/Contents/Resources/WebOCR"

security find-identity -v -p codesigning \
  | grep -Fq "\"$SIGNING_IDENTITY\"" || {
    print -u2 "缺少稳定签名证书：$SIGNING_IDENTITY"
    exit 1
  }

codesign --force --deep --options runtime --timestamp=none --sign "$SIGNING_IDENTITY" "$APP_PATH"

plutil -lint "$APP_PATH/Contents/Info.plist"
lipo -archs "$EXECUTABLE_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
