#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
OUTPUT_DIR="${AUTOREPLY_OUTPUT_DIR:-$PROJECT_ROOT/build-output}"
DMG="$OUTPUT_DIR/千牛全自动客服-版本B.dmg"
README_SOURCE="$PROJECT_ROOT/Packaging/首次安装说明.txt"

AUTOREPLY_OUTPUT_DIR="$OUTPUT_DIR" "$PROJECT_ROOT/scripts/build-installer-app.sh"
[[ -s "$README_SOURCE" ]] || { print -u2 -- "缺少首次安装说明：$README_SOURCE"; exit 1; }

stage=$(mktemp -d "${TMPDIR%/}/qianniu-dmg-stage.XXXXXX")
mount_root=$(mktemp -d "${TMPDIR%/}/qianniu-dmg-verify.XXXXXX")
cleanup() {
  hdiutil detach "$mount_root" -quiet 2>/dev/null || true
  rm -rf -- "$stage" "$mount_root"
}
trap cleanup EXIT
ditto "$OUTPUT_DIR/安装并启动.app" "$stage/安装并启动.app"
cp "$README_SOURCE" "$stage/首次安装说明.txt"
rm -f -- "$DMG"
hdiutil create -volname "千牛全自动客服-版本B" -srcfolder "$stage" \
  -ov -format UDZO "$DMG"

hdiutil attach "$DMG" -readonly -nobrowse -mountpoint "$mount_root" -quiet
codesign --verify --deep --strict "$mount_root/安装并启动.app"
codesign --verify --deep --strict \
  "$mount_root/安装并启动.app/Contents/Resources/千牛全自动客服-版本B.app"
hdiutil detach "$mount_root" -quiet
if [[ "${AUTOREPLY_SIGNING_IDENTITY:--}" == "-" ]]; then
  print -- "NOTARIZATION=not_requested_adhoc"
else
  codesign --force --timestamp --sign "$AUTOREPLY_SIGNING_IDENTITY" "$DMG"
  if [[ -n "${AUTOREPLY_NOTARY_PROFILE:-}" ]]; then
    "$PROJECT_ROOT/scripts/notarize-distribution.sh" "$DMG"
  else
    print -- "NOTARIZATION=not_requested_no_profile"
  fi
fi
print -- "DMG_PATH=$DMG"
