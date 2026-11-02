#!/usr/bin/env bash
# judge-packet.sh [spec-dir]
# Prints everything the judge needs and nothing else: the original task (spec) + the diff.
. "$(dirname "$0")/lib.sh"
cd "$(git rev-parse --show-toplevel)" || exit 1

SPEC="${1:-}"
if [ -z "$SPEC" ]; then # newest spec folder
  SPEC="$(ls -dt .kiro/specs/*/ 2>/dev/null | grep -v '/_' | head -n 1)"
fi
BASE="$(base_ref)"

echo "################ ORIGINAL TASK (spec: ${SPEC:-none}) ################"
for f in requirements.md bugfix.md design.md tasks.md; do
  [ -n "$SPEC" ] && [ -f "$SPEC/$f" ] && { echo "----- $f -----"; cat "$SPEC/$f"; }
done

echo
echo "################ CHANGE vs base ${BASE:0:12} ################"
git --no-pager diff --stat "$BASE" -- . ':(exclude).kiro/harness/state'
git --no-pager diff "$BASE" -- . ':(exclude).kiro/harness/state' | head -n 2000

UNTRACKED="$(git ls-files --others --exclude-standard)"
if [ -n "$UNTRACKED" ]; then
  echo
  echo "################ NEW (untracked) FILES ################"
  echo "$UNTRACKED" | while read -r f; do
    echo "----- $f -----"; head -n 300 "$f"
  done
fi
echo
echo "TREE_HASH $(tree_hash)"
