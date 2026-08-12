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

## Reference local worker

The repository includes a real worker at
`scripts/download-models/afterray_model_worker.py`:

- OCR: an Ollama vision model;
- Embedding: Ollama `/api/embed`;
- LLM: Ollama `/api/generate`;
- ASR: ffmpeg normalization followed by `whisper-cli` from whisper.cpp.

Install runtime dependencies, start Ollama, then download model assets:

```sh
brew install ollama ffmpeg whisper-cpp
ollama serve
scripts/download-models/download.sh
```

Use `worker_adapters` to create all four adapters for the reference worker:

```rust,no_run
use afterray_models::worker_adapters;

let adapters = worker_adapters("scripts/download-models/afterray_model_worker.py");
```

Use `ProcessAdapterConfig` directly when different capabilities need different
worker executables, environment variables, timeouts, or working directories.

Configuration variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `AFTERRAY_OLLAMA_URL` | `http://127.0.0.1:11434` | Ollama API |
| `AFTERRAY_OCR_MODEL` | `qwen2.5vl:3b` | OCR/VLM model |
| `AFTERRAY_EMBEDDING_MODEL` | `nomic-embed-text` | embedding model |
| `AFTERRAY_LLM_MODEL` | `gemma3:4b` | generation model |
| `AFTERRAY_FFMPEG_BIN` | `ffmpeg` | audio conversion executable |
| `AFTERRAY_WHISPER_BIN` | `whisper-cli` | whisper.cpp executable |
| `AFTERRAY_WHISPER_MODEL` | none | required local GGML model path |

If a binary, input file, or model is missing, the job ends as `failed` with an
actionable error. No adapter returns placeholder inference data.

## Verification

```sh
rtk cargo test -p afterray-models
rtk cargo clippy -p afterray-models --all-targets -- -D warnings
python3 -m py_compile scripts/download-models/afterray_model_worker.py
```
