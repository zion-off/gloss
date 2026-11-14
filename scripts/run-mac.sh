#!/usr/bin/env bash
# Builds the Mac app and wraps it in build/gloss.app, for development only: ad hoc signing, one
# architecture. Releases come from scripts/release.sh. Usage: scripts/run-mac.sh [--release] [--no-open]
set -euo pipefail
cd "$(dirname "$0")/.."
[ "$(uname -s)" = Darwin ] || { echo "run-mac.sh needs macOS (the gloss app is macOS-only)"; exit 1; }

# shellcheck source=lib/app-bundle.sh
source scripts/lib/app-bundle.sh

config=debug
open_app=1
for arg in "$@"; do
  case "$arg" in
    --release) config=release ;;
    --no-open) open_app=0 ;;
    *) echo "usage: scripts/run-mac.sh [--release] [--no-open]"; exit 64 ;;
  esac
done

swift build -c "$config" --product GlossMac
bin="$(swift build -c "$config" --show-bin-path)"
app="build/gloss.app"

assemble_app "$bin" "$app" 0.1 1

codesign --force --deep --sign - "$app" >/dev/null 2>&1 || echo "(ad hoc signing failed; the app still runs locally)"
echo "built $app"
if [ "$open_app" = 1 ]; then open "$app"; fi
