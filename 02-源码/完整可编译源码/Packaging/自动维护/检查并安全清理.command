#!/bin/zsh
set -euo pipefail

TOOL_ROOT="${0:A:h}"
cd "$TOOL_ROOT"
/usr/bin/shasum -a 256 -c manifest.sha256 >/dev/null

runtime_root="$HOME/Library/Application Support/QianniuAutoReplyTaskIsolationCandidate/AI客服记录-任务隔离候选版"
bundled_python="/Applications/千牛全自动客服-版本B.app/Contents/Resources/Python.framework/Versions/3.12/bin/python3.12"
if [[ -x "$bundled_python" ]]; then
  python="$bundled_python"
elif [[ -x /usr/bin/python3 ]]; then
  python=/usr/bin/python3
else
  print -u2 -- "没有找到可用的 Python。请把整个交付文件夹交给 Codex 修复。"
  exit 1
fi

exec "$python" "$TOOL_ROOT/qianniu_safe_cleanup.py" --runtime-root "$runtime_root" "$@"
