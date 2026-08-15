#!/usr/bin/env bash

# Checks the inexpensive, release-blocking conditions before a signed build and
# two notarization submissions. It reads release state but does not write it.

set -Eeuo pipefail

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

step() {
  printf '==> %s\n' "$*"
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "required tool not found: $1"
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"
plist="$repo_root/apps/AfterRay/Resources/Info.plist"
wrangler_config="$repo_root/site/wrangler.jsonc"
plist_buddy='/usr/libexec/PlistBuddy'
bucket='afterray-releases'
index_key='releases.json'

for tool in git npx python3 security xcrun; do
  require_tool "$tool"
done
[[ -x "$plist_buddy" ]] || die "required tool not found: $plist_buddy"
[[ -f "$wrangler_config" ]] || die "missing wrangler config: $wrangler_config"
[[ -n "${AFTERRAY_CODESIGN_IDENTITY:-}" ]] \
  || die 'AFTERRAY_CODESIGN_IDENTITY must name the intended Developer ID identity'
[[ -n "${AFTERRAY_NOTARY_PROFILE:-}" ]] \
  || die 'AFTERRAY_NOTARY_PROFILE must name a Keychain notary profile'

step 'Checking repository state'
[[ -z "$(git -C "$repo_root" status --porcelain --untracked-files=normal)" ]] \
  || die 'worktree is dirty; commit or remove release-unrelated changes first'
git -C "$repo_root" fetch --quiet origin main
head_sha="$(git -C "$repo_root" rev-parse HEAD)"
remote_main_sha="$(git -C "$repo_root" rev-parse origin/main)"
[[ "$head_sha" == "$remote_main_sha" ]] \
  || die 'HEAD is not origin/main; push or rebase the intended release commit first'

step 'Checking version and build number'
version="$($plist_buddy -c 'Print :CFBundleShortVersionString' "$plist")"
workspace_version="$(awk '
  /^\[workspace\.package\]$/ { in_workspace_package = 1; next }
  /^\[/ { in_workspace_package = 0 }
  in_workspace_package && /^version[[:space:]]*=/ {
    value = $0
    sub(/^[^=]*=[[:space:]]*"/, "", value)
    sub(/"[[:space:]]*$/, "", value)
    print value
    exit
  }
' "$repo_root/Cargo.toml")"
[[ -n "$workspace_version" && "$workspace_version" == "$version" ]] \
  || die 'Info.plist and Cargo workspace versions must match'
build="$(git -C "$repo_root" rev-list --count HEAD)"
[[ "$version" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || die "invalid marketing version: $version"

step 'Checking signing and notarization access'
security find-identity -v -p codesigning | grep -F -- "$AFTERRAY_CODESIGN_IDENTITY" >/dev/null \
  || die 'the requested Developer ID identity is unavailable in the login Keychain'
xcrun notarytool history --keychain-profile "$AFTERRAY_NOTARY_PROFILE" >/dev/null \
  || die 'the requested notary Keychain profile is unavailable'
sign_update="${AFTERRAY_SPARKLE_SIGN_UPDATE:-$repo_root/.afterray-dev/sparkle-tools/bin/sign_update}"
[[ -x "$sign_update" ]] || die 'sign_update is missing; run make sparkle-tools first'

step 'Checking the published release index'
index_local="$(mktemp /tmp/afterray-releases.XXXXXX.json)"
cleanup() {
  rm -f -- "$index_local"
}
trap cleanup EXIT
npx --yes wrangler r2 object get "$bucket/$index_key" \
  --file "$index_local" \
  --remote \
  --config "$wrangler_config" >/dev/null
python3 - "$index_local" "$version" "$build" <<'PYTHON'
import json, sys

path, version, build_text = sys.argv[1:]
with open(path) as handle:
    releases = json.load(handle).get("releases", [])

build = int(build_text)
archive = f"AfterRay-{version}-arm64.zip"
installer = f"AfterRay-{version}-arm64.dmg"
highest = max((int(item["build"]) for item in releases), default=0)
if build <= highest:
    raise SystemExit(f"build {build} is not newer than published build {highest}")
for item in releases:
    if item.get("archive") == archive or item.get("installer") == installer:
        raise SystemExit(
            f"version {version} would reuse an immutable published artifact name; "
            "bump the marketing version before building"
        )
PYTHON

printf 'Preflight passed: version %s, build %s.\n' "$version" "$build"
