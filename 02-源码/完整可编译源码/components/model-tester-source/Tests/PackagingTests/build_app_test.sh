#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h:h}"
TEMP=$(mktemp -d)
trap 'rm -rf -- "$TEMP"' EXIT
mkdir -p "$TEMP/v2/site-packages/fastembed" "$TEMP/v2/cache/models" \
         "$TEMP/python/Versions/3.12/bin" "$TEMP/python/Versions/3.12/lib/python3.12"
print 'print("fixture")' > "$TEMP/v2/retrieve_top12.py"
print 'fixture knowledge' > "$TEMP/kb.zip"
print '#!/bin/zsh' > "$TEMP/python/Versions/3.12/bin/python3.12"
chmod 755 "$TEMP/python/Versions/3.12/bin/python3.12"

MODEL_TESTER_OUTPUT_DIR="$TEMP/output" \
MODEL_TESTER_KB_PATH="$TEMP/kb.zip" \
MODEL_TESTER_V2_ROOT="$TEMP/v2" \
MODEL_TESTER_PYTHON_FRAMEWORK="$TEMP/python" \
MODEL_TESTER_SIGNING_IDENTITY='-' \
  "$ROOT/scripts/build-app.sh"

APP="$TEMP/output/格志客服模型测试器.app"
test -x "$APP/Contents/MacOS/GrozziieModelTesterApp"
test -s "$APP/Contents/Resources/KnowledgeBase/Grozziie-China-KB.zip"
test -s "$APP/Contents/Resources/model-tester-manifest.json"
test ! -e "$APP/Contents/Resources/WebOCR"
test ! -e "$APP/Contents/Resources/auth.json"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")" = '14.0'
lipo -archs "$APP/Contents/MacOS/GrozziieModelTesterApp" | grep -qx arm64
codesign --verify --deep --strict "$APP"
