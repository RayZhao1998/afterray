#!/usr/bin/env bash

set -Eeuo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

printf '==> client / ImageIO / blur / AppKit stages\n'
client_bin="${TMPDIR:-/tmp}/afterray-bench-client"
xcrun swiftc -O -framework AppKit -framework CoreImage -o "$client_bin" \
  "$repo_root/scripts/bench-recall-pipeline.swift"
"$client_bin"

printf '\n==> daemon decrypt / base64 / JSON / unix socket stages\n'
AFTERRAY_BENCH_JPEG="${AFTERRAY_BENCH_JPEG:-/tmp/afterray-bench/busy.jpg}" \
  cargo test -p afterray-store --lib bench_daemon_artifact_stages -- --ignored --nocapture --test-threads=1
