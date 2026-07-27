#!/bin/bash
# Run AgentNotch's built-in diagnostics against the installed (or freshly built)
# app bundle. The bundle matters: Automation permission is granted to the signed
# bundle, not to `swift run`, so `.build/release/AgentNotch --doctor` would report
# a different TCC identity than the one that actually does the focusing.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

INSTALLED="$HOME/Applications/AgentNotch.app"
BUILT="dist/AgentNotch.app"

if [ -x "$INSTALLED/Contents/MacOS/AgentNotch" ]; then
    APP="$INSTALLED"
elif [ -x "$BUILT/Contents/MacOS/AgentNotch" ]; then
    APP="$BUILT"
else
    echo "AgentNotch.app is not built." >&2
    echo "" >&2
    echo "Looked in:" >&2
    echo "  $INSTALLED" >&2
    echo "  $(pwd)/$BUILT" >&2
    echo "" >&2
    echo "Build it first:" >&2
    echo "  scripts/build_app.sh --install" >&2
    exit 1
fi

echo "using: $APP"
echo ""
exec "$APP/Contents/MacOS/AgentNotch" --doctor
