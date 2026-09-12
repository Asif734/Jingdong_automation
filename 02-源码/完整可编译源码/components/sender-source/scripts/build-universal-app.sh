#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
OUTPUT_DIR="${QIANNIU_SENDER_OUTPUT_DIR:-${PROJECT_ROOT:h}/output}"
APP_PATH="$OUTPUT_DIR/千牛自动发送-稳定签名版.app"
EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/千牛自动发送"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Apple Development: Chu Ye Shi (6Q9HFP6LJJ)}"

mkdir -p "$OUTPUT_DIR"
for architecture in arm64 x86_64; do
  swift build \
    --package-path "$PROJECT_ROOT" \
    --scratch-path "$PROJECT_ROOT/.build-status-fix-$architecture" \
    --configuration release \
    --arch "$architecture" \
    -Xswiftc -gnone
done

ARM_DIR=$(swift build --package-path "$PROJECT_ROOT" --scratch-path "$PROJECT_ROOT/.build-status-fix-arm64" --configuration release --arch arm64 -Xswiftc -gnone --show-bin-path)
INTEL_DIR=$(swift build --package-path "$PROJECT_ROOT" --scratch-path "$PROJECT_ROOT/.build-status-fix-x86_64" --configuration release --arch x86_64 -Xswiftc -gnone --show-bin-path)

rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$PROJECT_ROOT/Packaging/Info.plist" "$APP_PATH/Contents/Info.plist"
lipo -create "$ARM_DIR/QianniuAutoSender" "$INTEL_DIR/QianniuAutoSender" -output "$EXECUTABLE_PATH"
chmod 755 "$EXECUTABLE_PATH"
codesign --force --deep --options runtime --timestamp=none --sign "$SIGNING_IDENTITY" "$APP_PATH"
plutil -lint "$APP_PATH/Contents/Info.plist"
lipo -archs "$EXECUTABLE_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
