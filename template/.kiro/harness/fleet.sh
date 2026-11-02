#!/usr/bin/env bash
# fleet.sh <repos.txt> <spec-dir> [--dry-run]   — HUMAN or CI only.
# Spotify "Fleet Management" in miniature: apply ONE spec to many repos with Kiro CLI
# headless. Per repo: branch -> coder agent -> verify -> judge agent (separate run =
# separate session) -> gate -> commit -> ship. Results in fleet-report.tsv.
#
# Requirements: kiro-cli (headless mode, KIRO_API_KEY set), every repo already has the
# harness installed and locked. repos.txt: one absolute repo path per line.
set -u
REPOS="${1:-}"; SPEC_SRC="${2:-}"; DRY="${3:-}"
[ -f "$REPOS" ] && [ -d "$SPEC_SRC" ] || { echo "usage: fleet.sh <repos.txt> <spec-dir> [--dry-run]" >&2; exit 1; }
command -v kiro-cli >/dev/null 2>&1 || { echo "kiro-cli not found (https://kiro.dev/docs/cli/headless/)" >&2; exit 1; }
[ -n "${KIRO_API_KEY:-}" ] || { echo "KIRO_API_KEY is not set (required by headless mode)" >&2; exit 1; }

SPEC_SRC="$(cd "$SPEC_SRC" && pwd)"
NAME="$(basename "$SPEC_SRC")"
REPORT="$(pwd)/fleet-report.tsv"
KIRO="kiro-cli chat --v3 --no-interactive --trust-all-tools"
printf 'repo\tstatus\tbranch\tdetail\n' > "$REPORT"
row() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$REPORT"; echo "[$2] $1 $4"; }

while IFS= read -r REPO || [ -n "$REPO" ]; do
  case "$REPO" in ''|\#*) continue ;; esac
  ( cd "$REPO" 2>/dev/null || { row "$REPO" SKIP - "not found"; exit 0; }
    H=.kiro/harness
    [ -f "$H/state/locked" ] || { row "$REPO" SKIP - "harness not installed/locked"; exit 0; }
    [ -z "$(git status --porcelain)" ] || { row "$REPO" SKIP - "dirty working tree"; exit 0; }
    BR="harness/$NAME-$(date +%Y%m%d)"
    git switch -q -c "$BR" 2>/dev/null || git switch -q "$BR" || { row "$REPO" SKIP - "cannot create branch"; exit 0; }
    mkdir -p ".kiro/specs/$NAME" && cp -R "$SPEC_SRC/." ".kiro/specs/$NAME/"
    LOG="$H/state/fleet-$NAME.log"

    $KIRO --agent harness-coder "Execute every task in .kiro/specs/$NAME/tasks.md following the harness rules. Check the preconditions first. Finish by running: bash .kiro/harness/verify.sh --full" > "$LOG" 2>&1
    grep -q 'PRECONDITION NOT MET' "$LOG" && { row "$REPO" SKIP "$BR" "precondition not met"; exit 0; }
    [ -n "$(git status --porcelain -- . ':(exclude).kiro/specs')" ] || { row "$REPO" NOCHANGE "$BR" "agent made no change"; exit 0; }

    bash "$H/verify.sh" --full >> "$LOG" 2>&1 || { row "$REPO" FAIL_VERIFY "$BR" "see $LOG"; exit 0; }

    $KIRO --agent harness-judge "Judge the change for spec .kiro/specs/$NAME: run bash .kiro/harness/judge-packet.sh .kiro/specs/$NAME, apply the checklist, record the verdict." >> "$LOG" 2>&1
    GATE="$(bash "$H/gate.sh" 2>&1)" || { row "$REPO" VETO "$BR" "$GATE"; exit 0; }

    git add -A && git commit -q -m "harness($NAME): apply spec $NAME" -m "Verified by .kiro/harness (verify + independent judge)." \
      || { row "$REPO" FAIL "$BR" "commit failed"; exit 0; }
    if [ "$DRY" = "--dry-run" ]; then row "$REPO" READY "$BR" "dry run: not pushed"; exit 0; fi
    bash "$H/ship.sh" ".kiro/specs/$NAME" >> "$LOG" 2>&1 && row "$REPO" SHIPPED "$BR" "PR opened" || row "$REPO" FAIL_SHIP "$BR" "see $LOG"
  )
done < "$REPOS"

echo "Report: $REPORT"
