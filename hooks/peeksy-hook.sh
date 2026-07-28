#!/bin/sh
# peeksy hook — bridges Claude Code hook events to the Peeksy app.
#
# Registered in ~/.claude/settings.json ALONGSIDE any existing hooks. Never replaces them.
# Contract: ALWAYS exit 0, silent on every failure, never delay the agent —
# except SessionEnd, which is sent in the FOREGROUND. See below.
# $PPID is the process that spawned the hook: the claude process for a terminal
# session, but the IDE's extension host for an agent panel — it hosts many
# sessions and outlives all of them, so the app must not read it as this
# session's heartbeat.
# Env override (tests): PEEKSY_SOCK

SOCK="${PEEKSY_SOCK:-$HOME/Library/Application Support/Peeksy/hook.sock}"

# Fast path: app not running -> zero forks. Fires on EVERY PreToolUse/PostToolUse.
[ -S "$SOCK" ] || exit 0

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0

PID=$PPID
TTY=$(ps -o tty= -p "$PPID" 2>/dev/null | tr -d ' ' || true)
[ -n "$TTY" ] || TTY="?"
META="\"_meta\":{\"pid\":$PID,\"tty\":\"$TTY\"}"

# Inject _meta as the FIRST key. Strip the leading '{'; if the remainder is just '}',
# the object was empty.
REST=${PAYLOAD#\{}
REST_TRIM=$(printf '%s' "$REST" | sed -e 's/^[[:space:]]*//')
case "$REST_TRIM" in
  '}'*) ENVELOPE="{$META}" ;;
  *)    ENVELOPE="{$META,$REST" ;;
esac

# Hard-capped. Prints NOTHING on stdout so a PermissionRequest hook never
# suppresses Claude Code's own native dialog. $1 is the total time budget.
send() {
  printf '%s' "$ENVELOPE" | curl -s \
    --unix-socket "$SOCK" \
    --connect-timeout 1 --max-time "$1" \
    -X POST -H 'Content-Type: application/json' \
    --data-binary @- \
    "http://peeksy/v1/event/claude-code" >/dev/null 2>&1
}

# SessionEnd is the ONE event that removes a row, and it fires while the process
# carrying it is being torn down — a backgrounded curl there is racing the kill
# that follows, and a lost SessionEnd is a row that outlives its session. So it
# goes in the foreground, on a tighter budget because this one CAN delay an
# agent: 2 s of an exit nobody is waiting on, and only when the socket was
# already there to accept it.
#
# Everything else stays fire-and-forget: PreToolUse/PostToolUse fire tens of
# times a turn and must never cost the agent a millisecond.
#
# A false positive — "SessionEnd" appearing inside a tool input — costs one
# synchronous send and nothing else.
case "$PAYLOAD" in
  *SessionEnd*) send 2 ;;
  *)            send 3 & ;;
esac

exit 0
