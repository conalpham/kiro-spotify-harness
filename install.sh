#!/usr/bin/env bash
# install.sh [--with-ci] [--force] <project-dir>
# Copies the harness from ./template/.kiro into a project. Idempotent:
#  - never overwrites the project's own files (only harness-owned paths are written)
#  - refuses to touch a LOCKED harness unless a human passes --force from a terminal
set -u
KIT="$(cd "$(dirname "$0")" && pwd)"
SRC="$KIT/template/.kiro"
WITH_CI=0; FORCE=0; DEST=""
for a in "$@"; do
  case "$a" in
    --with-ci) WITH_CI=1 ;;
    --force) FORCE=1 ;;
    -*) echo "unknown option $a" >&2; exit 1 ;;
    *) DEST="$a" ;;
  esac
done
[ -n "$DEST" ] || { echo "usage: install.sh [--with-ci] [--force] <project-dir>" >&2; exit 1; }
DEST="$(cd "$DEST" 2>/dev/null && pwd)" || { echo "INSTALL ERROR: project dir not found" >&2; exit 1; }
cd "$DEST" || exit 1
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "INSTALL ERROR: $DEST is not a git repository. Ask the user whether to run 'git init' first." >&2; exit 1; }
DEST="$(git rev-parse --show-toplevel)"; cd "$DEST" || exit 1

if [ -f .kiro/harness/state/locked ]; then
  if [ $FORCE -eq 1 ] && [ -t 0 ]; then echo "Upgrading a locked harness (forced by a human)."
  else echo "INSTALL ERROR: harness is already installed and LOCKED here. A human can upgrade with: bash $KIT/install.sh --force $DEST" >&2; exit 1; fi
fi

copied=0; kept=0
put() { # put <relative path under .kiro>  (harness-owned: always refreshed)
  mkdir -p "$(dirname ".kiro/$1")"
  cp "$SRC/$1" ".kiro/$1"; copied=$((copied+1))
}
keep() { # keep <relative path>  (user-editable after install: only copied if missing)
  if [ -e ".kiro/$1" ]; then kept=$((kept+1)); else mkdir -p "$(dirname ".kiro/$1")"; cp -R "$SRC/$1" ".kiro/$1"; copied=$((copied+1)); fi
}

for f in lib.sh verify.sh gate.sh guard-shell.sh guard-write.sh trace.sh judge-packet.sh record-verdict.sh setup.sh ship.sh fleet.sh; do
  put "harness/$f"
done
chmod +x .kiro/harness/*.sh
put hooks/spotify-harness.json
put agents/harness-coder.json
put agents/harness-judge.json
put steering/harness-principles.md
put steering/harness-judge.md
put steering/harness-spec-guide.md
keep specs/_example-simpledateformat-to-javatime

mkdir -p .kiro/harness/state && printf '*\n' > .kiro/harness/state/.gitignore

if [ $WITH_CI -eq 1 ]; then
  mkdir -p .github/workflows
  if [ -e .github/workflows/harness-verify.yml ]; then kept=$((kept+1))
  else cp "$KIT/ci/harness-verify.yml" .github/workflows/harness-verify.yml; copied=$((copied+1)); fi
fi

echo "INSTALL OK: $copied files written, $kept existing files kept, into $DEST/.kiro"
echo
echo "Next (KIRO SETUP PROTOCOL step 3): bash .kiro/harness/setup.sh detect"
echo
bash .kiro/harness/setup.sh detect
