#!/bin/bash
# Register Peeksy's hook in ~/.claude/settings.json.
#
# A wrapper, not an implementation. The merge, the preview, the backup and the
# atomic write all live in the app binary (see Sources/PeeksyCore/Install),
# so there is exactly one answer to "what does installing do" — a jq pipeline in
# here would be a second, subtly different one, against the file that carries
# other tools' hooks.
#
# Usage:
#   scripts/install_hook.sh                 preview, then ask before writing
#   scripts/install_hook.sh --agent codex  select Codex (then trust via /hooks)
#   scripts/install_hook.sh --dry-run       preview only
#   scripts/install_hook.sh --yes           write without asking
#   scripts/install_hook.sh --settings PATH work against a copy (do this first)
#
# Anything else is passed straight through:
#   scripts/install_hook.sh --uninstall-hook
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

INSTALLED="$HOME/Applications/Peeksy.app"
BUILT="dist/Peeksy.app"

# Prefer the installed bundle: that is the copy that keeps existing after the
# next `build_app.sh`, which begins by deleting dist/.
if [ -x "$INSTALLED/Contents/MacOS/Peeksy" ]; then
    APP="$INSTALLED"
elif [ -x "$BUILT/Contents/MacOS/Peeksy" ]; then
    APP="$BUILT"
else
    echo "Peeksy.app is not built." >&2
    echo "" >&2
    echo "Looked in:" >&2
    echo "  $INSTALLED" >&2
    echo "  $(pwd)/$BUILT" >&2
    echo "" >&2
    echo "Build it first:" >&2
    echo "  scripts/build_app.sh --install" >&2
    exit 1
fi

# Default to --install-hook, but let an explicit mode through untouched.
MODE="--install-hook"
for arg in "$@"; do
    case "$arg" in
        --uninstall-hook|--print-hook-json|--install-hook) MODE="" ;;
    esac
done

echo "using: $APP"
echo ""
# MODE is deliberately unquoted: empty must mean "absent", not an empty argument.
# (The explanation goes on its own line — shellcheck rejects prose appended to a
# disable directive and then silently ignores the whole directive.)
# shellcheck disable=SC2086
exec "$APP/Contents/MacOS/Peeksy" $MODE "$@"
