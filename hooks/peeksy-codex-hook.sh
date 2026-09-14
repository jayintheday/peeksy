#!/bin/sh
# Observe Codex without supplying hook decisions or model-visible output.
# Synchronous, short sends preserve turn boundaries; delivery failure is harmless.
SOCK="${PEEKSY_SOCK:-$HOME/Library/Application Support/Peeksy/hook.sock}"
[ -S "$SOCK" ] || exit 0
PAYLOAD=$(cat 2>/dev/null) || exit 0
[ -n "$PAYLOAD" ] || exit 0

# A command hook can be spawned through an intermediate shell. Walk to the
# native codex process, not node, code-mode hosts, or arbitrary shell helpers.
PID=$PPID
CURRENT=$PPID
TTY="?"
DEDICATED=false
DEPTH=0
while [ "$CURRENT" -gt 1 ] 2>/dev/null && [ "$DEPTH" -lt 12 ]; do
    RECORD=$(ps -p "$CURRENT" -o ppid=,tty=,comm= 2>/dev/null) || break
    read -r PARENT TERM COMM <<EOF
$RECORD
EOF
    case "${COMM##*/}" in
        codex)
            PID=$CURRENT
            case "$TERM" in ttys[0-9]*) TTY=$TERM; DEDICATED=true ;; esac
            ARGS=$(ps -p "$CURRENT" -o args= 2>/dev/null)
            # Shared app servers and remote clients are not per-thread heartbeats.
            case "$ARGS" in *" app-server"*|*" --remote"*) DEDICATED=false ;; esac
            break ;;
    esac
    CURRENT=$PARENT
    DEPTH=$((DEPTH + 1))
done

# Only controlled scalar metadata is interpolated. Leave the agent's JSON intact.
case "$PID" in ''|*[!0-9]*) exit 0 ;; esac
case "$TTY" in *[!a-zA-Z0-9]*) TTY="?" ;; esac
REST=$(printf '%s' "$PAYLOAD" | sed 's/^[[:space:]]*//')
case "$REST" in \{*) REST=${REST#\{} ;; *) exit 0 ;; esac
META="\"_meta\":{\"pid\":$PID,\"tty\":\"$TTY\",\"dedicated_process\":$DEDICATED}"
case "$REST" in \}*) ENVELOPE="{$META}" ;; *) ENVELOPE="{$META,$REST" ;; esac
printf '%s' "$ENVELOPE" | curl -s --unix-socket "$SOCK" \
    --connect-timeout 0.2 --max-time 0.25 \
    -X POST -H 'Content-Type: application/json' --data-binary @- \
    http://peeksy/v1/event/codex >/dev/null 2>&1
exit 0
