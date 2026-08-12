#!/usr/bin/env bash

set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"

osascript -e 'tell application id "dev.afterray.app" to quit' >/dev/null 2>&1 || true

executables=(
  "$repo_root/.afterray-dev/AfterRay.app/Contents/MacOS/AfterRay"
  "$repo_root/.afterray-dev/AfterRay.app/Contents/Helpers/afterrayd"
  "$repo_root/.build/debug/afterray-visual-lab"
)

for _ in {1..20}; do
  still_running='false'
  for executable in "${executables[@]}"; do
    if pgrep -f -x "$executable" >/dev/null 2>&1; then
      still_running='true'
      break
    fi
  done
  [[ "$still_running" == 'false' ]] && break
  sleep 0.1
done

for executable in "${executables[@]}"; do
  pids=()
  while IFS= read -r pid; do
    [[ -n "$pid" ]] && pids+=("$pid")
  done < <(pgrep -f -x "$executable" 2>/dev/null || true)
  if ((${#pids[@]} > 0)); then
    kill "${pids[@]}" 2>/dev/null || true
  fi
done

printf '%s\n' 'AfterRay development processes stopped.'
