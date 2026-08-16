#!/usr/bin/env bash

# Tags a release only after its published appcast entry is publicly visible.
# Tags are immutable release provenance, not a way to start a release.

set -Eeuo pipefail

usage() {
  printf '%s\n' \
    'Usage: scripts/tag-release.sh dist/AfterRay-<version>-arm64.json' \
    '' \
    'Verifies that the manifest belongs to clean origin/main and is visible in' \
    'the public appcast, then creates and pushes annotated tag v<version>.'
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 1 ]] || { usage >&2; exit 64; }
manifest_path="$1"
[[ -f "$manifest_path" ]] || die "manifest not found: $manifest_path"

for tool in curl git python3; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done

read_field() {
  python3 -c '
import json, sys
with open(sys.argv[1]) as handle:
    document = json.load(handle)
value = document.get(sys.argv[2])
if value is None:
    sys.exit("missing field: " + sys.argv[2])
print(json.dumps(value) if isinstance(value, bool) else value)
' "$manifest_path" "$1"
}

version="$(read_field version)"
build="$(read_field build)"
notarized="$(read_field notarized)"
source_dirty="$(read_field source_dirty)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid version: $version"
[[ "$build" =~ ^[0-9]+$ ]] || die "invalid build: $build"
[[ "$notarized" == 'true' ]] || die 'refusing to tag an unnotarized manifest'
[[ "$source_dirty" == 'false' ]] || die 'refusing to tag a dirty-source manifest'

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"
[[ -z "$(git status --porcelain)" ]] || die 'worktree must be clean before tagging'
git fetch origin main --quiet
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] \
  || die 'HEAD must equal origin/main before tagging'
[[ "$build" == "$(git rev-list --count HEAD)" ]] \
  || die "manifest build $build does not match HEAD"

tag="v$version"
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  [[ "$(git rev-parse "$tag^{commit}")" == "$(git rev-parse HEAD)" ]] \
    || die "existing $tag points at a different commit"
else
  git tag -a "$tag" -m "AfterRay $version (build $build)"
fi

appcast_path="$(mktemp /tmp/afterray-appcast.XXXXXX.xml)"
cleanup() {
  rm -f -- "$appcast_path"
}
trap cleanup EXIT
curl --fail --silent --show-error --location \
  https://afterray.com/appcast.xml >"$appcast_path"
python3 - "$appcast_path" "$version" "$build" <<'PYTHON'
import sys
import xml.etree.ElementTree as ET

path, version, build = sys.argv[1:]
root = ET.parse(path).getroot()
namespace = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
for item in root.findall('./channel/item'):
    title = item.findtext('title')
    sparkle_build = item.findtext(f'{namespace}version')
    if title == version and sparkle_build == build:
        break
else:
    sys.exit(f'appcast does not contain {version} build {build}')
PYTHON

git push origin "refs/tags/$tag"
printf 'Tagged and pushed %s at %s.\n' "$tag" "$(git rev-parse --short HEAD)"
