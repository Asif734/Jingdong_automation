#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h:h}"
TEMP=$(mktemp -d)
MOUNT="$TEMP/mount"
cleanup() {
  hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
  rm -rf -- "$TEMP"
}
trap cleanup EXIT

mkdir -p "$TEMP/output/格志客服模型测试器.app" "$MOUNT"
print 'fixture' > "$TEMP/output/格志客服模型测试器.app/fixture.txt"

MODEL_TESTER_OUTPUT_DIR="$TEMP/output" "$ROOT/scripts/build-dmg.sh" >/dev/null
hdiutil attach "$TEMP/output/格志客服模型测试器.dmg" \
  -mountpoint "$MOUNT" -nobrowse -readonly -quiet

test -d "$MOUNT/格志客服模型测试器.app"
test -L "$MOUNT/应用程序"
test -s "$MOUNT/使用说明.txt"
grep -q 'codex login' "$MOUNT/使用说明.txt"
grep -q '拖入图片' "$MOUNT/使用说明.txt"
