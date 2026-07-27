#!/bin/bash
# Generate AppIcon.icns from the 1024×1024 source PNG.
#
# The .icns is a BUILD ARTEFACT and is gitignored; assets/AppIcon.png is the
# source of truth and is committed, so a fresh clone can rebuild the icon with
# no design tools installed. build_app.sh calls this automatically.
#
# Usage:
#   scripts/make_icon.sh                       assets/AppIcon.png -> AppIcon.icns
#   scripts/make_icon.sh path/to/other.png     use a different source
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

SRC="${1:-assets/AppIcon.png}"
OUT="AppIcon.icns"

if [ ! -f "$SRC" ]; then
    echo "error: no icon source at $SRC" >&2
    exit 1
fi

# The artwork must already be the rounded-rect ("squircle") shape with
# transparent corners. macOS does NOT mask an .icns the way it masks an iOS
# icon — whatever shape is in the PNG is the shape on screen, which is why a
# circular export would read as foreign next to every other Mac app.
read -r W H <<< "$(sips -g pixelWidth -g pixelHeight "$SRC" |
    awk -F': ' '/pixelWidth|pixelHeight/{printf "%s ", $2}')"
if [ "$W" != "1024" ] || [ "$H" != "1024" ]; then
    echo "error: $SRC is ${W}×${H}; a 1024×1024 source is required" >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SET="$WORK/AppIcon.iconset"
mkdir -p "$SET"

# iconutil is strict about these names; anything else is silently left out of
# the archive, which shows up much later as a blurry icon at one size only.
emit() {  # emit <pixels> <filename>
    sips -z "$1" "$1" "$SRC" --out "$SET/$2" >/dev/null 2>&1
}

emit 16   icon_16x16.png
emit 32   icon_16x16@2x.png
emit 32   icon_32x32.png
emit 64   icon_32x32@2x.png
emit 128  icon_128x128.png
emit 256  icon_128x128@2x.png
emit 256  icon_256x256.png
emit 512  icon_256x256@2x.png
emit 512  icon_512x512.png
emit 1024 icon_512x512@2x.png

iconutil --convert icns "$SET" --output "$OUT"
echo "==> $OUT  (from $SRC)"
