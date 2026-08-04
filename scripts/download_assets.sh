#!/bin/bash
# Supertonic 3 모델 파일을 Hugging Face에서 내려받아 assets/에 넣는다 (~400MB).
set -e
cd "$(dirname "$0")/.."
BASE="https://huggingface.co/Supertone/supertonic-3/resolve/main"
mkdir -p assets/onnx assets/voice_styles

for f in duration_predictor.onnx text_encoder.onnx vector_estimator.onnx vocoder.onnx tts.json unicode_indexer.json; do
  echo "다운로드: onnx/$f"
  curl -L --progress-bar -o "assets/onnx/$f" "$BASE/onnx/$f"
done

for v in M1 M2 M3 M4 M5 F1 F2 F3 F4 F5; do
  echo "다운로드: voice_styles/$v.json"
  curl -L -s -o "assets/voice_styles/$v.json" "$BASE/voice_styles/$v.json"
done

echo "완료! assets/ 준비 끝."
