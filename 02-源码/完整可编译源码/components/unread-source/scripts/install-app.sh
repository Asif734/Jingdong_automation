#!/bin/bash
# Install only a fully built/signed bundle. Never overwrite a live Mach-O file.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_APP="$PROJECT_DIR/output/千牛未读助手.app"
TARGET_APP='/Applications/千牛未读助手.app'
EXPECTED_ID='com.local.qianniu-unread-assistant'

assert_stopped() {
  if pgrep -x UnreadApp >/dev/null; then
    echo 'UnreadApp is still running; quit and wait for complete process exit. Nothing installed.' >&2
    exit 1
  fi
}
check_bundle() {
  local actual_id
  actual_id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$1/Contents/Info.plist")
  [[ "$actual_id" == "$EXPECTED_ID" ]] || { echo 'Unexpected bundle ID; refusing replacement.' >&2; exit 1; }
  codesign --verify --deep --strict "$1"
}

assert_stopped
check_bundle "$SOURCE_APP"
if [[ -e "$TARGET_APP" ]]; then check_bundle "$TARGET_APP"; fi
STAGING_DIR=$(mktemp -d '/Applications/.qianniu-unread-stage.XXXXXX')
STAGED_APP="$STAGING_DIR/千牛未读助手.app"
ditto "$SOURCE_APP" "$STAGED_APP"
check_bundle "$STAGED_APP"
assert_stopped
mkdir -p "$PROJECT_DIR/installation-backups"
BACKUP_DIR=$(mktemp -d "$PROJECT_DIR/installation-backups/install.XXXXXX")
if [[ -e "$TARGET_APP" ]]; then mv "$TARGET_APP" "$BACKUP_DIR/千牛未读助手.app"; fi
if ! mv "$STAGED_APP" "$TARGET_APP"; then
  if [[ -e "$BACKUP_DIR/千牛未读助手.app" && ! -e "$TARGET_APP" ]]; then
    mv "$BACKUP_DIR/千牛未读助手.app" "$TARGET_APP"
  fi
  echo 'Install failed; previous bundle restored where possible.' >&2
  exit 1
fi
rmdir "$STAGING_DIR"
check_bundle "$TARGET_APP"
echo "Installed: $TARGET_APP"
echo "Previous bundle retained: $BACKUP_DIR"
