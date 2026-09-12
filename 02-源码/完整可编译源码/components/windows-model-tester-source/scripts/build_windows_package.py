from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""): digest.update(chunk)
    return digest.hexdigest()


def write_manifest(root: Path, knowledge_zip: Path) -> Path:
    value = {
        "app_version": "1.0.0-windows-test",
        "knowledge_base_sha256": sha256(knowledge_zip),
        "model": "gpt-5.6-sol",
        "reasoning_effort": "medium",
        "retriever": "v2-top12",
        "python": "3.12-x64-embeddable",
    }
    path = Path(root) / "manifest.json"; path.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8"); return path


def audit_tree(root: Path) -> list[str]:
    findings = []
    for path in Path(root).rglob("*"):
        lowered = path.name.lower()
        if lowered.endswith(".app") or lowered in {"auth.json"} or ".codex" in path.parts:
            findings.append(str(path))
        if path.is_file():
            header = path.read_bytes()[:4]
            if header in {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe"}: findings.append(str(path) + ":Mach-O")
            if path.suffix == ".so": findings.append(str(path) + ":shared-object")
    return findings


def assemble_package(destination: Path, source_root: Path, launcher: Path, python_root: Path, knowledge_zip: Path, v2_root: Path) -> Path:
    destination = Path(destination)
    if destination.exists(): shutil.rmtree(destination)
    destination.mkdir(parents=True)
    shutil.copy2(launcher, destination / "格志客服模型测试器.exe")
    shutil.copytree(python_root, destination / "runtime")
    for pth in (destination / "runtime").glob("python*._pth"):
        lines = pth.read_text(encoding="utf-8").splitlines()
        if ".." not in lines:
            lines.insert(1, "..")
            pth.write_text("\n".join(lines) + "\n", encoding="utf-8")
    shutil.copytree(source_root / "app", destination / "app", ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    shutil.copytree(source_root / "web", destination / "web")
    shutil.copytree(source_root / "resources", destination / "resources")
    kb_target = destination / "resources" / "KnowledgeBase"; kb_target.mkdir(parents=True)
    shutil.copy2(knowledge_zip, kb_target / "Grozziie-China-KB.zip")
    v2_target = destination / "resources" / "V2Knowledge"
    shutil.copytree(v2_root, v2_target, dirs_exist_ok=True, ignore=shutil.ignore_patterns("site-packages", "__pycache__", "*.pyc"))
    (destination / "data").mkdir()
    write_manifest(destination, kb_target / "Grozziie-China-KB.zip")
    return destination


def _download(url: str, destination: Path) -> Path:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if not destination.exists():
        print(f"下载 {url}", flush=True)
        subprocess.run(["curl", "-fL", url, "-o", str(destination)], check=True)
    return destination


def _prepare_python(cache: Path, requirements: Path) -> Path:
    archive = _download("https://www.python.org/ftp/python/3.12.10/python-3.12.10-embed-amd64.zip", cache / "python-3.12.10-embed-amd64.zip")
    runtime = cache / "python-runtime"
    if runtime.exists(): shutil.rmtree(runtime)
    runtime.mkdir(); zipfile.ZipFile(archive).extractall(runtime)
    packages = runtime / "Lib" / "site-packages"; packages.mkdir(parents=True)
    wheels = cache / "wheels"; wheels.mkdir(exist_ok=True)
    subprocess.run([
        sys.executable, "-m", "pip", "download", "-r", str(requirements), "-d", str(wheels),
        "--only-binary=:all:", "--platform", "win_amd64", "--python-version", "312", "--implementation", "cp", "--abi", "cp312",
    ], check=True)
    for wheel in sorted(wheels.glob("*.whl")): zipfile.ZipFile(wheel).extractall(packages)
    pth = next(runtime.glob("python312._pth")); lines = [line for line in pth.read_text().splitlines() if line.strip() != "#import site"]
    if "Lib/site-packages" not in lines: lines.append("Lib/site-packages")
    if "import site" not in lines: lines.append("import site")
    pth.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return runtime


def _stable_zip(source: Path, output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for path in sorted(source.rglob("*"), key=lambda x: x.as_posix()):
            if not path.is_file(): continue
            info = zipfile.ZipInfo(path.relative_to(source).as_posix(), (2026, 8, 28, 0, 0, 0)); info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, path.read_bytes())


def main() -> None:
    source_root = Path(__file__).resolve().parents[1]
    repo = source_root.parents[1]
    cache = repo / ".toolcache" / "windows-model-tester"
    app_resources = repo / "output" / "model-tester" / "格志客服模型测试器.app" / "Contents" / "Resources"
    knowledge_zip = app_resources / "KnowledgeBase" / "Grozziie-China-KB.zip"
    v2_root = app_resources / "V2Knowledge"
    dotnet = repo / ".toolcache" / "dotnet" / "dotnet"
    if not dotnet.exists(): raise SystemExit("缺少本地 .NET SDK：先运行设计计划中的 dotnet-install 步骤")
    if not knowledge_zip.exists() or not (v2_root / "cache").exists(): raise SystemExit("缺少当前 Mac 测试器的知识库/V2资源")
    launcher_output = cache / "launcher"; launcher_output.mkdir(parents=True, exist_ok=True)
    subprocess.run([str(dotnet), "publish", str(source_root / "launcher" / "GrozziieModelTesterLauncher.csproj"), "-c", "Release", "-r", "win-x64", "--self-contained", "true", "-p:PublishSingleFile=true", "-o", str(launcher_output)], check=True)
    runtime = _prepare_python(cache, source_root / "requirements-windows.lock")
    package_root = repo / "output" / "windows-model-tester" / "格志客服模型测试器-Windows-x64"
    assemble_package(package_root, source_root, launcher_output / "格志客服模型测试器.exe", runtime, knowledge_zip, v2_root)
    shutil.copy2(source_root / "README-Windows.txt", package_root / "使用说明.txt")
    findings = audit_tree(package_root)
    audit = {"findings":findings, "file_count":sum(1 for x in package_root.rglob("*") if x.is_file())}
    audit_path = package_root.parent / "package-audit.json"; audit_path.write_text(json.dumps(audit, ensure_ascii=False, indent=2), encoding="utf-8")
    if findings: raise SystemExit("包审计失败：\n" + "\n".join(findings[:20]))
    output = package_root.parent / "格志客服模型测试器-Windows-x64.zip"; _stable_zip(package_root, output)
    print(output)


if __name__ == "__main__": main()
