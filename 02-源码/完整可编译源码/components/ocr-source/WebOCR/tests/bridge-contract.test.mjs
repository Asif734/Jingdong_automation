import assert from "node:assert/strict";
import test from "node:test";
import { dataURLToBlob, toBridgePayload } from "../src/bridge-contract.mjs";

test("bridge preserves short, repeated, and whitespace-bearing OCR text", () => {
  const result = {
    items: [
      { text: "1", score: 0.99, poly: [[5, 10], [15, 10], [15, 20], [5, 20]] },
      { text: "原文  空格", score: 0.75, poly: [[20, 30], [80, 30], [80, 45], [20, 45]] },
      { text: "1", score: 0.51, poly: [[5, 50], [15, 50], [15, 60], [5, 60]] },
    ],
  };

  assert.deepEqual(toBridgePayload(result), {
    lines: [
      { text: "1", confidence: 0.99, box: { x: 5, y: 10, width: 10, height: 10 } },
      { text: "原文  空格", confidence: 0.75, box: { x: 20, y: 30, width: 60, height: 15 } },
      { text: "1", confidence: 0.51, box: { x: 5, y: 50, width: 10, height: 10 } },
    ],
  });
});

test("bridge keeps empty recognized text instead of filtering it", () => {
  const result = {
    items: [
      { text: "", score: 0.2, poly: [[0, 0], [2, 0], [2, 3], [0, 3]] },
    ],
  };

  assert.equal(toBridgePayload(result).lines.length, 1);
  assert.equal(toBridgePayload(result).lines[0].text, "");
});

test("data URL conversion creates an in-memory blob without fetch", async () => {
  const blob = dataURLToBlob("data:image/png;base64,AQIDBA==");

  assert.equal(blob.type, "image/png");
  assert.deepEqual(new Uint8Array(await blob.arrayBuffer()), new Uint8Array([1, 2, 3, 4]));
});
