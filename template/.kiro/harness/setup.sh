#!/usr/bin/env bash
# setup.sh — the ONLY way to configure the harness (agents may not edit harness files).
#
#   setup.sh detect                         what the project contains + current config
#   setup.sh set <KEY> <VALUE>              KEY: HARNESS_GRADLE_TASKS | HARNESS_AUTODETECT | HARNESS_BASE
#   setup.sh add-verifier <name> <quick|full> <command...>
#   setup.sh remove-verifier <name>
#   setup.sh baseline                       run verify --full on the current tree (must be green)
#   setup.sh selftest                       check the installation end to end
#   setup.sh lock                           freeze configuration (requires a passing selftest)
#   setup.sh unlock                         human only, from a real terminal
#   setup.sh status
. "$(dirname "$0")/lib.sh"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT" || exit 1
CONFIG="$HARNESS_DIR/config.sh"
LOCAL="$HARNESS_DIR/verifiers.local.sh"
LOCK="$STATE_DIR/locked"

die() { echo "SETUP ERROR: $1" >&2; exit 1; }
need_unlocked() { [ -f "$LOCK" ] && die "harness is locked. A human must run 'bash .kiro/harness/setup.sh unlock' in a terminal."; return 0; }
has() { command -v "$1" >/dev/null 2>&1; }

