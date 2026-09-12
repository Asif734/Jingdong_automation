import { PaddleOCR } from "@paddleocr/paddleocr-js";
import { dataURLToBlob, toBridgePayload } from "./bridge-contract.mjs";

const initialization = PaddleOCR.create({
  textDetectionModelName: "PP-OCRv5_mobile_det",
  textDetectionModelAsset: {
    url: "/models/PP-OCRv5_mobile_det_onnx_infer.tar",
  },
  textRecognitionModelName: "PP-OCRv5_mobile_rec",
  textRecognitionModelAsset: {
    url: "/models/PP-OCRv5_mobile_rec_onnx_infer.tar",
  },
  textRecognitionBatchSize: 6,
  textRecScoreThresh: 0,
  ortOptions: {
    backend: "wasm",
    wasmPaths: "/ort/",
    numThreads: 1,
    simd: true,
  },
});

window.qianniuOCR = {
  async ready() {
    const engine = await initialization;
    return engine.getInitializationSummary();
  },

  async recognize(imageDataURL) {
    const engine = await initialization;
    const image = dataURLToBlob(imageDataURL);
    const [result] = await engine.predict(image, {
      textDetThresh: 0.2,
      textDetBoxThresh: 0.3,
      textRecScoreThresh: 0,
    });
    return toBridgePayload(result);
  },
};
