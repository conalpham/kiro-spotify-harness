#!/usr/bin/env bash
# gate.sh — exit 0 only if the CURRENT working tree passed `verify.sh --full`
# AND an independent judge recorded PASS for it. Used by guard-shell.sh (agent),
# ship.sh (human) and fleet.sh (automation). Same rule everywhere.
. "$(dirname "$0")/lib.sh"
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" || exit 1

fail() { echo "GATE CLOSED: $1" >&2; exit 1; }
H="$(tree_hash)"

[ -f "$STATE_DIR/last-verify" ] || fail "run 'bash .kiro/harness/verify.sh --full' first."
read -r vs vh _ < "$STATE_DIR/last-verify"
case "$vs" in
  PASS) ;;
  NONE) fail "no verifier is configured for this project (see 'bash .kiro/harness/setup.sh detect')." ;;
  *)    fail "last full verify FAILED. Fix it and re-run verify --full." ;;
esac
[ "$vh" = "$H" ] || fail "code changed after the last full verify. Re-run verify --full."

[ -f "$STATE_DIR/verdict" ] || fail "no judge verdict yet. Run the harness-judge agent in a NEW session."
read -r js jh _ < "$STATE_DIR/verdict"
[ "$js" = PASS ] || fail "the judge vetoed this change: $(cut -d' ' -f4- "$STATE_DIR/verdict")"
[ "$jh" = "$H" ] || fail "code changed after the judge's verdict. The change must be judged again."

echo "GATE OPEN: verify PASS + judge PASS on tree ${H:0:12}"
