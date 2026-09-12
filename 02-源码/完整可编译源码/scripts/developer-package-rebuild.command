#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
DEFAULT_PACKAGE_ROOT="${SCRIPT_DIR:h}"
PACKAGE_ROOT="${QIANNIU_DEVELOPER_PACKAGE_ROOT:-$DEFAULT_PACKAGE_ROOT}"
SOURCE_ROOT="$PACKAGE_ROOT/02-完整源码"
APP_ROOT="$PACKAGE_ROOT/01-可运行应用/千牛全自动客服-任务隔离候选版.app"
APP_RESOURCES="$APP_ROOT/Contents/Resources"
V2_RUNTIME="$PACKAGE_ROOT/03-构建资源/V2Runtime"
PYTHON_FRAMEWORK="$PACKAGE_ROOT/03-构建资源/Python.framework"
KNOWLEDGE_BASE="$PACKAGE_ROOT/03-构建资源/Grozziie-China-KB.zip"
OUTPUT_DIR="$PACKAGE_ROOT/05-重新构建输出"

fail() { print -u2 -- "$*"; exit 1; }

[[ -s "$SOURCE_ROOT/Package.swift" ]] || fail "完整源码缺失：$SOURCE_ROOT"
[[ -x "$SOURCE_ROOT/scripts/build-app.sh" ]] || fail "构建脚本缺失"
[[ -d "$V2_RUNTIME/.venv/lib/python3.12/site-packages/fastembed" ]] \
  || fail "V2 Python 依赖缺失"
[[ -d "$V2_RUNTIME/cache/models" ]] || fail "V2 本地模型缺失"
[[ -x "$PYTHON_FRAMEWORK/Versions/3.12/bin/python3.12" ]] \
  || fail "Python.framework 缺失"
[[ -s "$KNOWLEDGE_BASE" ]] || fail "知识库 ZIP 缺失"

identity="-"
if command -v security >/dev/null 2>&1; then
  certificate_hash=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '/Apple Development:/ { print $2; exit }')
  if [[ -n "$certificate_hash" ]]; then
    identity="$certificate_hash"
  fi
fi

if [[ "$identity" == "-" ]]; then
  print -- "SIGNING_MODE=adhoc"
else
  print -- "SIGNING_MODE=certificate"
fi
print -- "PACKAGE_ROOT=$PACKAGE_ROOT"
print -- "SOURCE_ROOT=$SOURCE_ROOT"
print -- "KNOWLEDGE_BASE=$KNOWLEDGE_BASE"

if [[ "${1:-}" == "--preflight-only" ]]; then
  print -- "PREFLIGHT_OK=1"
  exit 0
fi

cd "$SOURCE_ROOT"
swift test
PYTHONDONTWRITEBYTECODE=1 python3 Tests/BaselineScriptsTests/freeze_per_user_session_baseline_test.py
PYTHONDONTWRITEBYTECODE=1 python3 Tests/Packaging/verify_baseline_test.py

mkdir -p "$OUTPUT_DIR"
AUTOREPLY_OUTPUT_DIR="$OUTPUT_DIR" \
AUTOREPLY_V2_RUNTIME_SOURCE="$V2_RUNTIME" \
AUTOREPLY_PYTHON_FRAMEWORK_SOURCE="$PYTHON_FRAMEWORK" \
AUTOREPLY_KNOWLEDGE_BASE_SOURCE="$KNOWLEDGE_BASE" \
AUTOREPLY_SIGNING_IDENTITY="$identity" \
  "$SOURCE_ROOT/scripts/build-app.sh"
