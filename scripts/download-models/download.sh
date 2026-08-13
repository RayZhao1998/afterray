#!/bin/sh
# AfterRay model download. Weights only — no Python, uv, or pip.
# Requires a compiled `afterray` CLI (`cargo build -p afterray --release`).
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
cli=${AFTERRAY_CLI:-"$repository_root/target/release/afterray"}

if [ ! -x "$cli" ]; then
  echo "Building afterray CLI (one-time, no Python)"
  cargo build --manifest-path "$repository_root/Cargo.toml" -p afterray-cli --release
  cli="$repository_root/target/release/afterray"
fi

pack=${AFTERRAY_DOWNLOAD_ONLY:-}
if [ -n "$pack" ]; then
  exec "$cli" download --pack "$pack" --dir "${AFTERRAY_MODEL_DIR:-$repository_root/.afterray/models}"
fi
exec "$cli" download --dir "${AFTERRAY_MODEL_DIR:-$repository_root/.afterray/models}"
