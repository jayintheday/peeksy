#!/bin/sh
# agent-notch hook — bridges Claude Code hook events to the AgentNotch app.
#
# Registered in ~/.claude/settings.json ALONGSIDE any existing hooks. Never replaces them.
# Contract: ALWAYS exit 0, silent on every failure, never delay the agent.
# $PPID is the claude process: Claude Code spawns hooks as CHILDREN.
# Env override (tests): AGENT_NOTCH_SOCK

SOCK="${AGENT_NOTCH_SOCK:-$HOME/Library/Application Support/AgentNotch/hook.sock}"

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

# Fire-and-forget, backgrounded, hard-capped. Prints NOTHING on stdout so a
# PermissionRequest hook never suppresses Claude Code's own native dialog.
printf '%s' "$ENVELOPE" | curl -s \
  --unix-socket "$SOCK" \
  --connect-timeout 1 --max-time 3 \
  -X POST -H 'Content-Type: application/json' \
  --data-binary @- \
  "http://agent-notch/v1/event/claude-code" >/dev/null 2>&1 &

exit 0
