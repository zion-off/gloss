#!/usr/bin/env bash
# Works out the version a release PR publishes, from its labels and the existing v* tags.
#   LABELS='["release","minor"]' scripts/next-version.sh          # prints e.g. 0.2.0
#   LABELS='["release","minor"]' scripts/next-version.sh --check  # only checks the labels
# "release" publishes; one of patch|minor|major picks the bump (patch when none). More than one
# of those three is an error. With no v* tag yet the first release is 0.1.0.
set -euo pipefail
cd "$(dirname "$0")/.."

bumps=$(python3 -I - <<'PY'
import json, os
labels = json.loads(os.environ.get("LABELS", "[]"))
print(" ".join(l for l in labels if l in ("patch", "minor", "major")))
PY
)
count=$(wc -w <<<"$bumps" | tr -d ' ')
if [ "$count" -gt 1 ]; then
  echo "pick one bump label (patch, minor or major), found: $bumps" >&2
  exit 1
fi
[ "${1:-}" = "--check" ] && exit 0
bump="${bumps:-patch}"

latest=$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' | sed 's/^v//' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
if [ -z "$latest" ]; then echo "0.1.0"; exit 0; fi
IFS=. read -r major minor patch <<<"${latest%%-*}"
case "$bump" in
  major) echo "$((major + 1)).0.0" ;;
  minor) echo "$major.$((minor + 1)).0" ;;
  patch) echo "$major.$minor.$((patch + 1))" ;;
esac
