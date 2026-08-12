# AfterRay

**A private timeline for everything you saw and heard on your Mac.**

AfterRay continuously captures your screen and, when you choose to record,
system and microphone audio. Local OCR and speech recognition turn those
captures into searchable context. A native recall timeline lets you drag back
through the day, recover the exact screen you saw, and play the audio around
that moment.

Everything runs on your Mac. Captures, indexes, model inputs, and model outputs
stay local.

> [!IMPORTANT]
> AfterRay is currently a developer V0, built to prove the complete local
> capture → understanding → recall loop on one Mac. It is not yet packaged or
> hardened for general distribution.

## What works today

- Manual recording of the current display, system audio, and microphone audio.
- A native macOS timeline with horizontal drag-to-recall.
- Screenshot previews, OCR text, transcripts, and audio playback by moment.
- Full-text and local embedding search across captured evidence.
- Local session summaries through an Ollama-hosted LLM.
- Favorites that survive automatic retention cleanup.
- An encrypted local vault backed by SQLCipher and XChaCha20-Poly1305.
- A Rust CLI that exposes the same API used by the Swift app.
- A standalone Visual Lab for iterating on recall UI with deterministic mock
  data.

## Requirements

- Apple Silicon Mac (M3 or newer recommended).
- macOS 15 or newer.
- Around 14 GB of free space for the default development model set, plus space
  for recordings.
