#!/usr/bin/env bash
#
# build-release.sh — cut a full Grokestrator release (Mac + optional iOS).
#
#   1. scripts/release-preflight.sh
#   2. scripts/build-mac-release.sh   (signed+notarized when creds set)
#   3. scripts/build-ios-release.sh   (TestFlight upload when creds set)
#
# Usage:
#   scripts/build-release.sh
#   scripts/build-release.sh --version 0.3.5 --clean
#   scripts/build-release.sh --mac-only
#   scripts/build-release.sh --unsigned   # force unsigned Mac; skip iOS upload

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

MAC_ONLY=0
ARGS=()
PASSTHROUGH=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mac-only) MAC_ONLY=1; shift ;;
    --version|--clean) PASSTHROUGH+=("$1" "$2"); shift 2 ;;
    --unsigned) PASSTHROUGH+=("$1"); shift ;;
    -h|--help)
      sed -n '2,14p' "$0"
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

cd "$REPO_ROOT"

if [[ " ${PASSTHROUGH[*]} " != *" --unsigned "* ]]; then
  PREFLIGHT_ARGS=()
  [[ "$MAC_ONLY" -eq 1 ]] && PREFLIGHT_ARGS+=(--mac)
  scripts/release-preflight.sh "${PREFLIGHT_ARGS[@]}"
fi

scripts/build-mac-release.sh "${PASSTHROUGH[@]}"

if [[ "$MAC_ONLY" -eq 0 && " ${PASSTHROUGH[*]} " != *" --unsigned "* ]]; then
  scripts/build-ios-release.sh "${PASSTHROUGH[@]}"
fi

echo
printf '✔ Release pipeline complete\n'