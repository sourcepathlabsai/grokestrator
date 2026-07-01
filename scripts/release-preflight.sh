#!/usr/bin/env bash
#
# release-preflight.sh — verify local/CI credentials before a signed release.
#
# Checks everything needed for:
#   • Signed + notarized Mac DMG  (build-mac-release.sh)
#   • TestFlight iOS upload       (build-ios-release.sh)
#
# Usage:
#   scripts/release-preflight.sh           # check all
#   scripts/release-preflight.sh --mac     # Mac only
#   scripts/release-preflight.sh --ios     # iOS only

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/release.env"
CHECK_MAC=1
CHECK_IOS=1

for arg in "$@"; do
  case "$arg" in
    --mac) CHECK_IOS=0 ;;
    --ios) CHECK_MAC=0 ;;
    -h|--help)
      sed -n '2,12p' "$0"
      exit 0
      ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/apple-signing.sh"

log()  { printf '▸ %s\n' "$*"; }
ok()   { printf '✔ %s\n' "$*"; }
fail() { printf '✘ %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }

FAILURES=0
BUILD_DIR="${BUILD_DIR:-/tmp/grokestrator-preflight}"

log "Release preflight (team=${APPLE_TEAM_ID:-unset})"

if [[ -z "${APPLE_TEAM_ID:-}" ]]; then
  fail "APPLE_TEAM_ID not set — copy scripts/release.env.example → scripts/release.env"
else
  ok "APPLE_TEAM_ID=$APPLE_TEAM_ID"
fi

if [[ "$CHECK_MAC" -eq 1 ]]; then
  log "Mac signed + notarized DMG"
  if apple_notary_ready; then
    ok "Notarization credentials configured"
  else
    fail "Notarization not configured — set NOTARY_KEYCHAIN_PROFILE or App Store Connect API key trio"
  fi

  if [[ -n "${APPLE_CERTIFICATE_BASE64:-}" ]]; then
    ok "APPLE_CERTIFICATE_BASE64 set (CI import path)"
  elif security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
    ok "Developer ID Application certificate in keychain"
  else
    fail "No Developer ID Application cert — install in Keychain or set APPLE_CERTIFICATE_BASE64 for CI"
  fi
fi

if [[ "$CHECK_IOS" -eq 1 ]]; then
  log "iOS TestFlight upload"
  if [[ -n "${APP_STORE_CONNECT_KEY_ID:-}" && -n "${APP_STORE_CONNECT_ISSUER_ID:-}" ]]; then
    ok "App Store Connect API IDs configured"
    if apple_api_key_path >/dev/null 2>&1 || [[ -n "${APP_STORE_CONNECT_API_KEY_BASE64:-}" ]]; then
      ok "App Store Connect API .p8 key available"
    else
      fail "API .p8 missing — place AuthKey_\$KEY_ID.p8 in ~/.appstoreconnect/private_keys/ or set APP_STORE_CONNECT_API_KEY_BASE64"
    fi
  else
    fail "APP_STORE_CONNECT_KEY_ID + APP_STORE_CONNECT_ISSUER_ID not set"
  fi
fi

echo
if [[ "$FAILURES" -gt 0 ]]; then
  printf '✘ Preflight failed (%d issue(s)). Fix scripts/release.env before releasing.\n' "$FAILURES" >&2
  exit 1
fi
ok "Preflight passed — ready for scripts/build-release.sh"