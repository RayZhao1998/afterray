#!/usr/bin/env bash

set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"
app_bundle="$repo_root/.afterray-dev/AfterRay.app"

if [[ ! -d "$app_bundle" ]]; then
  printf '%s\n' 'AfterRay.app has not been built. Run `make dev` or `make v0-build` first.' >&2
  exit 66
fi

open "$app_bundle"
