#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h:h}"
INFO_PLIST="$PROJECT_ROOT/Packaging/Info.plist"
ICON_FILE="$PROJECT_ROOT/Packaging/AppIcon.icns"
BUILD_SCRIPT="$PROJECT_ROOT/scripts/build-app.sh"

[[ "$('/usr/libexec/PlistBuddy' -c 'Print :CFBundleIconFile' "$INFO_PLIST")" == "AppIcon" ]]
[[ -s "$ICON_FILE" ]]
grep -Fq 'Packaging/AppIcon.icns' "$BUILD_SCRIPT"
grep -Fq 'Contents/Resources/AppIcon.icns' "$BUILD_SCRIPT"