cmd_detect() {
  echo "== project root: $ROOT"
  echo "== git: $(in_git && echo "yes, branch $(git rev-parse --abbrev-ref HEAD 2>/dev/null)" || echo NO)"
  echo "== stack markers:"
  for f in package.json gradlew build.gradle build.gradle.kts settings.gradle settings.gradle.kts pom.xml \
           pyproject.toml setup.py requirements.txt go.mod Cargo.toml Package.swift Podfile pubspec.yaml; do
    [ -e "$f" ] && echo "   - $f"
  done
  if [ -f package.json ] && has node; then
    echo "== npm scripts: $(node -e "console.log(Object.keys(require('./package.json').scripts||{}).join(', '))" 2>/dev/null)"
  fi
  if [ -x ./gradlew ] || [ -f build.gradle ] || [ -f build.gradle.kts ]; then
    echo "== gradle plugins/tasks hinted in build files:"
    grep -h -o -E 'ktlint|detekt|spotless|com\.android\.(application|library)|kotlin\("android"\)|org\.jetbrains\.kotlin\.android|jacoco|kover|testDebugUnitTest|lintDebug' \
      $(find . -maxdepth 3 \( -name 'build.gradle*' -o -name 'libs.versions.toml' \) -not -path '*/build/*' 2>/dev/null) </dev/null 2>/dev/null | sort -u | sed 's/^/   - /'
    echo "   (Android suggestion: HARNESS_GRADLE_TASKS=\"<lint task> testDebugUnitTest\"; plain 'check' can be slow)"
  fi
  echo "== tools on PATH: $(for t in node npm java gradle mvn python3 ruff pytest go cargo swift xcodebuild gh kiro-cli; do has $t && printf '%s ' $t; done)"
  echo "== CI / build docs worth reading for the real commands:"
  ls -1 .github/workflows/*.y*ml bitrise.yml .gitlab-ci.yml Jenkinsfile azure-pipelines.yml Makefile justfile 2>/dev/null | sed 's/^/   - /'
  echo "== test dirs: $(find . -maxdepth 4 -type d \( -name test -o -name tests -o -name androidTest -o -name __tests__ \) -not -path '*/node_modules/*' -not -path '*/build/*' 2>/dev/null | head -n 8 | tr '\n' ' ')"
  echo "== steering present: $(ls .kiro/steering 2>/dev/null | tr '\n' ' ')"
  echo "== config.sh:"; [ -f "$CONFIG" ] && sed 's/^/   /' "$CONFIG" || echo "   (defaults)"
  echo "== local verifiers:"; [ -f "$LOCAL" ] && grep -E '^# verifier:' "$LOCAL" | sed 's/^# verifier:/   -/' || echo "   (none)"
  echo "== lock: $([ -f "$LOCK" ] && echo LOCKED || echo unlocked)"
}

cmd_set() {
  need_unlocked
  local k="${1:-}" v="${2-}"
  case "$k" in HARNESS_GRADLE_TASKS|HARNESS_AUTODETECT|HARNESS_BASE) ;; *) die "unknown key '$k'";; esac
  touch "$CONFIG"
  grep -v -E "^$k=" "$CONFIG" > "$CONFIG.tmp" || true
  printf '%s=%q\n' "$k" "$v" >> "$CONFIG.tmp"
  mv "$CONFIG.tmp" "$CONFIG"
  echo "set $k=$v"
}

cmd_add_verifier() {
  need_unlocked
  local name="${1:-}" mode="${2:-}"; shift 2 2>/dev/null || true
  [ -n "$name" ] && [ $# -gt 0 ] || die "usage: add-verifier <name> <quick|full> <command...>"
  case "$name" in *[!A-Za-z0-9_-]*) die "name may only contain letters, digits, - and _";; esac
  case "$mode" in quick|full) ;; *) die "mode must be quick or full";; esac
  cmd_remove_verifier "$name" >/dev/null
  local cmd="$*"
  local q; q="$(printf '%s' "$cmd" | sed "s/'/'\\\\''/g")"
  {
    echo "# verifier: $name ($mode) -> $cmd"
    if [ "$mode" = full ]; then
      echo "[ \"\$MODE\" = full ] && run $name sh -c '$q' # @$name"
    else
      echo "run $name sh -c '$q' # @$name"
    fi
  } >> "$LOCAL"
  echo "added verifier '$name' ($mode): $cmd"
}

cmd_remove_verifier() {
  need_unlocked
  [ -f "$LOCAL" ] || return 0
  grep -v -E "(^# verifier: $1 \(|# @$1\$)" "$LOCAL" > "$LOCAL.tmp" || true
  mv "$LOCAL.tmp" "$LOCAL"
  echo "removed verifier '$1'"
}

cmd_baseline() {
  echo "Running the full verifier set on the current tree (this is the baseline)..."
  local start end out rc
  start=$(date +%s)
  out="$(bash "$HARNESS_DIR/verify.sh" --full 2>&1)"; rc=$?
  end=$(date +%s)
  echo "$out"
  echo "baseline duration: $((end - start))s"
  echo "$((end - start))" > "$STATE_DIR/baseline-seconds"
  [ $rc -eq 0 ] || die "baseline is RED. Pre-existing failures make the harness meaningless; report them to the user instead of hiding them."
  case "$out" in *"no verifier configured"*) die "no verifier ran. Add one with add-verifier (read CI config for the real commands).";; esac
  echo "BASELINE GREEN"
}

CHECKS=0; FAILS=0
ok()  { CHECKS=$((CHECKS+1)); echo "  PASS  $1"; }
bad() { CHECKS=$((CHECKS+1)); FAILS=$((FAILS+1)); echo "  FAIL  $1"; }
json_ok() {
  if has node; then node -e "JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'))" "$1" 2>/dev/null
  elif has python3; then python3 -c "import json,sys;json.load(open(sys.argv[1]))" "$1" 2>/dev/null
  else return 0; fi
}

cmd_selftest() {
  echo "HARNESS SELFTEST"
  in_git && ok "project is a git repository" || bad "project is not a git repository"
  local f
  for f in lib.sh verify.sh gate.sh guard-shell.sh guard-write.sh trace.sh judge-packet.sh record-verdict.sh setup.sh ship.sh fleet.sh; do
    [ -f "$HARNESS_DIR/$f" ] || { bad "missing .kiro/harness/$f"; continue; }
    bash -n "$HARNESS_DIR/$f" 2>/dev/null || bad "syntax error in $f"
  done
  ok "harness scripts present and parse"
  for f in .kiro/hooks/spotify-harness.json .kiro/agents/harness-coder.json .kiro/agents/harness-judge.json; do
    [ -f "$f" ] && json_ok "$f" && ok "valid JSON: $f" || bad "missing or invalid JSON: $f"
  done
  for f in harness-principles.md harness-judge.md harness-spec-guide.md; do
    [ -f ".kiro/steering/$f" ] || bad "missing steering $f"
  done
  ok "harness steering present"
  local miss=""
  for f in product.md tech.md structure.md golden-paths.md; do [ -f ".kiro/steering/$f" ] || miss="$miss $f"; done
  [ -z "$miss" ] && ok "project steering present (product, tech, structure, golden-paths)" || bad "project steering missing:$miss"
  git check-ignore -q "$STATE_DIR/probe" 2>/dev/null && ok "harness state is git-ignored" || bad "harness state is NOT git-ignored"

  local P='{"session_id":"selftest","tool_input":{"command":"%s"}}'
  printf "$P" "git push --force origin main" | bash "$HARNESS_DIR/guard-shell.sh" 2>/dev/null && bad "guard allowed a force push" || ok "guard blocks force push"
  printf "$P" "git status" | bash "$HARNESS_DIR/guard-shell.sh" 2>/dev/null && ok "guard allows harmless commands" || bad "guard blocked 'git status'"
  printf "$P" "sed -i s/a/b/ .kiro/harness/verify.sh" | bash "$HARNESS_DIR/guard-shell.sh" 2>/dev/null && bad "guard allowed a shell edit of the harness" || ok "guard blocks shell edits of the harness"
  printf "$P" "bash .kiro/harness/ship.sh" | bash "$HARNESS_DIR/guard-shell.sh" 2>/dev/null && bad "guard allowed the agent to ship" || ok "guard blocks agent shipping"
  printf '{"session_id":"selftest","tool_input":{"path":".kiro/hooks/x.json"}}' | bash "$HARNESS_DIR/guard-write.sh" 2>/dev/null \
    && bad "write guard allowed editing hooks" || ok "write guard protects the harness"
  printf '{"tool_input":{"command":"ls"}}' | bash "$HARNESS_DIR/trace.sh" >/dev/null 2>&1 && ok "trace hook runs" || bad "trace hook failed"

  if [ -f "$STATE_DIR/last-verify" ] && [ "$(cut -d' ' -f1 "$STATE_DIR/last-verify")" = PASS ]; then
    ok "baseline verify is green ($(cat "$STATE_DIR/baseline-seconds" 2>/dev/null || echo '?')s)"
  else
    bad "no green baseline yet (run: bash .kiro/harness/setup.sh baseline)"
  fi
  [ -f ".kiro/specs/_example-simpledateformat-to-javatime/requirements.md" ] && ok "example spec present" || bad "example spec missing"

  echo "HARNESS SELFTEST: $([ $FAILS -eq 0 ] && echo PASS || echo FAIL) ($((CHECKS - FAILS))/$CHECKS checks)"
  [ $FAILS -eq 0 ]
}

cmd_lock() {
  cmd_selftest >/dev/null || die "selftest is failing; run 'setup.sh selftest' and fix it before locking."
  echo "$(now)" > "$LOCK"
  echo "HARNESS LOCKED: configuration is frozen. Agents can no longer change verifiers."
}

cmd_unlock() {
  [ -t 0 ] && [ -t 1 ] || die "unlock must be run by a human in a real terminal."
  printf 'Unlock harness configuration? Agents will be able to change verifiers. [y/N] '
  read -r a; [ "$a" = y ] || [ "$a" = Y ] || die "cancelled"
  rm -f "$LOCK"; echo "unlocked"
}

cmd_status() {
  echo "lock:        $([ -f "$LOCK" ] && echo "LOCKED since $(cat "$LOCK")" || echo unlocked)"
  echo "last verify: $(cat "$STATE_DIR/last-verify" 2>/dev/null || echo none)"
  echo "verdict:     $(cat "$STATE_DIR/verdict" 2>/dev/null || echo none)"
  echo "tree now:    $(tree_hash)"
  bash "$HARNESS_DIR/gate.sh" 2>&1 | sed 's/^/gate:        /'
}

sub="${1:-status}"; [ $# -gt 0 ] && shift
case "$sub" in
  detect) cmd_detect ;;
  set) cmd_set "$@" ;;
  add-verifier) cmd_add_verifier "$@" ;;
  remove-verifier) cmd_remove_verifier "$@" ;;
  baseline) cmd_baseline ;;
  selftest) cmd_selftest ;;
  lock) cmd_lock ;;
  unlock) cmd_unlock ;;
  status) cmd_status ;;
  *) sed -n '2,12p' "$0"; exit 1 ;;
esac
