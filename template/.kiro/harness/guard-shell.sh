#!/usr/bin/env bash
# PreToolUse guard for shell commands (Kiro blocks the tool call on non-zero exit).
# Mirrors Spotify's restricted Git tool + Bash allowlist + "no PR unless verifiers pass".
# Second layer behind the Kiro-enforced permissions in .kiro/agents/harness-*.json.
. "$(dirname "$0")/lib.sh"

INPUT="$(read_payload)"
SESSION="$(json_field "$INPUT" session_id)"

deny() { echo "HARNESS BLOCKED: $1" >&2; exit 2; }
has_cmd() { printf '%s' "$INPUT" | grep -E -q -e "$1"; }

# 1) Commands an agent never needs inside the harness
has_cmd 'git +push[^"]*( --force| -f( |"|$)|--force-with-lease)' && deny "force push is not allowed."
has_cmd 'git +remote +(add|set-url|remove|rm|rename)'               && deny "changing git remotes is not allowed."
has_cmd 'git +config'                                              && deny "changing git config (identity, hooks) is not allowed."
has_cmd '[-]-no-verify'                                            && deny "skipping git hooks (--no-verify) is not allowed."
has_cmd 'git +reset +--hard|git +clean +-[a-zA-Z]*f|git +checkout +(-- +)?\. *("|$)' && deny "destructive git command; ask the user instead."
has_cmd '(^|[ ;&|"])sudo +'                                        && deny "sudo is not allowed."
has_cmd 'rm +-[a-zA-Z]*[rR][a-zA-Z]* +(/|~|\$HOME)( |"|$)'         && deny "recursive delete of / or home is not allowed."
has_cmd '(curl|wget)[^|"]*\| *(ba|z)?sh'                           && deny "piping downloads into a shell is not allowed."

# 2) The harness is read-only for agents, including through the shell.
has_cmd '(rm|mv|cp|tee|touch|truncate|chmod|chown|ln|dd|sed +-i[^ ]*|perl +-[a-zA-Z]*i)[^;&|"]*\.kiro/(harness|hooks|agents)/' \
  && deny "the harness (.kiro/harness, .kiro/hooks, .kiro/agents) is read-only for the agent."
has_cmd '>>? *[^ ;&|"]*\.kiro/(harness|hooks|agents)/' && deny "the harness is read-only for the agent."
has_cmd '\.kiro/harness/(ship|fleet)\.sh|setup\.sh +unlock|install\.sh[^"]*--force' \
  && deny "shipping, fleet runs and unlocking are done by the human (or CI), not by the agent."

# 3) The judge must be independent: a session that edited code cannot record a verdict.
if has_cmd 'record-verdict\.sh'; then
  if [ -n "$SESSION" ] && grep -q -x -F "$SESSION" "$STATE_DIR/writer-sessions" 2>/dev/null; then
    deny "this session edited code, so it cannot judge its own change. Start a NEW session with the harness-judge agent."
  fi
fi

# 4) Gate: nothing leaves the machine unless verify --full and the judge both passed
#    on exactly the current working tree.
if has_cmd '(git +push|gh +pr +create|glab +mr +create)'; then
  REASON="$(bash "$HARNESS_DIR/gate.sh" 2>&1 >/dev/null)" || deny "${REASON#GATE CLOSED: }"
fi

exit 0
