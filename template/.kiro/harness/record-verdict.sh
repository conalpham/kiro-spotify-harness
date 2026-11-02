#!/usr/bin/env bash
# record-verdict.sh PASS|FAIL "one-line reason"
# Binds the judge's verdict to the exact working tree it reviewed.
. "$(dirname "$0")/lib.sh"
V="${1:-}"; REASON="${2:-}"
case "$V" in PASS|FAIL) ;; *) echo "usage: record-verdict.sh PASS|FAIL \"reason\"" >&2; exit 1 ;; esac
echo "$V $(tree_hash) $(now) $REASON" > "$STATE_DIR/verdict"
echo "$(now) $V $REASON" >> "$STATE_DIR/verdict-history.log"
echo "Recorded verdict: $V"