- Xcode and the Xcode Command Line Tools.
- A current Rust toolchain.
- [Ollama](https://ollama.com/download), `ffmpeg`, and `whisper.cpp`.

Install the command-line dependencies with Homebrew:

```sh
brew install ollama ffmpeg whisper-cpp
```

Install Rust from [rustup.rs](https://rustup.rs/) if `cargo --version` is not
already available.

## Quick start

Clone the repository and enter it, then start Ollama:

```sh
ollama serve
```

In another terminal, download the local models. This is required once:

```sh
./scripts/download-models/download.sh
```

Build and launch AfterRay:

```sh
make v0
```

The command builds the native capture helper, Rust daemon and CLI, then opens
the Swift app. It does **not** begin recording automatically.

Click **Record** in the app to start a session. On the first attempt, macOS will
request Screen & System Audio Recording and Microphone access. Grant access to
the terminal or capture helper shown by macOS, quit the affected process if
asked, run `make v0` again, and click **Record** once more.

Recorded data persists between runs at:

```text
.afterray/v0-data
```

Use a disposable vault for testing with:

```sh
./scripts/run-v0.sh --ephemeral
```

Stop AfterRay by pressing `Control-C` in the terminal that launched it.

## Using the app

1. Click **Record** and use your Mac normally.
2. Click **Stop** when the session is finished.
3. Drag the recall strip left or right to move through captured moments.
4. Inspect OCR and transcript evidence associated with the selected moment.
5. Play its audio segment when one is available.
6. Favorite an important moment to protect it from retention cleanup.
7. Search for words or concepts to jump back to matching evidence.

Screenshots are captured every 10 seconds in V0. The interval can be changed
with `AFTERRAY_CAPTURE_INTERVAL_SECONDS`.

## Local models

The development setup currently connects four local capabilities:

| Capability | Default runtime | Default model |
| --- | --- | --- |
| OCR | Ollama | `qwen2.5vl:3b` |
| Speech recognition | whisper.cpp | `large-v3-turbo-q5_0` |
| Embedding | Ollama | `nomic-embed-text` |
| LLM | Ollama | `gemma4:latest` |

Rust owns scheduling, concurrency, retries, cancellation, and result storage.
The model worker only performs one typed inference request at a time. This
keeps the core independent from Ollama and whisper.cpp, so the inference layer
can later move to MLX without changing the app or vault.

Override a model or runtime with environment variables before launching:

```sh
export AFTERRAY_OCR_MODEL='qwen2.5vl:3b'
export AFTERRAY_EMBEDDING_MODEL='nomic-embed-text'
export AFTERRAY_LLM_MODEL='gemma4:latest'
export AFTERRAY_WHISPER_MODEL="$PWD/.afterray/models/ggml-large-v3-turbo-q5_0.bin"
make v0
```

## Architecture

```text
AfterRay.app (SwiftUI)                 afterray CLI (Rust)
          │                                      │
          └──────── versioned Unix socket ───────┘
                                 │
                          afterrayd (Rust)
             ┌───────────────────┼────────────────────┐
             │                   │                    │
       Capture scheduler   Encrypted vault      Model queue
             │            SQLite + artifacts   OCR/ASR/Emb/LLM
             │                                        │
   macOS capture backend                    Local process adapter
             │                                        │
  thin ScreenCaptureKit shim              Ollama + whisper.cpp
```

The split is intentional:

- **Rust owns product state and policy:** sessions, scheduling, backpressure,
  retention, encryption, search, model jobs, IPC, and the CLI.
- **Swift owns the native interface:** recall interaction, rendering, playback,
  and the smallest possible bridge to Apple-only capture APIs.
- **The UI never opens the database or reads encryption keys.** It requests
  typed read models and decrypted artifacts from the daemon.

The vault key is created in macOS Keychain. Metadata is stored in an encrypted
SQLCipher database, while screenshot and audio artifacts are encrypted
individually before being persisted.

## CLI and daemon

Run only the daemon when developing the CLI:

```sh
make v0-daemon
```

The runner prints the temporary socket path and ready-to-copy commands for a
second terminal. With `AFTERRAY_SOCKET` set to that path, the main commands are:

```sh
afterray status --json
afterray record start
afterray record stop
afterray sessions list --json
afterray moments <session-id> --json
afterray search 'weekly planning' --json
afterray favorite add <moment-id>
afterray favorite remove <moment-id>
afterray summarize <session-id> --json
afterray models --json
afterray jobs list --json
```

When running from the repository, replace `afterray` with
`target/debug/afterray`.

## Visual development

The recall surface can be developed without recording real user data:

```sh
swift run afterray-visual-lab
```

The Visual Lab includes empty, short, long-day, processing, and favorites
scenarios plus live controls for timeline scale, opacity, glow, and related
presentation values. See [the Visual Lab workflow](docs/visual-lab-workflow.md)
for details.

## Development

```sh
# Build everything without launching the app
make v0-build

# Run the Rust test suite
cargo test --workspace

# Run the Swift test suite
swift test

# Treat Rust warnings as errors
cargo clippy --workspace --all-targets -- -D warnings
```

Repository layout:

```text
apps/                         Swift app, Visual Lab, capture shim
crates/                       Rust daemon, CLI, store, protocol and adapters
swift/                        Reusable Recall UI and mock data
scripts/download-models/      Model worker and development downloads
docs/                         Product specification and implementation notes
```

## Configuration

| Variable | Purpose | Default |
| --- | --- | --- |
| `AFTERRAY_DATA_DIR` | Persistent vault location | `.afterray/v0-data` through the V0 runner |
| `AFTERRAY_SOCKET` | Unix socket shared by clients and daemon | Runner-generated temporary path |
| `AFTERRAY_CAPTURE_INTERVAL_SECONDS` | Screenshot interval | `10` |
| `AFTERRAY_MAX_UNSTARRED_MOMENTS` | Retention ceiling for non-favorites | `10000` |
| `AFTERRAY_MODEL_WORKER` | Typed local model worker | Bundled Python worker |
| `AFTERRAY_OLLAMA_URL` | Ollama API endpoint | `http://127.0.0.1:11434` |

## Troubleshooting

### Recording fails immediately

Open **System Settings → Privacy & Security** and verify both:

- **Screen & System Audio Recording**
- **Microphone**

Enable the terminal application that launched AfterRay, or the AfterRay helper
if macOS lists it separately. macOS may require that application to be quit and
reopened before the permission becomes active.

### AfterRay cannot reach Ollama

Start it in another terminal:

```sh
ollama serve
```

Then confirm that the models exist:

```sh
ollama list
```

### A model is missing

Resume the model setup script. Existing downloads are reused:

```sh
./scripts/download-models/download.sh
```

### Start with an empty disposable vault

```sh
./scripts/run-v0.sh --ephemeral
```

This does not modify the persistent vault at `.afterray/v0-data`.

## V0 boundaries

V0 intentionally does not include activity-triggered capture, Accessibility
Tree snapshots, meeting detection, automatic recording, onboarding, model
delivery, subscriptions, App Store packaging, multi-device sync, third-party
agent access, or Windows support.

The next product milestone is focused on the recall experience itself: making
navigation through hours, days, and eventually months feel immediate and
visually distinctive.

For the frozen V0 scope and technical decisions, read the
[V0 implementation plan](docs/afterray-v0-implementation-plan.md).

## Project status

AfterRay is currently a private development project. External contributions are
not being accepted during V0, and no public source license has been selected in
this repository yet.
