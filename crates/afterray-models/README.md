# afterray-models

`afterray-models` owns the V0 model queue, the model catalog, and the
boundary between `afterrayd` and local inference runtimes. It does not write
results to SQLite; the daemon reads completed typed outputs and commits them
through the store.

## Queue

`ModelQueue` provides:

- `pending`, `running`, `done`, `failed`, and `cancelled` states;
- a separate concurrency limit for OCR, ASR, embeddings, and LLM work;
- automatic retry for process crashes, I/O failures, and timeouts;
- explicit `cancel` and manual `retry` operations;
- typed inputs and outputs, so an OCR worker cannot accidentally satisfy an
  embedding job.

The V0 queue is in memory. Durable job rows belong in `afterray-store`; daemon
startup can resubmit its unfinished rows without changing the adapter contract.

## Worker contract

`ProcessAdapter` starts one child process per inference. It writes exactly one
JSON object to stdin and expects exactly one JSON object on stdout. Logs must go
to stderr.

The shipped worker is the Rust `afterray-model-worker` binary. OCR stays on
`afterray-native-model-worker` (macOS Vision).

## Catalog and download

`catalog` describes the packs the Settings page shows. Repositories and local
paths can be overridden with `AFTERRAY_*` environment variables.

`afterray download` (and the daemon `download_models` request) fetch weights
with Rust/`reqwest`. There is no Python, pip, or Hugging Face client runtime.

```sh
cargo run -p afterray-cli --release -- download
cargo run -p afterray-cli --release -- download --pack asr
```

Default packs:

| id | Source | Runtime |
| --- | --- | --- |
| `asr` | `Qwen/Qwen3-ASR-1.7B` | Candle Metal via `qwen3-asr` |
| `embedding` | nomic GGUF | `llama-cpp-2` Metal |
| `llm` | Optional on-device Qwen3.6-27B Q4 GGUF. Overlay Q&A can instead use Ollama or an OpenAI-compatible URL from Settings. Qwen 3.7 has no local GGUF. | `llama-cpp-2` Metal, Ollama, or OpenAI-compatible HTTP |

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `AFTERRAY_NATIVE_MODEL_WORKER` | bundled Swift worker | OCR executable |
| `AFTERRAY_MODEL_WORKER` | bundled `afterray-model-worker` | ASR / embedding / LLM |
| `AFTERRAY_MODEL_DIR` | AfterRay model directory | weight root |
| `AFTERRAY_ASR_MODEL` | `Qwen3-ASR-1.7B` | ASR snapshot directory |
| `AFTERRAY_ASR_REPOSITORY` | `Qwen/Qwen3-ASR-1.7B` | Hugging Face repo |
| `AFTERRAY_EMBEDDING_MODEL` | nomic GGUF path | embedding weights |
| `AFTERRAY_LLM_MODEL` | optional GGUF path | built-in assistant weights |
| `AFTERRAY_LLM_REPOSITORY` | `unsloth/Qwen3.6-27B-GGUF` | Hugging Face repo for the built-in pack |
| `AFTERRAY_LLM_FILE` | `Qwen3.6-27B-Q4_K_M.gguf` | GGUF filename in that repo |
| `AFTERRAY_LLM_PROVIDER` | `builtin` | `builtin`, `ollama`, or `openai_compatible` |
| `AFTERRAY_LLM_BASE_URL` | empty / Ollama default | remote origin |
| `AFTERRAY_LLM_CHAT_MODEL` | empty | remote chat model id |
| `AFTERRAY_LLM_API_KEY` | empty | optional bearer token |

If a binary, input file, or model is missing, the job ends as `failed` with an
actionable error. No adapter returns placeholder inference data.

## Verification

```sh
rtk cargo test -p afterray-models
rtk cargo clippy -p afterray-models --all-targets -- -D warnings
```
