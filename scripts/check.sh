#!/usr/bin/env bash
# Runs everything that must be green before a commit (see CLAUDE.md).
set -uo pipefail
cd "$(dirname "$0")/.."
log="${TMPDIR:-/tmp}/gloss-check.log"

if ! swift build --build-tests >"$log" 2>&1; then
  grep -E "error:" "$log" | sort -u | head -40
  echo "✘ build failed (full log: $log)"; exit 1
fi
warnings=$(grep -E "warning:" "$log" | grep -E "/gloss/(Sources|Tests)/" | sed 's/\x1b\[[0-9;]*m//g' | sort -u)
if [ -n "$warnings" ]; then
  echo "$warnings" | head -20
  echo "✘ compiler warnings in Sources/ or Tests/ (zero-warning policy)"; exit 1
fi

if ! swift test --skip-build >"$log" 2>&1; then
  grep -E "✘|error|failed" "$log" | head -40
  echo "✘ swift tests failed (full log: $log)"; exit 1
fi
grep -E "^✔ Test run with" "$log" | awk '{tests += $5; suites += $8} END {printf "✔ %d swift tests in %d suites\n", tests, suites}'

if [ -x scripts/cli-smoke.sh ]; then
  scripts/cli-smoke.sh || exit 1
fi

if [ -f web/pnpm-lock.yaml ]; then
  ( cd web
    pnpm install --frozen-lockfile --silent >/dev/null
    pnpm --silent test >"$log" 2>&1 || { grep -E "^not ok|error TS|# fail" "$log" | head -20; exit 1; }
    grep -E "^# pass" "$log" | sed 's/^# pass /✔ /; s/$/ web tests/'
    pnpm --silent check-build ) || { echo "✘ web checks failed (typecheck, tests or stale build output; log: $log)"; exit 1; }
elif [ -f web/package.json ]; then
  echo "✘ web/ has no pnpm-lock.yaml (pnpm is the package manager)"; exit 1
fi
echo "✔ all checks passed"
