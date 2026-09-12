#!/bin/zsh
set -euo pipefail

[[ $# -eq 5 ]] || { print -u2 'usage: prepare-resources.sh DEST KB_ZIP V2_ROOT PYTHON_FRAMEWORK EXPECTED_SHA256'; exit 2; }
DEST="$1"
KB_ZIP="$2"
V2_ROOT="$3"
PYTHON_FRAMEWORK="$4"
EXPECTED_HASH="$5"

fail() { print -u2 -- "$*"; exit 1; }
[[ -s "$KB_ZIP" ]] || fail "知识库不存在：$KB_ZIP"
[[ -s "$V2_ROOT/retrieve_top12.py" ]] || fail "缺少V2检索脚本"
[[ -d "$V2_ROOT/site-packages" ]] || fail "缺少V2 Python依赖"
[[ -d "$V2_ROOT/cache" ]] || fail "缺少V2模型缓存"
[[ -x "$PYTHON_FRAMEWORK/Versions/3.12/bin/python3.12" ]] || fail "缺少Python 3.12运行时"

ACTUAL_HASH=$(shasum -a 256 "$KB_ZIP" | awk '{print $1}')
[[ "$ACTUAL_HASH" == "$EXPECTED_HASH" ]] || fail "知识库SHA-256不匹配"

mkdir -p "$DEST/KnowledgeBase" "$DEST/V2Knowledge" "$DEST/Python.framework"
ditto "$KB_ZIP" "$DEST/KnowledgeBase/Grozziie-China-KB.zip"
ditto "$V2_ROOT" "$DEST/V2Knowledge"

# Bundle a portable Python runtime but omit development/test payload and the
# global site-packages; the curated V2 dependencies are copied separately above.
rsync -a \
  --exclude '/Versions/3.12/lib/python3.12/site-packages' \
  --exclude '/Versions/3.12/lib/python3.12/test' \
  --exclude '/Versions/3.12/lib/python3.12/idlelib' \
  --exclude '/Versions/3.12/lib/python3.12/tkinter' \
  --exclude '/Versions/3.12/lib/python3.12/turtledemo' \
  --exclude '/Versions/3.12/lib/python3.12/ensurepip' \
  "$PYTHON_FRAMEWORK/" "$DEST/Python.framework/"

PYTHON_BIN="$DEST/Python.framework/Versions/3.12/bin/python3.12"
chmod 755 "$PYTHON_BIN"
if file "$PYTHON_BIN" | grep -q 'Mach-O'; then
  install_name_tool -change \
    /Library/Frameworks/Python.framework/Versions/3.12/Python \
    @executable_path/../Python \
    "$PYTHON_BIN"
  PYTHON_APP="$DEST/Python.framework/Versions/3.12/Resources/Python.app/Contents/MacOS/Python"
  if [[ -f "$PYTHON_APP" ]]; then
    install_name_tool -change \
      /Library/Frameworks/Python.framework/Versions/3.12/Python \
      @loader_path/../../../../Python \
      "$PYTHON_APP"
  fi
fi

print -r -- "{\n  \"app_version\": \"1.0.0-test\",\n  \"knowledge_base_sha256\": \"$ACTUAL_HASH\",\n  \"model\": \"gpt-5.6-sol\",\n  \"reasoning_effort\": \"medium\",\n  \"retriever\": \"v2-top12\"\n}" > "$DEST/model-tester-manifest.json"
