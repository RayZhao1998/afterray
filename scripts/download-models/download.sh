#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
model_dir=${AFTERRAY_MODEL_DIR:-"$repository_root/.afterray/models"}
runtime_dir=${AFTERRAY_MLX_RUNTIME:-"$repository_root/.afterray/mlx-runtime"}
embedding_url=${AFTERRAY_EMBEDDING_MODEL_URL:-"https://huggingface.co/nomic-ai/nomic-embed-text-v1.5-GGUF/resolve/main/nomic-embed-text-v1.5.Q4_K_M.gguf"}
embedding_path=${AFTERRAY_EMBEDDING_MODEL:-"$model_dir/nomic-embed-text-v1.5.Q4_K_M.gguf"}
whisper_url=${AFTERRAY_WHISPER_MODEL_URL:-"https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin"}
whisper_path=${AFTERRAY_WHISPER_MODEL:-"$model_dir/ggml-large-v3-turbo-q5_0.bin"}
llm_repository=${AFTERRAY_LLM_REPOSITORY:-"mlx-community/gemma-4-26b-a4b-it-4bit"}
llm_path=${AFTERRAY_LLM_MODEL:-"$model_dir/gemma-4-26b-a4b-it-4bit"}

for executable in curl ffmpeg whisper-cli llama-embedding python3; do
  if ! command -v "$executable" >/dev/null 2>&1; then
    echo "error: $executable is required by AfterRay's local model runtime" >&2
    echo "Install native tools with: brew install ffmpeg whisper-cpp llama.cpp" >&2
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

download_file "$embedding_url" "$embedding_path" "embedding model"
download_file "$whisper_url" "$whisper_path" "Whisper ASR model"

if [ ! -x "$runtime_dir/bin/python" ]; then
  echo "Creating AfterRay-owned MLX runtime: $runtime_dir"
  python3 -m venv "$runtime_dir"
fi

echo "Installing the AfterRay MLX runtime"
"$runtime_dir/bin/python" -m pip install --disable-pip-version-check --upgrade mlx-vlm huggingface-hub

if [ -d "$llm_path" ] && [ -f "$llm_path/config.json" ]; then
  echo "Gemma 4 already exists: $llm_path"
else
  echo "Downloading Gemma 4 into AfterRay storage (about 15 GB)"
  "$runtime_dir/bin/python" "$script_dir/download_huggingface_model.py" "$llm_repository" "$llm_path"
fi

printf '%s\n' \
  'AfterRay model setup complete. No Ollama service is used.' \
  "MLX runtime: $runtime_dir" \
  "Embedding:   $embedding_path" \
  "ASR:         $whisper_path" \
  "LLM:         $llm_path"
