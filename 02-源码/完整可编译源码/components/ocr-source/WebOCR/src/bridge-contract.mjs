function boundingRect(poly) {
  const xs = poly.map(([x]) => x);
  const ys = poly.map(([, y]) => y);
  const minX = Math.min(...xs);
  const maxX = Math.max(...xs);
  const minY = Math.min(...ys);
  const maxY = Math.max(...ys);
  return { x: minX, y: minY, width: maxX - minX, height: maxY - minY };
}

export function toBridgePayload(result) {
  return {
    lines: result.items.map((item) => ({
      text: item.text,
      confidence: item.score,
      box: boundingRect(item.poly),
    })),
  };
}

export function dataURLToBlob(dataURL) {
  const comma = dataURL.indexOf(",");
  if (!dataURL.startsWith("data:") || comma < 0) {
    throw new Error("Invalid image data URL");
  }
  const metadata = dataURL.slice(5, comma);
  const mime = metadata.split(";")[0] || "application/octet-stream";
  const binary = atob(dataURL.slice(comma + 1));
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index);
  }
  return new Blob([bytes], { type: mime });
}
