#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
DMG_PATH=""
OUTPUT_DIR=""

usage() {
  print -- "用法: $0 --dmg /绝对路径/千牛全自动客服-版本B.dmg --output /绝对输出目录"
}

while (( $# > 0 )); do
  case "$1" in
    --dmg) (( $# >= 2 )) || { usage; exit 2; }; DMG_PATH="$2"; shift 2 ;;
    --output) (( $# >= 2 )) || { usage; exit 2; }; OUTPUT_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) print -u2 -- "未知参数：$1"; usage; exit 2 ;;
  esac
done

[[ "$DMG_PATH" == /* ]] || { print -u2 -- "--dmg 必须是绝对路径"; exit 2; }
[[ "$OUTPUT_DIR" == /* ]] || { print -u2 -- "--output 必须是绝对路径"; exit 2; }
[[ -s "$DMG_PATH" ]] || { print -u2 -- "DMG 不存在或为空：$DMG_PATH"; exit 1; }

HANDOFF_GUIDE="$PROJECT_ROOT/docs/把这个文件交给Codex-项目完整接管与Debug手册.md"
COLLEAGUE_GUIDE="$PROJECT_ROOT/docs/千牛全自动客服-版本B-首次安装与维护指南.pdf"
ENGINEER_GUIDE="$PROJECT_ROOT/docs/工程师构建与Debug说明.md"
INSTALL_GUIDE="$PROJECT_ROOT/Packaging/首次安装说明.txt"
MAINTENANCE_ROOT="$PROJECT_ROOT/Packaging/自动维护"
DIAGNOSTIC_ROOT="$PROJECT_ROOT/Packaging/故障处理"
for required in "$HANDOFF_GUIDE" "$COLLEAGUE_GUIDE" "$ENGINEER_GUIDE" "$INSTALL_GUIDE" \
  "$MAINTENANCE_ROOT/安装自动清理.command" "$MAINTENANCE_ROOT/检查并安全清理.command" \
  "$MAINTENANCE_ROOT/自动清理规则.md" "$DIAGNOSTIC_ROOT/一键导出诊断包.command" \
  "$PROJECT_ROOT/scripts/maintenance/qianniu_safe_cleanup.py" \
  "$PROJECT_ROOT/scripts/maintenance/qianniu_diagnostic_export.py"; do
  [[ -s "$required" ]] || { print -u2 -- "缺少交付文件：$required"; exit 1; }
done

git -C "$PROJECT_ROOT" rev-parse --is-inside-work-tree >/dev/null
if [[ "${AUTOREPLY_HANDOFF_ALLOW_DIRTY_FOR_TESTS:-0}" != "1" ]]; then
  git -C "$PROJECT_ROOT" diff --quiet
  git -C "$PROJECT_ROOT" diff --cached --quiet
fi

forbidden_history_paths=$(git -C "$PROJECT_ROOT" rev-list --objects --all \
  | cut -d' ' -f2- \
  | grep -E '(^|/)(auth\.json|history\.jsonl|processed-events\.json)$|(^|/)(CodexHome|conversations|图片指纹)(/|$)|Application Support' \
  || true)
[[ -z "$forbidden_history_paths" ]] || {
  print -u2 -- "Git 历史中发现禁止交付的运行数据路径："
  print -u2 -- "$forbidden_history_paths"
  exit 1
}

mkdir -p "$OUTPUT_DIR"
timestamp=$(date '+%Y%m%d-%H%M%S')
package_name="千牛全自动客服-版本B-完整交付包-$timestamp"
package_root="$OUTPUT_DIR/$package_name"
zip_path="$OUTPUT_DIR/$package_name.zip"
[[ ! -e "$package_root" && ! -e "$zip_path" ]] || { print -u2 -- "输出目标已存在"; exit 1; }

mkdir -p \
  "$package_root/00-先看这里" \
  "$package_root/01-安装" \
  "$package_root/02-源码/完整可编译源码" \
  "$package_root/03-Git完整历史" \
  "$package_root/04-自动维护" \
  "$package_root/05-故障处理" \
  "$package_root/06-校验"

cp "$HANDOFF_GUIDE" "$package_root/00-先看这里/把这个文件交给Codex-安装配置维护与Debug手册.md"
cp "$COLLEAGUE_GUIDE" "$package_root/00-先看这里/千牛全自动客服-版本B-首次安装与维护指南.pdf"
cp "$INSTALL_GUIDE" "$package_root/01-安装/首次安装说明.txt"
cp "$DMG_PATH" "$package_root/01-安装/${DMG_PATH:t}"
cp "$ENGINEER_GUIDE" "$package_root/02-源码/工程师构建与Debug说明.md"
cp "$MAINTENANCE_ROOT/安装自动清理.command" "$package_root/04-自动维护/安装自动清理.command"
cp "$MAINTENANCE_ROOT/检查并安全清理.command" "$package_root/04-自动维护/检查并安全清理.command"
cp "$MAINTENANCE_ROOT/自动清理规则.md" "$package_root/04-自动维护/自动清理规则.md"
cp "$PROJECT_ROOT/scripts/maintenance/qianniu_safe_cleanup.py" "$package_root/04-自动维护/qianniu_safe_cleanup.py"
cp "$PROJECT_ROOT/scripts/maintenance/qianniu_diagnostic_export.py" "$package_root/04-自动维护/qianniu_diagnostic_export.py"
cp "$DIAGNOSTIC_ROOT/一键导出诊断包.command" "$package_root/05-故障处理/一键导出诊断包.command"
chmod 755 "$package_root/04-自动维护"/*.command "$package_root/04-自动维护"/*.py \
  "$package_root/05-故障处理"/*.command

commit=$(git -C "$PROJECT_ROOT" rev-parse HEAD)
branch=$(git -C "$PROJECT_ROOT" branch --show-current)
snapshot_path="$package_root/02-源码/源码快照.zip"
bundle_path="$package_root/03-Git完整历史/千牛全自动客服.bundle"
git -C "$PROJECT_ROOT" archive --format=zip --output="$snapshot_path" HEAD
git -C "$PROJECT_ROOT" archive HEAD | tar -x -C "$package_root/02-源码/完整可编译源码"
git -C "$PROJECT_ROOT" bundle create "$bundle_path" --all
git -C "$PROJECT_ROOT" bundle verify "$bundle_path" >/dev/null

verification_root=$(mktemp -d "${TMPDIR%/}/qianniu-handoff-verify.XXXXXX")
cleanup() { [[ -d "$verification_root" ]] && rm -rf -- "$verification_root"; }
trap cleanup EXIT
git clone --quiet "$bundle_path" "$verification_root/clone"
cloned_commit=$(git -C "$verification_root/clone" rev-parse HEAD)
[[ "$cloned_commit" == "$commit" ]] || { print -u2 -- "Git bundle 克隆校验失败"; exit 1; }

python3 - "$package_root" "$commit" "$branch" "${DMG_PATH:t}" <<'PY'
import hashlib, json, pathlib, sys
from datetime import datetime, timezone

root = pathlib.Path(sys.argv[1])
dmg = root / "01-安装" / sys.argv[4]
manifest = {
    "schemaVersion": 2,
    "createdAt": datetime.now(timezone.utc).isoformat(),
    "product": "千牛全自动客服-版本B",
    "bundleIdentifier": "com.scy.qianniu-autoreply.version-b",
    "architecture": "arm64",
    "gitCommit": sys.argv[2],
    "gitBranch": sys.argv[3],
    "gitBundleVerified": True,
    "gitCloneVerified": True,
    "sourceSnapshot": "02-源码/源码快照.zip",
    "editableSource": "02-源码/完整可编译源码",
    "gitBundle": "03-Git完整历史/千牛全自动客服.bundle",
    "distribution": {"file": dmg.name, "sha256": hashlib.sha256(dmg.read_bytes()).hexdigest()},
    "maintenance": {"retentionDays": 30, "highWatermarkGiB": 10, "targetGiB": 8},
    "privacy": {
        "customerRuntimeDataIncluded": False,
        "codexCredentialsIncluded": False,
        "developerBuildCachesIncluded": False,
    },
}
(root / "06-校验" / "manifest.json").write_text(
    json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
)
PY

python3 - "$package_root" <<'PY'
import hashlib, pathlib, sys
root = pathlib.Path(sys.argv[1])
output = root / "06-校验" / "SHA256SUMS.txt"
lines = []
for path in sorted(root.rglob("*")):
    if path.is_file() and path != output:
        lines.append(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.relative_to(root).as_posix()}")
output.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY

python3 - "$package_root" "$zip_path" <<'PY'
import pathlib, sys, zipfile
root, output = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
    for path in sorted(root.rglob("*")):
        if path.is_file():
            archive.write(path, (pathlib.Path(root.name) / path.relative_to(root)).as_posix())
PY
[[ -s "$zip_path" ]] || { print -u2 -- "最终 ZIP 生成失败"; exit 1; }

print -- "HANDOFF_DIR=$package_root"
print -- "HANDOFF_ZIP=$zip_path"
print -- "GIT_COMMIT=$commit"
print -- "GIT_BUNDLE_VERIFIED=1"
print -- "GIT_CLONE_VERIFIED=1"
