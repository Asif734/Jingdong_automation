#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
OUTPUT_DIR="${QIANNIU_OUTPUT_DIR:-${PROJECT_ROOT:h:h}/outputs}"
APP_PATH="$OUTPUT_DIR/AI客服-Codex批处理.app"
TEMP_APP="$OUTPUT_DIR/.AI客服-Codex批处理.$$.app"
EXECUTABLE_NAME="AI客服-Codex批处理"

mkdir -p "$OUTPUT_DIR"

for arch in arm64 x86_64; do
  swift build \
    --package-path "$PROJECT_ROOT" \
    --scratch-path "$PROJECT_ROOT/.build-$arch" \
    --configuration release \
    --arch "$arch" \
    -Xswiftc -gnone
done

ARM_BIN=$(swift build --package-path "$PROJECT_ROOT" --scratch-path "$PROJECT_ROOT/.build-arm64" --configuration release --arch arm64 --show-bin-path)
INTEL_BIN=$(swift build --package-path "$PROJECT_ROOT" --scratch-path "$PROJECT_ROOT/.build-x86_64" --configuration release --arch x86_64 --show-bin-path)

rm -rf "$TEMP_APP"
mkdir -p "$TEMP_APP/Contents/MacOS" "$TEMP_APP/Contents/Resources"
cp "$PROJECT_ROOT/Packaging/Info.plist" "$TEMP_APP/Contents/Info.plist"
lipo -create "$ARM_BIN/$EXECUTABLE_NAME" "$INTEL_BIN/$EXECUTABLE_NAME" -output "$TEMP_APP/Contents/MacOS/$EXECUTABLE_NAME"
chmod 755 "$TEMP_APP/Contents/MacOS/$EXECUTABLE_NAME"

RESOURCE_BUNDLES=("$ARM_BIN"/*CustomerReplyBatchAppSupport.bundle(N))
if (( ${#RESOURCE_BUNDLES} != 1 )); then
  print -u2 "未找到唯一的 AppSupport 资源包"
  exit 1
fi
ditto "$RESOURCE_BUNDLES[1]" "$TEMP_APP/Contents/Resources/${RESOURCE_BUNDLES[1]:t}"

codesign --force --deep --sign - "$TEMP_APP"
rm -rf "$APP_PATH"
mv "$TEMP_APP" "$APP_PATH"

plutil -lint "$APP_PATH/Contents/Info.plist"
lipo -archs "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
