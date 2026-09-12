#!/bin/zsh
set -euo pipefail

SOURCE_ROOT="${0:A:h}"
PROJECT_ROOT="${SOURCE_ROOT:h:h}"
STABLE_ROOT="${QIANNIU_MAINTENANCE_HOME:-$HOME/Library/Application Support/QianniuAutoReplyTaskIsolationCandidate/Maintenance}"
PARENT="${STABLE_ROOT:h}"
mkdir -p "$PARENT"

resolve_source() {
  local name="$1"
  if [[ -s "$SOURCE_ROOT/$name" ]]; then
    print -- "$SOURCE_ROOT/$name"
  elif [[ -s "$PROJECT_ROOT/scripts/maintenance/$name" ]]; then
    print -- "$PROJECT_ROOT/scripts/maintenance/$name"
  else
    print -u2 -- "缺少维护文件：$name"
    return 1
  fi
}

temporary=$(mktemp -d "$PARENT/.Maintenance.install.XXXXXX")
cleanup() { [[ -d "$temporary" ]] && rm -rf -- "$temporary"; }
trap cleanup EXIT

cp "$SOURCE_ROOT/检查并安全清理.command" "$temporary/检查并安全清理.command"
cp "$(resolve_source qianniu_safe_cleanup.py)" "$temporary/qianniu_safe_cleanup.py"
cp "$(resolve_source qianniu_diagnostic_export.py)" "$temporary/qianniu_diagnostic_export.py"
cp "$SOURCE_ROOT/自动清理规则.md" "$temporary/自动清理规则.md"
chmod 755 "$temporary/检查并安全清理.command" "$temporary/qianniu_safe_cleanup.py" "$temporary/qianniu_diagnostic_export.py"
(
  cd "$temporary"
  /usr/bin/shasum -a 256 检查并安全清理.command qianniu_safe_cleanup.py qianniu_diagnostic_export.py 自动清理规则.md > manifest.sha256
  /usr/bin/shasum -a 256 -c manifest.sha256 >/dev/null
)

if [[ -e "$STABLE_ROOT" ]]; then
  backup="$PARENT/Maintenance.backup-$(date '+%Y%m%d-%H%M%S')"
  mv "$STABLE_ROOT" "$backup"
fi
mv "$temporary" "$STABLE_ROOT"
trap - EXIT
print -- "自动维护工具已安装：$STABLE_ROOT"
