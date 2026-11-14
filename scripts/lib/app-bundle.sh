# Shared by scripts/run-mac.sh (development) and scripts/release.sh (release): turns SwiftPM's
# build products into a gloss.app. Source this file; it only defines functions.
#
# Layout:
#   gloss.app/Contents/Info.plist
#   gloss.app/Contents/MacOS/gloss          the app (CFBundleExecutable)
#   gloss.app/Contents/Helpers/gloss        the command line tool (only when one is given)
#   gloss.app/Contents/Resources/           gloss.icns and SwiftPM's resource bundles; the app
#                                           finds the reader's files there (ReaderBundle)
# The tool lives in Helpers/, not Resources/, because Helpers/ is a place codesign and
# notarization treat as code. It uses no resource bundles of its own.

# The deployment target from Package.swift (`.macOS(.v14)` -> 14.0, `.v10_15` -> 10.15).
app_min_macos() {
  local v
  v="$(sed -nE 's/.*\.macOS\(\.v([0-9]+(_[0-9]+)?)\).*/\1/p' Package.swift | head -n 1 | tr _ .)"
  [ -n "$v" ] || { echo "can't find the macOS version in Package.swift" >&2; return 1; }
  case "$v" in *.*) echo "$v" ;; *) echo "$v.0" ;; esac
}

# assemble_app <bin-dir> <app> <short-version> <build-number> [<cli-binary>]
# Extra Info.plist entries (Sparkle's SUFeedURL and friends, later) go in $GLOSS_PLIST_EXTRA,
# as plist <key>/<value> lines, and land just before the closing </dict>.
assemble_app() {
  local bin="$1" app="$2" version="$3" build="$4" cli="${5:-}" min_macos
  min_macos="$(app_min_macos)"

  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp "$bin/GlossMac" "$app/Contents/MacOS/gloss"
  if [ -n "$cli" ]; then
    mkdir -p "$app/Contents/Helpers"
    cp "$cli" "$app/Contents/Helpers/gloss"
  fi
  # SwiftPM resource bundles (the reader's files among them); ReaderBundle looks in Resources first.
  local bundle
  for bundle in "$bin"/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$app/Contents/Resources/"
  done

  # The app icon (scripts/app-icon: the .icns plus its svg sources).
  cp scripts/app-icon/gloss.icns "$app/Contents/Resources/gloss.icns"

  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>gloss</string>
    <key>CFBundleIconFile</key><string>gloss</string>
    <key>CFBundleIdentifier</key><string>dev.gloss.app</string>
    <key>CFBundleName</key><string>gloss</string>
    <key>CFBundleDisplayName</key><string>gloss</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>$build</string>
    <key>LSMinimumSystemVersion</key><string>$min_macos</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.books</string>
    <key>NSHumanReadableCopyright</key><string>Copyright © 2026 the gloss authors. MIT license.</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <!-- gloss:// links from other apps, \`gloss open\` and scripts (brief 16). -->
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>dev.gloss.link</string>
            <key>CFBundleURLSchemes</key>
            <array><string>gloss</string></array>
        </dict>
    </array>
    <!-- Finder double-clicking a book gloss can read (brief 36); the ids are the system's
         UTIs (UTType.epub / UTType.pdf). The registered formats live in
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
${GLOSS_PLIST_EXTRA:-}
</dict>
</plist>
PLIST
  plutil -lint "$app/Contents/Info.plist" >/dev/null
}
