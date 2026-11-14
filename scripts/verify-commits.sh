#!/usr/bin/env bash
# Builds and tests each commit in a range in a throwaway worktree, so every commit is known to
# build on its own (commit policy). Usage: scripts/verify-commits.sh <base>..<head>
set -uo pipefail
cd "$(dirname "$0")/.."
range="${1:?usage: verify-commits.sh base..head}"
tree="${TMPDIR:-/tmp}/gloss-verify-tree"
scratch="${TMPDIR:-/tmp}/gloss-verify-build"
[ -d "$tree" ] || git worktree add --detach "$tree" HEAD >/dev/null 2>&1
# The two commits that brought in the Mac type-check (bad64a6, dba60f2) predate GLOSS_BUILD_DIR and
# read the build from <repo>/.build only; point that at the scratch build so they can type-check
# too. .build/ is ignored by git, so checking out other commits leaves the link alone.
if [ "$(readlink "$tree/.build" 2>/dev/null)" != "$scratch" ]; then
  rm -rf "$tree/.build" && ln -s "$scratch" "$tree/.build"
fi
status=0
for commit in $(git rev-list --reverse "$range"); do
  subject=$(git log -1 --format=%s "$commit")
  git -C "$tree" checkout -q --detach "$commit"
  # Commits that have scripts/mac-typecheck.py also type-check their Mac modules against the stub frameworks — a
  # Linux-only round (on a Mac the real build already type-checks them; the stub round there
  # would only test the stubs).
  if (cd "$tree" && swift build --build-tests --scratch-path "$scratch" >/tmp/gloss-verify.log 2>&1 \
        && swift test --skip-build --scratch-path "$scratch" >>/tmp/gloss-verify.log 2>&1 \
        && { [ ! -f scripts/mac-typecheck.py ] || [ "$(uname -s)" = Darwin ] \
             || GLOSS_BUILD_DIR="$scratch/debug" python3 scripts/mac-typecheck.py >>/tmp/gloss-verify.log 2>&1; }); then
    echo "✔ ${commit:0:7} $subject"
  else
    echo "✘ ${commit:0:7} $subject (log: /tmp/gloss-verify.log)"; status=1
  fi
done
exit $status
