#!/usr/bin/env bash
# Builds a release of gloss into dist/: a universal (arm64 + x86_64) gloss.app with the `gloss`
# command line tool inside, gloss-<version>.dmg and gloss-<version>.dmg.sha256.
#
#   scripts/release.sh <version>      e.g. 0.1.0 or 0.2.0-beta.1
#
# Signing is ad hoc unless GLOSS_SIGN_IDENTITY names a "Developer ID Application" identity
# (then: hardened runtime + timestamp). With GLOSS_NOTARY_PROFILE too (a `notarytool
# store-credentials` keychain profile), the dmg is notarized and stapled. The identity path
# has not been run yet (no developer account at the time of writing).
# GLOSS_ALLOW_DIRTY=1 allows building from a working tree with uncommitted changes.
set -euo pipefail
cd "$(dirname "$0")/.."

usage() { echo "usage: scripts/release.sh <version>   (e.g. 0.1.0, 0.2.0-beta.1)"; }
say() { echo "gloss release: $*"; }
die() { echo "gloss release: $*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || die "needs macOS (the gloss app is macOS-only)"
[ $# -eq 1 ] || { usage; exit 64; }
version="$1"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || { echo "'$version' isn't a semantic version" >&2; usage; exit 64; }
if [ -n "$(git status --porcelain)" ] && [ "${GLOSS_ALLOW_DIRTY:-0}" != 1 ]; then
  die "the working tree has uncommitted changes (commit them, or set GLOSS_ALLOW_DIRTY=1)"
fi
[ -z "${GLOSS_NOTARY_PROFILE:-}" ] || [ -n "${GLOSS_SIGN_IDENTITY:-}" ] \
  || die "GLOSS_NOTARY_PROFILE needs GLOSS_SIGN_IDENTITY (notarizing wants a Developer ID signature)"

# shellcheck source=lib/app-bundle.sh
source scripts/lib/app-bundle.sh

build_number="$(git rev-list --count HEAD)"
dist="dist"
app="$dist/gloss.app"
dmg="$dist/gloss-$version.dmg"

say "building $version (build $build_number), universal release"
swift build -c release --arch arm64 --arch x86_64 --product GlossMac
swift build -c release --arch arm64 --arch x86_64 --product gloss
bin="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

say "assembling $app"
mkdir -p "$dist"
rm -f "$dmg" "$dmg.sha256"
assemble_app "$bin" "$app" "$version" "$build_number" "$bin/gloss"

if [ -n "${GLOSS_SIGN_IDENTITY:-}" ]; then
  say "signing with '$GLOSS_SIGN_IDENTITY' (hardened runtime)"
  sign=(codesign --force --options runtime --timestamp --sign "$GLOSS_SIGN_IDENTITY")
  # Inside out, no --deep: the tool first, then the app that seals it.
  "${sign[@]}" "$app/Contents/Helpers/gloss"
  "${sign[@]}" "$app"
else
  say "signing ad hoc (set GLOSS_SIGN_IDENTITY for a Developer ID build)"
  codesign --force --deep --sign - "$app"
fi
codesign --verify --deep --strict "$app"

say "making $dmg"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"
hdiutil create -quiet -volname gloss -srcfolder "$stage" -format UDZO -ov "$dmg"

if [ -n "${GLOSS_SIGN_IDENTITY:-}" ]; then
  codesign --force --timestamp --sign "$GLOSS_SIGN_IDENTITY" "$dmg"
  if [ -n "${GLOSS_NOTARY_PROFILE:-}" ]; then
    say "notarizing (this waits for apple)"
    xcrun notarytool submit "$dmg" --keychain-profile "$GLOSS_NOTARY_PROFILE" --wait
    xcrun stapler staple "$dmg"
  fi
fi

say "checksum"
(cd "$dist" && shasum -a 256 "$(basename "$dmg")" > "$(basename "$dmg").sha256")

say "done:"
ls -lh "$dmg" "$dmg.sha256" | awk '{print "  " $NF "  " $5}'
cat "$dmg.sha256"
