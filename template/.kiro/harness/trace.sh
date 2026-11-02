#!/usr/bin/env bash
# PostToolUse: append every tool call to a local trace (Spotify keeps traces in MLflow).
# Must print nothing: on exit 0, stdout would be added to the agent's context.
. "$(dirname "$0")/lib.sh"
INPUT="$(read_payload | cut -c1-4000)"
printf '%s\t%s\n' "$(now)" "$INPUT" >> "$STATE_DIR/trace.log"
exit 0
