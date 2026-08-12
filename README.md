# AfterRay

AfterRay V0 is a local-first macOS screen and audio recorder with a Rust daemon,
encrypted local storage, local OCR/ASR/embedding/LLM adapters, and a native Swift
recall timeline.

## Run V0

Requirements: macOS 15+, Apple Silicon, Rust, Xcode/Swift, Ollama, ffmpeg, and
whisper.cpp.

```sh
# Download the development model set.
./scripts/download-models/download.sh

# Build and open the daemon plus Swift app.
make v0
```

The first recording asks macOS for Screen Recording and Microphone access. V0
never starts recording automatically. The vault persists at `.afterray/v0-data`;
use `./scripts/run-v0.sh --ephemeral` only for a disposable test run.

Useful development commands:

```sh
make v0-build
make v0-daemon
cargo test --workspace
swift test
swift run afterray-visual-lab
```

See [the V0 implementation plan](docs/afterray-v0-implementation-plan.md) for
scope and architecture. V0 deliberately excludes Accessibility, meeting
detection, onboarding, subscriptions, App Store packaging, and automatic model
delivery.
