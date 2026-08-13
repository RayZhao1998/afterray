# afterray-models

`afterray-models` owns the V0 model queue and the boundary between `afterrayd`
and local inference runtimes. It does not write results to SQLite; the daemon
reads completed typed outputs and commits them through the store.

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

Example request:

```json
{
  "protocol_version": 1,
  "job_id": "019...",
  "capability": "embedding",
  "input": { "type": "embedding", "text": "local memory" }
}
```

Example response:

```json
{
  "protocol_version": 1,
  "output": { "type": "embedding", "vector": [0.1, 0.2] },
  "retryable": false
}
```

On failure, omit `output` and return `error` plus `retryable`. A timeout or
cancellation drops and kills the worker process.

## Local workers

The repository includes two real workers:

- `afterray-native-model-worker` performs screenshot OCR through macOS Vision;
- `afterray_model_worker.py` invokes AfterRay-managed MLX (Qwen3-ASR + Gemma),
  llama.cpp embeddings, and an optional whisper.cpp fallback.

Install native development dependencies and download model assets:

```sh
brew install ffmpeg llama.cpp
scripts/download-models/download.sh
```

Use `ProcessAdapterConfig` directly when different capabilities need different
worker executables, environment variables, timeouts, or working directories.

Configuration variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `AFTERRAY_NATIVE_MODEL_WORKER` | bundled Swift worker | OCR executable |
| `AFTERRAY_ASR_MODEL` | AfterRay model directory | Qwen3-ASR MLX weights |
| `AFTERRAY_ASR_BACKEND` | `qwen3` | `qwen3` or `whisper` |
| `AFTERRAY_EMBEDDING_MODEL` | AfterRay model directory | embedding weights |
| `AFTERRAY_LLM_MODEL` | AfterRay model directory | MLX generation weights |
| `AFTERRAY_FFMPEG_BIN` | `ffmpeg` | audio conversion executable |
| `AFTERRAY_WHISPER_BIN` | `whisper-cli` | optional whisper.cpp executable |
| `AFTERRAY_WHISPER_MODEL` | none | optional whisper.cpp GGML fallback |

If a binary, input file, or model is missing, the job ends as `failed` with an
actionable error. No adapter returns placeholder inference data.

## Verification

```sh
rtk cargo test -p afterray-models
rtk cargo clippy -p afterray-models --all-targets -- -D warnings
python3 -m py_compile scripts/download-models/afterray_model_worker.py
```
