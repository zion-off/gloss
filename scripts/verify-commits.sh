#!/usr/bin/env bash
# Builds and tests each commit in a range in a throwaway worktree, so every commit is known to
# build on its own (commit policy). Usage: scripts/verify-commits.sh <base>..<head>
set -uo pipefail
cd "$(dirname "$0")/.."
range="${1:?usage: verify-commits.sh base..head}"
tree="${TMPDIR:-/tmp}/gloss-verify-tree"
scratch="${TMPDIR:-/tmp}/gloss-verify-build"
[ -d "$tree" ] || git worktree add --detach "$tree" HEAD >/dev/null 2>&1
status=0
for commit in $(git rev-list --reverse "$range"); do
  subject=$(git log -1 --format=%s "$commit")
  git -C "$tree" checkout -q --detach "$commit"
  if (cd "$tree" && swift build --build-tests --scratch-path "$scratch" >/tmp/gloss-verify.log 2>&1 \
        && swift test --skip-build --scratch-path "$scratch" >>/tmp/gloss-verify.log 2>&1 \); then
    echo "✔ ${commit:0:7} $subject"
  else
    echo "✘ ${commit:0:7} $subject (log: /tmp/gloss-verify.log)"; status=1
  fi
done
exit $status
