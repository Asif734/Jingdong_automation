#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
REPO_ROOT="$(cd "$PROJECT_ROOT/../.." && pwd -P)"
OUTPUT_DIR="${MODEL_TESTER_OUTPUT_DIR:-$REPO_ROOT/output/model-tester}"
APP="$OUTPUT_DIR/格志客服模型测试器.app"
DMG="$OUTPUT_DIR/格志客服模型测试器.dmg"
[[ -d "$APP" ]] || { print -u2 '请先运行 build-app.sh'; exit 1; }
STAGING=$(mktemp -d "$OUTPUT_DIR/.model-tester-dmg.XXXXXX")
trap 'rm -rf -- "$STAGING"' EXIT
ditto "$APP" "$STAGING/格志客服模型测试器.app"
ditto "$PROJECT_ROOT/Packaging/使用说明.txt" "$STAGING/使用说明.txt"
ln -s /Applications "$STAGING/应用程序"
rm -f -- "$DMG"
hdiutil create -volname '格志客服模型测试器' -srcfolder "$STAGING" \
  -ov -format UDZO "$DMG" >/dev/null
print -- "DMG_PATH=$DMG"
