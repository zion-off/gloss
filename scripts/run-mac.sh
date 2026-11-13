#!/usr/bin/env bash
# Builds the Mac app and wraps it in build/gloss.app, for development only: ad hoc signing, no
# notarization, no distribution (CLAUDE.md). Usage: scripts/run-mac.sh [--release] [--no-open]
set -euo pipefail
cd "$(dirname "$0")/.."
[ "$(uname -s)" = Darwin ] || { echo "run-mac.sh needs macOS (the gloss app is macOS-only)"; exit 1; }

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

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/GlossMac" "$app/Contents/MacOS/gloss"
# SwiftPM resource bundles (the reader's files among them); ReaderBundle looks in Resources first.
for bundle in "$bin"/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$app/Contents/Resources/"
done

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>gloss</string>
    <key>CFBundleIdentifier</key><string>dev.gloss.app</string>
    <key>CFBundleName</key><string>gloss</string>
    <key>CFBundleDisplayName</key><string>gloss</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.books</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <!-- gloss:// links from other apps, `gloss open` and scripts (brief 16). -->
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>dev.gloss.link</string>
            <key>CFBundleURLSchemes</key>
            <array><string>gloss</string></array>
        </dict>
    </array>
    <!-- Finder double-clicking a book gloss can read (brief 36); the ids are the system's
         UTIs (UTType.epub / UTType.pdf, docs/MAC_API_NOTES.md). The registered formats live in
         code (FormatRegistry); v1 ships epub and pdf. -->
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>epub book</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array><string>org.idpf.epub-container</string></array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key><string>pdf document</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array><string>com.adobe.pdf</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$app" >/dev/null 2>&1 || echo "(ad hoc signing failed; the app still runs locally)"
echo "built $app"
if [ "$open_app" = 1 ]; then open "$app"; fi
