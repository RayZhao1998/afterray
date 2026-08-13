#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

echo "==> unit: codec / store / daemon GOP"
cargo test -p afterray-codec -p afterray-store -p afterrayd --offline -- --test-threads=1

echo "==> VideoToolbox fixture decode"
swift "$root/scripts/prove-av1-decode.swift" \
  "$root/crates/afterray-codec/fixtures/closed-gop-64x64.ivf"

if [[ -d /tmp/afterray-gop-sim/frames/Lody ]]; then
  echo "==> live-sample packer e2e (Lody 12-frame GOP, release)"
  AFTERRAY_GOP_E2E_FULL=1 cargo test -p afterrayd --release --offline \
    packer_encodes_closed_gop_and_serves_poster -- --nocapture
  if [[ -f /tmp/afterray-gop-e2e.ivf ]]; then
    echo "==> VideoToolbox decode of packed 3456x2234 GOP"
    swift "$root/scripts/prove-av1-decode.swift" /tmp/afterray-gop-e2e.ivf
  fi
fi

echo "==> GOP e2e checks passed"
