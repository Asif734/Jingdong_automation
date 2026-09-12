import { cp, mkdir, rm } from "node:fs/promises";
import { spawn } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const output = path.resolve(root, "../Sources/QianniuOCRAppSupport/Resources/WebOCR");
const ortDist = path.resolve(root, "node_modules/onnxruntime-web/dist");

await rm(output, { recursive: true, force: true });
await mkdir(path.join(output, "models"), { recursive: true });
await mkdir(path.join(output, "ort"), { recursive: true });

await new Promise((resolve, reject) => {
  const child = spawn(path.join(root, "node_modules/esbuild/bin/esbuild"), [
    path.join(root, "src/ocr.mjs"),
    "--bundle",
    "--format=esm",
    "--platform=browser",
    "--target=safari16",
    "--external:fs",
    "--external:path",
    "--minify",
    `--outfile=${path.join(output, "ocr.js")}`,
  ], { stdio: ["ignore", "pipe", "pipe"] });
  let stderr = "";
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk) => { stderr += chunk; });
  child.on("error", reject);
  child.on("close", (code) => {
    if (code === 0) resolve();
    else reject(new Error(stderr || `esbuild exited with code ${code}`));
  });
});

await cp(path.join(root, "src/index.html"), path.join(output, "index.html"));
await cp(path.join(root, "assets/models"), path.join(output, "models"), { recursive: true });

for (const filename of [
  "ort-wasm-simd-threaded.mjs",
  "ort-wasm-simd-threaded.wasm",
  "ort-wasm-simd-threaded.jsep.mjs",
  "ort-wasm-simd-threaded.jsep.wasm",
]) {
  await cp(path.join(ortDist, filename), path.join(output, "ort", filename));
}
