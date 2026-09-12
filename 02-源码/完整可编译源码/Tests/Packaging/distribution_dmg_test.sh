#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h:h}"
DMG="${AUTOREPLY_DMG_PATH:-$ROOT/build-output/千牛全自动客服-版本B.dmg}"
[[ -s "$DMG" ]] || { print -u2 -- "missing DMG: $DMG"; exit 1; }

mount_root=$(mktemp -d "${TMPDIR%/}/qianniu-dmg-test.XXXXXX")
cleanup() {
  hdiutil detach "$mount_root" -quiet 2>/dev/null || true
  rmdir "$mount_root" 2>/dev/null || true
}
trap cleanup EXIT

hdiutil attach "$DMG" -readonly -nobrowse -mountpoint "$mount_root" -quiet
installer="$mount_root/安装并启动.app"
payload="$installer/Contents/Resources/千牛全自动客服-版本B.app"
[[ -d "$installer" ]] || { print -u2 -- "installer missing from DMG"; exit 1; }
[[ -d "$payload" ]] || { print -u2 -- "embedded payload missing from installer"; exit 1; }
[[ -s "$mount_root/首次安装说明.txt" ]] || { print -u2 -- "readme missing from DMG"; exit 1; }
[[ $(find "$mount_root" -mindepth 1 -maxdepth 1 ! -name '.Trashes' ! -name '.fseventsd' ! -name '.DS_Store' | wc -l | tr -d ' ') == 2 ]] \
  || { print -u2 -- "DMG must expose only installer and readme"; exit 1; }
codesign --verify --deep --strict "$payload"
codesign --verify --deep --strict "$installer"
print -- "DMG_CONTRACT_OK=1"
