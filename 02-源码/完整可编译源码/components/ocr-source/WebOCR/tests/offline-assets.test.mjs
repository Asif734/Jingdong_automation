import assert from "node:assert/strict";
import { access } from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const ort = path.join(root, "Sources/QianniuOCRAppSupport/Resources/WebOCR/ort");

test("offline bundle contains every ORT module selected by Safari", async () => {
  for (const filename of [
    "ort-wasm-simd-threaded.mjs",
    "ort-wasm-simd-threaded.wasm",
    "ort-wasm-simd-threaded.jsep.mjs",
    "ort-wasm-simd-threaded.jsep.wasm",
  ]) {
    await assert.doesNotReject(access(path.join(ort, filename)), filename);
  }
});
