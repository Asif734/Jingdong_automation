#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h:h}"
FROZEN_INFO="$PROJECT_ROOT/../../outputs/千牛主聊天区OCR-PlanB-无图片检测冻结版.app/Contents/Info.plist"
CURRENT_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PROJECT_ROOT/Packaging/Info.plist")
FROZEN_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$FROZEN_INFO")
CURRENT_NAME=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$PROJECT_ROOT/Packaging/Info.plist")
FROZEN_NAME=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$FROZEN_INFO")

if [[ "$CURRENT_ID" == "$FROZEN_ID" ]]; then
  print -u2 "最新版与冻结版 Bundle ID 冲突：$CURRENT_ID"
  exit 1
fi

[[ "$CURRENT_ID" == "com.local.qianniu-main-chat-ocr-plan-b.current" ]]

if [[ "$CURRENT_NAME" == "$FROZEN_NAME" ]]; then
  print -u2 "最新版与冻结版显示名称冲突：$CURRENT_NAME"
  exit 1
fi

[[ "$CURRENT_NAME" == "千牛主聊天区OCR-PlanB-最新版" ]]
