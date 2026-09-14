#!/bin/bash
# Assemble and ad-hoc sign dist/Peeksy.app.
#
# Adapted from open-focus (MIT, © 2026 Filip Sokolowski) — see NOTICE.
#
# Usage:
#   scripts/build_app.sh              build dist/Peeksy.app
#   scripts/build_app.sh --install    also copy it to ~/Applications
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

APP_NAME="Peeksy"
BUNDLE_ID="com.vijaypatel.peeksy"
VERSION="0.2.0"
BINARY="Peeksy"
DIST="dist"
APP="$DIST/$APP_NAME.app"
ICON_SRC="assets/AppIcon.png"
ICON="AppIcon.icns"

INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

# Which build is this? CFBundleShortVersionString answers a different question
# — the release name — and cannot distinguish this build from one three weeks
# ago. `rev-parse` is used rather than `describe` because it is the one that
# still works in CI's shallow checkout, and every command is guarded so a source
# tarball with no .git builds perfectly well, just unstamped.
GIT_COMMIT="$(git rev-parse --short HEAD 2>/dev/null || true)"
if [ -n "$GIT_COMMIT" ] && ! git diff --quiet HEAD 2>/dev/null; then
    GIT_DIRTY="true"
else
    GIT_DIRTY="false"
fi
BUILD_DATE="$(date '+%Y-%m-%d %H:%M')"

echo "==> Building release binary"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

if [ ! -f "$BIN_DIR/$BINARY" ]; then
    echo "error: expected binary at $BIN_DIR/$BINARY but it is missing" >&2
    exit 1
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/$BINARY" "$APP/Contents/MacOS/$APP_NAME"

# The .icns is generated, not committed — assets/AppIcon.png is the source of
# truth, so a fresh clone builds an icon without any design tools. Regenerate
# whenever the source is newer, or the icon silently stays one design behind.
if [ -f "$ICON_SRC" ] && { [ ! -f "$ICON" ] || [ "$ICON_SRC" -nt "$ICON" ]; }; then
    scripts/make_icon.sh "$ICON_SRC"
fi

if [ -f "$ICON" ]; then
    cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
    echo "    bundled $ICON"
else
    echo "    note: $ICON not found — bundling without an icon"
fi

# Both scripts are shipped as resources and synced to stable installed paths.
for hook in hooks/peeksy-hook.sh hooks/peeksy-codex-hook.sh; do
    cp "$hook" "$APP/Contents/Resources/"
    chmod +x "$APP/Contents/Resources/$(basename "$hook")"
done

# NSAppleEventsUsageDescription is mandatory, not cosmetic: without it the very
# first Apple event fails with errAEEventNotPermitted (-1743), and on some macOS
# versions the process is killed outright rather than merely denied.
cat > "$APP/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>Peeksy</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>PeeksyCommit</key><string>$GIT_COMMIT</string>
    <key>PeeksyDirty</key><string>$GIT_DIRTY</string>
    <key>PeeksyBuildDate</key><string>$BUILD_DATE</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>© 2026 Vijay Patel. Portions © 2026 Filip Sokolowski (MIT).</string>
    <key>NSAppleEventsUsageDescription</key><string>Peeksy brings the Terminal window running your agent session to the front when you click it.</string>
</dict>
</plist>
PLIST

# Sign LAST — Info.plist and Resources are part of the code signature seal, so
# anything written after this point invalidates it.
# No --deep (deprecated, and there are no nested bundles to sign anyway).
# --identifier is pinned so the signing identity can never drift from the plist.
echo "==> Signing"
xattr -cr "$APP"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
codesign --verify --verbose=2 "$APP"

echo "==> Done: $APP"

if [ "$INSTALL" -eq 1 ]; then
    DEST="$HOME/Applications"
    mkdir -p "$DEST"
    echo "==> Installing to $DEST/$APP_NAME.app"
    rm -rf "$DEST/$APP_NAME.app"
    ditto "$APP" "$DEST/$APP_NAME.app"
    echo "==> Installed: $DEST/$APP_NAME.app"
    echo ""
    echo "    NOTE: ad-hoc signing produces a new cdhash on every build, so macOS"
    echo "    may silently deny Automation after a rebuild — focus clicks then fail"
    echo "    with -1743 (errAEEventNotPermitted) and no prompt. If that happens:"
    echo ""
    echo "        tccutil reset AppleEvents $BUNDLE_ID"
    echo ""
    echo "    then click a session once to get a fresh permission prompt."
fi
