#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
import wave
from pathlib import Path

import numpy as np
import sherpa_onnx


def emit(value: dict) -> None:
    sys.stdout.write(json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def pcm_audio(path: Path) -> tuple[np.ndarray, int, float]:
    temporary: Path | None = None
    try:
        if path.suffix.lower() != ".wav":
            handle = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
            handle.close()
            temporary = Path(handle.name)
            subprocess.run(
                ["/usr/bin/afconvert", "-f", "WAVE", "-d", "LEI16@16000", str(path), str(temporary)],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
            )
            path = temporary
        with wave.open(str(path), "rb") as audio_file:
            rate = audio_file.getframerate()
            channels = audio_file.getnchannels()
            width = audio_file.getsampwidth()
            frames = audio_file.readframes(audio_file.getnframes())
        if width != 2:
            raise ValueError(f"expected 16-bit PCM, got sample width {width}")
        samples = np.frombuffer(frames, dtype="<i2").astype(np.float32)
        if channels > 1:
            samples = samples.reshape(-1, channels).mean(axis=1)
        samples /= 32768.0
        return samples, rate, len(samples) / rate
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def serve(recognizer: sherpa_onnx.OfflineRecognizer) -> None:
    emit({"type": "ready", "model": "sensevoice-int8"})
    for line in sys.stdin:
        request_id = None
        try:
            request = json.loads(line)
            request_id = request.get("id")
            audio_path = request.get("audio_path")
            if not isinstance(request_id, str) or not request_id:
                raise ValueError("request id must be a nonempty string")
            if not isinstance(audio_path, str) or not audio_path:
                raise ValueError("audio_path must be a nonempty string")
            samples, sample_rate, duration = pcm_audio(Path(audio_path))
            stream = recognizer.create_stream()
            stream.accept_waveform(sample_rate, samples)
            recognizer.decode_stream(stream)
            emit({
                "id": request_id,
                "ok": True,
                "text": stream.result.text,
                "duration_seconds": duration,
            })
        except Exception as error:
            emit({"id": request_id, "ok": False, "error": str(error)})


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--tokens", required=True)
    args = parser.parse_args()
    recognizer = sherpa_onnx.OfflineRecognizer.from_sense_voice(
        model=args.model,
        tokens=args.tokens,
        num_threads=4,
        provider="cpu",
        language="zh",
        use_itn=True,
        debug=False,
    )
    serve(recognizer)


if __name__ == "__main__":
    main()
