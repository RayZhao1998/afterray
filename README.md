# AfterRay

**A private timeline for everything you saw and heard on your Mac.**

AfterRay continuously captures your screen, system audio, microphone audio,
and the foreground app's Accessibility tree. Local OCR and speech recognition turn those
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

- Automatic recording after the required macOS permissions are approved.
- A native macOS timeline with horizontal drag-to-recall.
- Screenshot previews, OCR text, transcripts, and audio playback by moment.
- Full-text and local embedding search across captured evidence.
- Local session summaries through an AfterRay-managed MLX runtime.
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
- `ffmpeg`, `whisper.cpp`, and `llama.cpp` for the current developer build.

Install the command-line dependencies with Homebrew:

```sh
brew install ffmpeg whisper-cpp llama.cpp
```

Install Rust from [rustup.rs](https://rustup.rs/) if `cargo --version` is not
already available.

## Quick start

Clone the repository and enter it, then let AfterRay download its own local
runtime and model files. This is required once:

```sh
./scripts/download-models/download.sh
```

Build and launch AfterRay:

```sh
make v0
```

The command assembles and launches a signed development `AfterRay.app`. On its
first launch the app immediately requests Screen & System Audio Recording,
Microphone, and Accessibility access. macOS presents these as separate system
approvals; Accessibility must be enabled in System Settings. AfterRay starts
recording automatically as soon as all three are enabled.

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

1. Approve the three macOS permissions and use your Mac normally.
2. Use **Pause** only when you intentionally want capture to stop.
3. Drag the recall strip left or right to move through captured moments.
4. Inspect OCR, Accessibility, and transcript evidence for the selected moment.
5. Play its audio segment when one is available.
6. Favorite an important moment to protect it from retention cleanup.
7. Search for words or concepts to jump back to matching evidence.

Screenshots are captured every 10 seconds in V0. The interval can be changed
with `AFTERRAY_CAPTURE_INTERVAL_SECONDS`.

## Local models

AfterRay downloads model files into `.afterray/models` and owns the inference
processes itself. No Ollama installation, server, account, or API is involved.
Rust continues to own scheduling, concurrency, retries, cancellation, and
result storage; native workers only execute typed local inference jobs.

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
  ScreenCaptureKit + AX shim          Vision + MLX + native runtimes
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
# Watch the complete app. Successful builds are signed and relaunched;
# failed builds leave the previous instance running.
make dev

# Storybook-like mock-data UI loop. No recording permissions or real data.
make dev-ui

# Open the last successful build without rebuilding, or stop app + daemon.
make open
make stop

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
| `AFTERRAY_MODEL_WORKER` | Typed local model worker | Bundled AfterRay worker |

## Troubleshooting

### Recording fails immediately

Open **System Settings → Privacy & Security** and verify all three:

- **Screen & System Audio Recording**
- **Microphone**
- **Accessibility**

Enable the terminal application that launched AfterRay, or the AfterRay helper
if macOS lists it separately. macOS may require that application to be quit and
reopened before the permission becomes active.

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

V0 intentionally does not include activity-triggered capture, meeting
detection, subscriptions, production App Store packaging, multi-device sync,
third-party agent access, or Windows support. Model setup is still a developer
script rather than the final in-app download experience.

The next product milestone is focused on the recall experience itself: making
navigation through hours, days, and eventually months feel immediate and
visually distinctive.

For the frozen V0 scope and technical decisions, read the
[V0 implementation plan](docs/afterray-v0-implementation-plan.md).

## Project status

AfterRay is currently a private development project. External contributions are
not being accepted during V0, and no public source license has been selected in
this repository yet.
