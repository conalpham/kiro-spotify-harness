#!/usr/bin/env bash
# Shared helpers for the Kiro "Spotify-style" harness.
# Portable: macOS bash 3.2 + BSD tools, and Linux.

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="$HARNESS_DIR/state"
mkdir -p "$STATE_DIR"
# State is local-only: never committed, never part of the tree hash.
[ -f "$STATE_DIR/.gitignore" ] || printf '*\n' > "$STATE_DIR/.gitignore"

in_git() { git rev-parse --is-inside-work-tree >/dev/null 2>&1; }

# Content hash of the whole working tree (tracked + untracked, minus ignored).
# Uses a throwaway index, so the real index is untouched. The value is the same
# before and after `git commit`, so a verify/judge run before committing still
# counts when the agent later tries to push.
tree_hash() {
  in_git || { echo "no-git"; return; }
  local idx tmp
  idx="$(git rev-parse --git-path index)"
  tmp="$(mktemp "${TMPDIR:-/tmp}/harness-idx.XXXXXX")"
  if [ -f "$idx" ]; then cp "$idx" "$tmp"; else rm -f "$tmp"; fi
  GIT_INDEX_FILE="$tmp" git add -A >/dev/null 2>&1
  GIT_INDEX_FILE="$tmp" git write-tree 2>/dev/null
  rm -f "$tmp"
}

# The commit the current work started from (merge-base with the main branch).
base_ref() {
  local r b
  for r in "${HARNESS_BASE:-}" origin/HEAD origin/main origin/master main master; do
    [ -n "$r" ] || continue
    b="$(git merge-base HEAD "$r" 2>/dev/null)" && [ -n "$b" ] && { echo "$b"; return; }
  done
  git rev-list --max-parents=0 HEAD 2>/dev/null | tail -n 1
}

# Single-line copy of the hook payload read from STDIN.
read_payload() { tr '\n' ' ' ; }

json_field() { # json_field <payload> <key>  -> first string value of "key"
  printf '%s' "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1
}

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
