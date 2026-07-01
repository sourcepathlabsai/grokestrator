#!/usr/bin/env bash
#
# certify-pr.sh — mandatory pre-merge certification for Grokestrator PRs.
#
# Runs the same checks as .github/workflows/pr-certify.yml so agents and CI
# agree on what "green" means before a slice lands on main.
#
# Steps:
#   1. Regenerate Grokestrator.xcodeproj from project.yml (xcodegen)
#   2. GrokestratorCore unit tests (swift test)
#   3. GrokestratorMac Debug build (macOS, no signing)
#   4. GrokestratoriOS Debug build (iOS Simulator, no signing)
#
# Usage:
#   scripts/certify-pr.sh              # full certification
#   scripts/certify-pr.sh --skip-tests # builds only (faster local iteration)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CORE_PKG="$REPO_ROOT/Packages/GrokestratorCore"
PROJECT="$REPO_ROOT/Grokestrator.xcodeproj"

SKIP_TESTS=0
for arg in "$@"; do
  case "$arg" in
    --skip-tests) SKIP_TESTS=1 ;;
    -h|--help)
      echo "Usage: scripts/certify-pr.sh [--skip-tests]"
      exit 0
      ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

log()  { printf '▸ %s\n' "$*"; }
ok()   { printf '✔ %s\n' "$*"; }
fail() { printf '✘ %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

require_cmd xcodegen
require_cmd xcodebuild
require_cmd swift

cd "$REPO_ROOT"

# ---------------------------------------------------------------------------
# 1. Regenerate xcodeproj
# ---------------------------------------------------------------------------

log "Regenerating $PROJECT from project.yml"
xcodegen generate >/dev/null
ok "Xcode project regenerated"

# ---------------------------------------------------------------------------
# 2. Core unit tests
# ---------------------------------------------------------------------------

if [[ "$SKIP_TESTS" -eq 0 ]]; then
  log "Running GrokestratorCore unit tests"
  (cd "$CORE_PKG" && swift test) >/dev/null
  ok "GrokestratorCore tests passed"
else
  log "Skipping GrokestratorCore tests (--skip-tests)"
fi

# ---------------------------------------------------------------------------
# 3. Mac build
# ---------------------------------------------------------------------------

log "Building GrokestratorMac (macOS Debug, no signing)"
xcodebuild \
  -project "$PROJECT" \
  -scheme GrokestratorMac \
  -configuration Debug \
  -destination 'platform=macOS' \
  build \
  CODE_SIGNING_ALLOWED=NO \
  >/dev/null
ok "GrokestratorMac build succeeded"

# ---------------------------------------------------------------------------
# 4. iOS Simulator build
# ---------------------------------------------------------------------------

log "Building GrokestratoriOS (iOS Simulator Debug, no signing)"
xcodebuild \
  -project "$PROJECT" \
  -scheme GrokestratoriOS \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  build \
  CODE_SIGNING_ALLOWED=NO \
  >/dev/null
ok "GrokestratoriOS build succeeded"

echo
ok "PR certification complete — safe to open/merge the PR"