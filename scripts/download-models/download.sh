#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
model_dir=${AFTERRAY_MODEL_DIR:-"$repository_root/.afterray/models"}
runtime_dir=${AFTERRAY_MLX_RUNTIME:-"$repository_root/.afterray/mlx-runtime"}
embedding_url=${AFTERRAY_EMBEDDING_MODEL_URL:-"https://huggingface.co/nomic-ai/nomic-embed-text-v1.5-GGUF/resolve/main/nomic-embed-text-v1.5.Q4_K_M.gguf"}
embedding_path=${AFTERRAY_EMBEDDING_MODEL:-"$model_dir/nomic-embed-text-v1.5.Q4_K_M.gguf"}
asr_repository=${AFTERRAY_ASR_REPOSITORY:-"mlx-community/Qwen3-ASR-1.7B-8bit"}
asr_path=${AFTERRAY_ASR_MODEL:-"$model_dir/Qwen3-ASR-1.7B-8bit"}
whisper_url=${AFTERRAY_WHISPER_MODEL_URL:-"https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin"}
whisper_path=${AFTERRAY_WHISPER_MODEL:-"$model_dir/ggml-large-v3-turbo-q5_0.bin"}
llm_repository=${AFTERRAY_LLM_REPOSITORY:-"mlx-community/gemma-4-26b-a4b-it-4bit"}
llm_path=${AFTERRAY_LLM_MODEL:-"$model_dir/gemma-4-26b-a4b-it-4bit"}
download_only=${AFTERRAY_DOWNLOAD_ONLY:-}

want() {
  [ -z "$download_only" ] || [ "$download_only" = "$1" ]
}

for executable in curl python3; do
  if ! command -v "$executable" >/dev/null 2>&1; then
    echo "error: $executable is required to download AfterRay models" >&2
    exit 1
  fi
done

mkdir -p "$model_dir"

download_file() {
  url=$1
  destination=$2
  label=$3
  if [ -f "$destination" ]; then
    echo "$label already exists: $destination"
    return
  fi
  partial="$destination.partial"
  echo "Downloading $label: $destination"
  curl --fail --location --continue-at - --output "$partial" "$url"
  mv "$partial" "$destination"
}

if want embedding; then
  download_file "$embedding_url" "$embedding_path" "embedding model"
fi

if [ "$download_only" = "whisper" ] || [ "${AFTERRAY_DOWNLOAD_WHISPER:-0}" = "1" ]; then
  download_file "$whisper_url" "$whisper_path" "optional Whisper ASR fallback"
fi

need_mlx=0
if want asr || want llm; then
  need_mlx=1
fi

if [ "$need_mlx" = "1" ]; then
  if [ ! -x "$runtime_dir/bin/python" ]; then
    echo "Creating AfterRay-owned MLX runtime: $runtime_dir"
    python3 -m venv "$runtime_dir"
  fi

  echo "Installing the AfterRay MLX runtime"
  "$runtime_dir/bin/python" -m pip install --disable-pip-version-check --upgrade mlx-vlm mlx-audio huggingface-hub

  if want asr; then
    if [ -d "$asr_path" ] && [ -f "$asr_path/config.json" ]; then
      echo "Qwen3-ASR already exists: $asr_path"
    else
      echo "Downloading Qwen3-ASR into AfterRay storage (about 2.5 GB)"
      "$runtime_dir/bin/python" "$script_dir/download_huggingface_model.py" "$asr_repository" "$asr_path"
    fi
  fi

  if want llm; then
    if [ -d "$llm_path" ] && [ -f "$llm_path/config.json" ]; then
      echo "Gemma 4 already exists: $llm_path"
    else
      echo "Downloading Gemma 4 into AfterRay storage (about 15 GB)"
      "$runtime_dir/bin/python" "$script_dir/download_huggingface_model.py" "$llm_repository" "$llm_path"
    fi
  fi
fi

printf '%s\n' \
  'AfterRay model setup complete. No Ollama service is used.' \
  "MLX runtime: $runtime_dir" \
  "Embedding:   $embedding_path" \
  "ASR:         $asr_path" \
  "LLM:         $llm_path"
