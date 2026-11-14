#!/usr/bin/env bash
# Prints true when anything besides docs (markdown, docs/, LICENSE) changed between a base commit
# and HEAD, false otherwise. The swift and web workflows use it to skip their job, rather than the
# whole workflow, on docs-only changes: a job skipped by its `if` still counts as passing for a
# required check, a workflow skipped by a path filter leaves the check waiting forever.
#   scripts/code-changed.sh <base>
# A missing or unknown base (a first push, history that isn't fetched) counts as changed.
set -euo pipefail
cd "$(dirname "$0")/.."

base="${1:-}"
if [ -z "$base" ] || ! git cat-file -e "$base^{commit}" 2>/dev/null; then
  echo true
  exit 0
fi
# Three dots: what HEAD changed since it left base, not what base gained since.
if git diff --name-only "$base...HEAD" | grep -qvE '\.md$|^docs/|^LICENSE$'; then
  echo true
else
  echo false
fi
