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

sign_app "$app" - >/dev/null 2>&1 || echo "(ad hoc signing failed; the app still runs locally)"
echo "built $app"
if [ "$open_app" = 1 ]; then
  # `open` on an app that is already running only brings the old process forward, so you would keep
  # testing the previous build. Ask this bundle's running copy (and only this path, never an
  # installed gloss.app) to quit the normal way, wait for it, then open the new one.
  here="$(cd "$app" && pwd -P)"
  quit_running() {
    osascript -l JavaScript - "$here" >/dev/null 2>&1 <<'JS' || true
function run(argv) {
  ObjC.import('AppKit');
  const apps = $.NSRunningApplication.runningApplicationsWithBundleIdentifier('dev.gloss.app');
  for (let i = 0; i < apps.count; i++) {
    const a = apps.objectAtIndex(i);
    if (ObjC.unwrap(a.bundleURL.path) === argv[0]) a.terminate();
  }
}
JS
  }
  if pgrep -qf "$here/Contents/MacOS/gloss"; then
    echo "quitting the running gloss..."
    quit_running
    for _ in $(seq 1 40); do
      pgrep -qf "$here/Contents/MacOS/gloss" || break
      sleep 0.25
    done
    if pgrep -qf "$here/Contents/MacOS/gloss"; then
      echo "gloss is still running (a save dialog, maybe?): quit it yourself, then run: open $app"
      exit 0
    fi
  fi
  open "$app"
fi
