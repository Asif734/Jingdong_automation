#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
assert_stopped() {
  if pgrep -x UnreadApp >/dev/null; then
    echo 'UnreadApp is running; quit it before building. No app files replaced.' >&2
    exit 1
  fi
}
assert_stopped
SIGN_IDENTITY='Apple Development: Chu Ye Shi (6Q9HFP6LJJ)'
if ! security find-identity -v -p codesigning | /usr/bin/grep -Fq "$SIGN_IDENTITY"; then
  echo "Missing signing identity: $SIGN_IDENTITY" >&2
  exit 1
fi
swift test --package-path "$PROJECT_DIR"
swift build --package-path "$PROJECT_DIR" -c release
BIN_DIR="$(swift build --package-path "$PROJECT_DIR" -c release --show-bin-path)"
OUTPUT_DIR="$PROJECT_DIR/output"
APP="$OUTPUT_DIR/千牛未读助手.app"
if [[ -e "$APP" ]]; then
  EXISTING_ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || true)
  if [[ "$EXISTING_ID" != 'com.local.qianniu-unread-assistant' ]]; then
    echo "Refusing to overwrite unrelated existing bundle: $APP" >&2
    exit 1
  fi
fi
mkdir -p "$APP/Contents/MacOS"
assert_stopped
cp "$BIN_DIR/UnreadApp" "$APP/Contents/MacOS/UnreadApp"
cp "$PROJECT_DIR/Packaging/Info.plist" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"
codesign --force --sign "$SIGN_IDENTITY" --options runtime "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
du -sh "$APP"
echo "$APP"
