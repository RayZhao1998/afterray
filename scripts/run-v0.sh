#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
  printf '%s\n' \
    'Usage: scripts/run-v0.sh [--build-only | --daemon-only] [--keep-data]' \
    '' \
    '  no option       Build everything, start afterrayd, then run the Swift app.' \
    '  --build-only    Compile the capture shim, Rust workspace, and Swift app.' \
    '  --daemon-only   Build and run afterrayd without opening the Swift app.' \
    '  --keep-data     Keep the temporary run directory after exit.' \
    '' \
    'This script never downloads models or starts recording automatically.'
}

mode='app'
keep_data='false'
while (($# > 0)); do
  case "$1" in
    --build-only)
      if [[ "$mode" != 'app' ]]; then
        printf '%s\n' '--build-only and --daemon-only cannot be combined' >&2
        exit 64
      fi
      mode='build'
      ;;
    --daemon-only)
      if [[ "$mode" != 'app' ]]; then
        printf '%s\n' '--build-only and --daemon-only cannot be combined' >&2
        exit 64
      fi
      mode='daemon'
      ;;
    --keep-data)
      keep_data='true'
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n\n' "$1" >&2
      usage >&2
      exit 64
      ;;
  esac
  shift
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"
capture_package="$repo_root/apps/AfterRayCaptureShim"
capture_shim="$capture_package/.build/debug/AfterRayCaptureShim"
daemon_bin="$repo_root/target/debug/afterrayd"
cli_bin="$repo_root/target/debug/afterray"
app_bin="$repo_root/.build/debug/afterray-app"
swift_cache="$repo_root/.afterray-dev/swift-cache"

mkdir -p "$swift_cache/clang" "$swift_cache/swiftpm"
export CLANG_MODULE_CACHE_PATH="$swift_cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$swift_cache/clang"
export SWIFTPM_CUSTOM_CACHE_PATH="$swift_cache/swiftpm"

printf '%s\n' '==> Building native ScreenCaptureKit shim'
swift build \
  --package-path "$capture_package" \
  --configuration debug \
  --product AfterRayCaptureShim

printf '%s\n' '==> Building Rust daemon and CLI'
cargo build --manifest-path "$repo_root/Cargo.toml" --workspace

printf '%s\n' '==> Building Swift recall app'
swift build \
  --package-path "$repo_root" \
  --configuration debug \
  --product afterray-app

if [[ "$mode" == 'build' ]]; then
  printf '%s\n' 'AfterRay V0 build completed.'
  exit 0
fi

run_dir="$(mktemp -d /tmp/afterray-v0.XXXXXX)"
daemon_pid=''

cleanup() {
  local status=$?
  trap - EXIT INT TERM HUP
  if [[ -n "$daemon_pid" ]] && kill -0 "$daemon_pid" 2>/dev/null; then
    kill "$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" 2>/dev/null || true
  fi
  if [[ "$keep_data" == 'true' ]]; then
    printf 'AfterRay run data kept at %s\n' "$run_dir"
  else
    case "$run_dir" in
      /tmp/afterray-v0.*)
        rm -rf -- "$run_dir"
        ;;
      *)
        printf 'Refusing to clean unexpected run directory: %s\n' "$run_dir" >&2
        ;;
    esac
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

export AFTERRAY_SOCKET="$run_dir/afterray.sock"
export AFTERRAY_DATA_DIR="$run_dir/data"
export AFTERRAY_CAPTURE_SHIM="$capture_shim"
daemon_log="$run_dir/afterrayd.log"

printf '==> Starting afterrayd\n    socket: %s\n    data:   %s\n' \
  "$AFTERRAY_SOCKET" "$AFTERRAY_DATA_DIR"
"$daemon_bin" >"$daemon_log" 2>&1 &
daemon_pid=$!

daemon_ready='false'
for _ in {1..100}; do
  if "$cli_bin" --json status >/dev/null 2>&1; then
    daemon_ready='true'
    break
  fi
  if ! kill -0 "$daemon_pid" 2>/dev/null; then
    break
  fi
  sleep 0.1
done

if [[ "$daemon_ready" != 'true' ]]; then
  printf '%s\n' 'afterrayd failed to become ready. Log follows:' >&2
  sed -n '1,240p' "$daemon_log" >&2
  exit 1
fi

printf '\n%s\n' 'AfterRay V0 daemon is ready.'
printf '%s\n' \
  'Recording is intentionally not started automatically.' \
  'The first record start may trigger macOS Screen Recording and Microphone prompts.' \
  'Grant the requested permissions, then retry the command if macOS asks you to.' \
  '' \
  'From another terminal, use:'
printf '  AFTERRAY_SOCKET=%q %q status\n' "$AFTERRAY_SOCKET" "$cli_bin"
printf '  AFTERRAY_SOCKET=%q %q record start\n' "$AFTERRAY_SOCKET" "$cli_bin"
printf '  AFTERRAY_SOCKET=%q %q record stop\n' "$AFTERRAY_SOCKET" "$cli_bin"
printf '  AFTERRAY_SOCKET=%q %q sessions list\n' "$AFTERRAY_SOCKET" "$cli_bin"
printf '\nDaemon log: %s\n' "$daemon_log"

if [[ "$mode" == 'daemon' ]]; then
  printf '%s\n' 'Press Control-C to stop afterrayd and clean the temporary run directory.'
  wait "$daemon_pid"
  exit $?
fi

printf '%s\n' '==> Opening the Swift recall app (close it to stop this V0 run)'
"$app_bin"
