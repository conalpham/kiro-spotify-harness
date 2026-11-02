#!/usr/bin/env bash
# PreToolUse guard for file-writing tools.
#  - the agent may not edit the harness itself (verifiers, hooks, harness steering)
#  - remembers which sessions wrote code, so those sessions cannot act as the judge
. "$(dirname "$0")/lib.sh"

INPUT="$(read_payload)"
SESSION="$(json_field "$INPUT" session_id)"

if printf '%s' "$INPUT" | grep -E -q '"[A-Za-z_]*([Pp]ath|[Ff]ile)[A-Za-z_]*"[[:space:]]*:[[:space:]]*"[^"]*\.kiro/(harness/|hooks/|agents/|steering/harness-)'; then
  echo "HARNESS BLOCKED: the harness files (.kiro/harness, .kiro/hooks, .kiro/agents, .kiro/steering/harness-*) are read-only for the agent. Configure verifiers with 'bash .kiro/harness/setup.sh' while setup is unlocked, or ask the user." >&2
  exit 2
fi

if [ -n "$SESSION" ]; then
  grep -q -x -F "$SESSION" "$STATE_DIR/writer-sessions" 2>/dev/null || echo "$SESSION" >> "$STATE_DIR/writer-sessions"
fi
exit 0
