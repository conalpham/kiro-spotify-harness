#!/usr/bin/env bash
# verify.sh [--quick|--full]
# The single "verify tool" the agent is allowed to know about (Spotify Honk, part 3):
#  - verifiers activate automatically from project contents (package.json, gradlew, pom.xml, ...)
#  - the agent never sees build-system details, only a short OK or the key error lines
#  - --quick : format/lint only (runs on every file save)
#  - --full  : everything (runs on agent stop, required by the ship gate)
# Project-specific verifiers: .kiro/harness/verifiers.local.sh, managed by `setup.sh add-verifier`.
set -u
. "$(dirname "$0")/lib.sh"

MODE=full
[ "${1:-}" = "--quick" ] && MODE=quick
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT" || exit 1

LOG="$STATE_DIR/verify-last.log"
: > "$LOG"
HASH="$(tree_hash)"
# Settings written by `setup.sh set` (HARNESS_GRADLE_TASKS, HARNESS_AUTODETECT, HARNESS_BASE)
[ -f "$HARNESS_DIR/config.sh" ] && . "$HARNESS_DIR/config.sh"

# Nothing changed since the last full pass: answer from cache (keeps the Stop hook cheap).
if [ "$MODE" = full ] && [ -f "$STATE_DIR/last-verify" ]; then
  read -r st h _ < "$STATE_DIR/last-verify"
  if [ "$st" = PASS ] && [ "$h" = "$HASH" ]; then
    echo "VERIFY OK (cached: no changes since last full pass)"
    exit 0
  fi
fi

RAN=""
FAILED=""
has() { command -v "$1" >/dev/null 2>&1; }
run() { # run <name> <cmd...>
  local name="$1"; shift
  RAN="$RAN $name"
  echo "===== [$name] $*" >> "$LOG"
  if ! "$@" >> "$LOG" 2>&1; then FAILED="$FAILED $name"; fi
}
npm_script() { [ -f package.json ] && node -e "const s=(require('./package.json').scripts||{});process.exit(s['$1']?0:1)" 2>/dev/null; }

if [ "${HARNESS_AUTODETECT:-1}" = 1 ]; then
  # ---- Node / TypeScript -----------------------------------------------------
  if [ -f package.json ] && has npm; then
    npm_script lint && run node-lint npm run -s lint
    if [ "$MODE" = full ]; then
      npm_script typecheck && run node-typecheck npm run -s typecheck
      npm_script build && run node-build npm run -s build
      npm_script test && run node-test env CI=true npm test -s
    fi
  fi

  # ---- JVM: Gradle (Android / Kotlin) and Maven ------------------------------
  GRADLE=""
  [ -x ./gradlew ] && GRADLE=./gradlew
  [ -z "$GRADLE" ] && { [ -f build.gradle ] || [ -f build.gradle.kts ]; } && has gradle && GRADLE=gradle
  if [ -n "$GRADLE" ] && [ "$MODE" = full ]; then
    # shellcheck disable=SC2086
    run gradle "$GRADLE" ${HARNESS_GRADLE_TASKS:-check} --console=plain -q
  fi
  if [ -f pom.xml ] && [ "$MODE" = full ]; then
    MVN=mvn; [ -x ./mvnw ] && MVN=./mvnw
    { has "$MVN" || [ -x "$MVN" ]; } && run maven "$MVN" -q -B verify
  fi

  # ---- Python ----------------------------------------------------------------
  if [ -f pyproject.toml ] || [ -f setup.py ] || [ -f requirements.txt ]; then
    has ruff && run py-ruff ruff check .
    if [ "$MODE" = full ] && has pytest && { [ -d tests ] || [ -d test ]; }; then
      run py-test pytest -q
    fi
  fi

  # ---- Go --------------------------------------------------------------------
  if [ -f go.mod ] && has go; then
    run go-fmt sh -c 'out=$(gofmt -l .); [ -z "$out" ] || { echo "gofmt needed: $out"; exit 1; }'
    if [ "$MODE" = full ]; then run go-vet go vet ./...; run go-test go test ./...; fi
  fi

  # ---- Rust ------------------------------------------------------------------
  if [ -f Cargo.toml ] && has cargo; then
    run rust-fmt cargo fmt --check
    if [ "$MODE" = full ]; then run rust-clippy cargo clippy -q -- -D warnings; run rust-test cargo test -q; fi
  fi
fi

# ---- Project-specific verifiers ---------------------------------------------
[ -f "$HARNESS_DIR/verifiers.local.sh" ] && . "$HARNESS_DIR/verifiers.local.sh"

# ---- Result -----------------------------------------------------------------
if [ -z "$RAN" ]; then
  [ "$MODE" = full ] && echo "NONE $HASH $(now)" > "$STATE_DIR/last-verify"
  echo "VERIFY WARNING: no verifier configured for this project. Nothing was checked. (bash .kiro/harness/setup.sh detect)"
  exit 0
fi

if [ -z "$FAILED" ]; then
  [ "$MODE" = full ] && echo "PASS $HASH $(now)" > "$STATE_DIR/last-verify"
  echo "VERIFY OK ($MODE:$RAN)"
  exit 0
fi

[ "$MODE" = full ] && echo "FAIL $HASH $(now)" > "$STATE_DIR/last-verify"
{
  echo "VERIFY FAILED ($MODE):$FAILED"
  echo "--- key lines (full log: .kiro/harness/state/verify-last.log) ---"
  grep -E -i '(error|fail|exception|assert|expected|panic|cannot find|not found|undefined|unresolved|✗|✕)' "$LOG" \
    | grep -v -E '^[[:space:]]+at ' | head -n 40
} >&2
exit 1
