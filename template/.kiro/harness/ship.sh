#!/usr/bin/env bash
# ship.sh [spec-dir]   — HUMAN or CI only (agents are blocked from running it).
# Plays the role of Spotify's surrounding infrastructure: the agent never pushes;
# this script pushes and opens the PR only when the gate is open.
. "$(dirname "$0")/lib.sh"
cd "$(git rev-parse --show-toplevel)" || exit 1
die() { echo "SHIP ERROR: $1" >&2; exit 1; }

bash "$HARNESS_DIR/gate.sh" || exit 1
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
case "$BRANCH" in main|master|develop|HEAD) die "refusing to ship from '$BRANCH'; work on a feature branch." ;; esac
[ -z "$(git status --porcelain)" ] || die "uncommitted changes. Commit them first (the gate already covers their content)."

SPEC="${1:-$(ls -dt .kiro/specs/*/ 2>/dev/null | grep -v '/_' | head -n 1)}"
SPEC="${SPEC%/}"
BODY="$(mktemp)"
{
  echo "## Change"
  [ -n "$SPEC" ] && [ -f "$SPEC/requirements.md" ] && sed -n '1,40p' "$SPEC/requirements.md"
  echo
  echo "## Harness evidence"
  echo "- verify: \`$(cat "$STATE_DIR/last-verify")\`"
  echo "- judge:  \`$(cat "$STATE_DIR/verdict")\`"
  if [ -n "$SPEC" ] && [ -f "$SPEC/retro.md" ]; then echo; echo "## Agent retro / risks for the reviewer"; cat "$SPEC/retro.md"; fi
} > "$BODY"

git push -u origin "$BRANCH" || die "push failed"
if command -v gh >/dev/null 2>&1; then
  gh pr create --fill --body-file "$BODY" || die "gh pr create failed (body kept at $BODY)"
else
  echo "Pushed. 'gh' not installed: open the PR manually. Suggested body: $BODY"
fi
