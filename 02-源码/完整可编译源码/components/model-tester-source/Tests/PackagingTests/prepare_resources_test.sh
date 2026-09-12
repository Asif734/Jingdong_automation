#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h:h}"
TEMP=$(mktemp -d)
trap 'rm -rf -- "$TEMP"' EXIT
mkdir -p "$TEMP/v2/site-packages/fastembed" "$TEMP/v2/cache/models" \
         "$TEMP/python/Versions/3.12/bin" "$TEMP/python/Versions/3.12/lib/python3.12"
print 'print("ok")' > "$TEMP/v2/retrieve_top12.py"
print 'kb' > "$TEMP/kb.zip"
print 'python' > "$TEMP/python/Versions/3.12/bin/python3.12"
chmod 755 "$TEMP/python/Versions/3.12/bin/python3.12"
HASH=$(shasum -a 256 "$TEMP/kb.zip" | awk '{print $1}')

"$ROOT/scripts/prepare-resources.sh" \
  "$TEMP/output" "$TEMP/kb.zip" "$TEMP/v2" "$TEMP/python" "$HASH"

test -s "$TEMP/output/KnowledgeBase/Grozziie-China-KB.zip"
test -s "$TEMP/output/V2Knowledge/retrieve_top12.py"
test -x "$TEMP/output/Python.framework/Versions/3.12/bin/python3.12"
grep -q "$HASH" "$TEMP/output/model-tester-manifest.json"

if "$ROOT/scripts/prepare-resources.sh" \
  "$TEMP/bad" "$TEMP/kb.zip" "$TEMP/v2" "$TEMP/python" "wrong" >/dev/null 2>&1; then
  print -u2 'wrong hash unexpectedly succeeded'
  exit 1
fi
