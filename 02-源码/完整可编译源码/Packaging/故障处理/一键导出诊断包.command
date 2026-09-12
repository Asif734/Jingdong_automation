#!/bin/zsh
set -euo pipefail

SCRIPT_ROOT="${0:A:h}"
maintenance="$HOME/Library/Application Support/QianniuAutoReplyTaskIsolationCandidate/Maintenance"
if [[ ! -s "$maintenance/qianniu_diagnostic_export.py" ]]; then
  installer=""
  for candidate in "$SCRIPT_ROOT/../04-自动维护/安装自动清理.command" "$SCRIPT_ROOT/../自动维护/安装自动清理.command"; do
    if [[ -x "$candidate" ]]; then installer="$candidate"; break; fi
  done
  [[ -n "$installer" ]] || { print -u2 -- "找不到自动维护安装器，请把整个交付文件夹交给 Codex。"; exit 1; }
  "$installer"
fi

cd "$maintenance"
/usr/bin/shasum -a 256 -c manifest.sha256 >/dev/null
runtime_root="$HOME/Library/Application Support/QianniuAutoReplyTaskIsolationCandidate/AI客服记录-任务隔离候选版"
bundled_python="/Applications/千牛全自动客服-版本B.app/Contents/Resources/Python.framework/Versions/3.12/bin/python3.12"
if [[ -x "$bundled_python" ]]; then python="$bundled_python"; else python=/usr/bin/python3; fi
exec "$python" "$maintenance/qianniu_diagnostic_export.py" --runtime-root "$runtime_root" --desktop "$HOME/Desktop"
