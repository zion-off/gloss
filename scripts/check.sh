#!/usr/bin/env bash
# Runs everything that must be green before a commit (see CLAUDE.md).
set -uo pipefail
cd "$(dirname "$0")/.."
log="${TMPDIR:-/tmp}/gloss-check.log"

if ! swift build --build-tests >"$log" 2>&1; then
  grep -E "error:" "$log" | sort -u | head -40
  echo "✘ build failed (full log: $log)"; exit 1
fi
grep -E "warning:" "$log" | grep -E "/(Sources|Tests)/" | sort -u | head -20

if ! swift test --skip-build >"$log" 2>&1; then
  grep -E "✘|error|failed" "$log" | head -40
  echo "✘ swift tests failed (full log: $log)"; exit 1
fi
grep -E "^✔ Test run with" "$log" | awk '{tests += $5; suites += $8} END {printf "✔ %d swift tests in %d suites\n", tests, suites}'

if [ -f web/pnpm-lock.yaml ]; then
  ( cd web
    pnpm install --frozen-lockfile --silent >/dev/null
    pnpm --silent test && pnpm --silent check-build ) || { echo "✘ web checks failed (typecheck, tests or stale build output)"; exit 1; }
elif [ -f web/package.json ]; then
  echo "✘ web/ has no pnpm-lock.yaml (pnpm is the package manager)"; exit 1
fi
echo "✔ all checks passed"
