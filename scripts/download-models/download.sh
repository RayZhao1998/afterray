#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
model_dir=${AFTERRAY_MODEL_DIR:-"$repository_root/.afterray/models"}
llm_model=${AFTERRAY_LLM_MODEL:-"gemma4:latest"}
ocr_model=${AFTERRAY_OCR_MODEL:-"qwen2.5vl:3b"}
embedding_model=${AFTERRAY_EMBEDDING_MODEL:-"nomic-embed-text"}
whisper_url=${AFTERRAY_WHISPER_MODEL_URL:-"https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin"}
whisper_path=${AFTERRAY_WHISPER_MODEL:-"$model_dir/ggml-large-v3-turbo-q5_0.bin"}

if ! command -v ollama >/dev/null 2>&1; then
  echo "error: ollama is required; install it from https://ollama.com/download" >&2
  exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "error: curl is required to download the whisper.cpp model" >&2
  exit 1
fi
if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "error: ffmpeg is required by the ASR worker; install it with: brew install ffmpeg" >&2
  exit 1
fi
if ! command -v whisper-cli >/dev/null 2>&1; then
  echo "error: whisper-cli is required by the ASR worker; install it with: brew install whisper-cpp" >&2
  exit 1
fi

mkdir -p "$model_dir"

echo "Pulling Ollama LLM: $llm_model"
ollama pull "$llm_model"
echo "Pulling Ollama OCR/VLM: $ocr_model"
ollama pull "$ocr_model"
echo "Pulling Ollama embedding model: $embedding_model"
ollama pull "$embedding_model"

if [ -f "$whisper_path" ]; then
  echo "Whisper model already exists: $whisper_path"
else
  echo "Downloading whisper.cpp ASR model: $whisper_path"
  partial_path="$whisper_path.partial"
  curl --fail --location --continue-at - --output "$partial_path" "$whisper_url"
  mv "$partial_path" "$whisper_path"
fi

echo "Model setup complete."
echo "Set AFTERRAY_WHISPER_MODEL=$whisper_path before starting afterrayd."
