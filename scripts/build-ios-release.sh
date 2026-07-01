#!/usr/bin/env bash
#
# build-ios-release.sh — build a release Grokestrator iOS app and,
# optionally, upload it to App Store Connect for TestFlight distribution.
#
# Two modes, selected automatically by whether the signing env vars are set:
#
#   1. SIGNED (production): If APPLE_TEAM_ID + APP_STORE_CONNECT_KEY_ID +
#      APP_STORE_CONNECT_ISSUER_ID are set, the script:
#          - archives Release for generic iOS
#          - exports an .ipa with method=app-store-connect
#          - uploads to App Store Connect via `xcrun altool`
#      A TestFlight build appears under "Builds" within ~5–15 min after
#      Apple's automated processing finishes.
#
#   2. DRY-RUN (no certs yet): If those env vars aren't set, the script
#      compiles for the iOS Simulator instead — no signing required.
#      This validates the entire build (Swift compilation, asset catalog,
#      privacy manifest bundling, etc.) without needing iOS distribution
#      certs or an App Store Connect API key. Output: a .app in
#      DerivedData; no .ipa, no upload.
#
# Configuration: copy scripts/release.env.example to scripts/release.env
# and fill in the values.
#
# Usage:
#   scripts/build-ios-release.sh                    # release.env-driven
#   scripts/build-ios-release.sh --version 0.2.0    # override version
#   scripts/build-ios-release.sh --clean            # nuke build/ first

set -euo pipefail

# ---------------------------------------------------------------------------
# Paths + defaults
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build/ios-release"
ARCHIVE_PATH="$BUILD_DIR/Grokestrator.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
ENV_FILE="$SCRIPT_DIR/release.env"

SCHEME="GrokestratoriOS"
CONFIGURATION="Release"
PROJECT="Grokestrator.xcodeproj"

CLEAN=0
VERSION_OVERRIDE=""

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

# ---------------------------------------------------------------------------
# CLI parsing
# ---------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)   VERSION_OVERRIDE="$2"; shift 2 ;;
    --clean)     CLEAN=1; shift ;;
    -h|--help)
      sed -n '2,30p' "$0"; exit 0 ;;
    *)
      echo "error: unknown flag: $1" >&2
      exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log()  { printf '\033[1;36m▶\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required tool not found: $1"
}

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/apple-signing.sh"

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

cd "$REPO_ROOT"

require_cmd xcodebuild
require_cmd xcodegen

# Materialize CI API key before upload.
if [[ -n "${APP_STORE_CONNECT_API_KEY_BASE64:-}" ]]; then
  export APP_STORE_CONNECT_API_KEY_PATH="$(apple_materialize_api_key)"
fi
apple_import_certificate_if_needed

# Decide mode.
SIGNED_MODE=0
if [[ -n "${APPLE_TEAM_ID:-}"               \
   && -n "${APP_STORE_CONNECT_KEY_ID:-}"    \
   && -n "${APP_STORE_CONNECT_ISSUER_ID:-}" ]] \
   && apple_api_key_path >/dev/null 2>&1; then
  SIGNED_MODE=1
fi

# Marketing version — CLI override, env, or project.yml.
if [[ -n "$VERSION_OVERRIDE" ]]; then
  VERSION="$VERSION_OVERRIDE"
elif [[ -n "${MARKETING_VERSION:-}" ]]; then
  VERSION="$MARKETING_VERSION"
else
  VERSION="$(grep -E '^[[:space:]]+MARKETING_VERSION:' project.yml | head -1 | sed 's/.*"\(.*\)".*/\1/')"
fi
[[ -n "$VERSION" ]] || die "could not determine MARKETING_VERSION"

if [[ "$SIGNED_MODE" -eq 1 ]]; then
  log "Build mode: SIGNED + UPLOAD to TestFlight  (team=$APPLE_TEAM_ID, version=$VERSION)"
else
  warn "Build mode: DRY-RUN  (no signing env vars set)"
  warn "Will compile for iOS Simulator only; no .ipa, no upload."
fi

# ---------------------------------------------------------------------------
# Clean
# ---------------------------------------------------------------------------

if [[ $CLEAN -eq 1 ]]; then
  log "Cleaning $BUILD_DIR"
  rm -rf "$BUILD_DIR"
fi
mkdir -p "$BUILD_DIR"

# ---------------------------------------------------------------------------
# Regenerate xcodeproj
# ---------------------------------------------------------------------------

log "Regenerating $PROJECT from project.yml"
xcodegen generate >/dev/null

# ---------------------------------------------------------------------------
# DRY-RUN path: just compile for simulator
# ---------------------------------------------------------------------------

if [[ "$SIGNED_MODE" -eq 0 ]]; then
  log "Building $SCHEME for iOS Simulator (no signing required)"
  xcodebuild \
    -project "$PROJECT" \
    -scheme  "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination 'generic/platform=iOS Simulator' \
    build \
    >/dev/null
  ok "iOS Simulator build succeeded"

  # Confirm the privacy manifest got bundled — this is the single most
  # common preflight bug; better to fail loud here than at App Store
  # submission time.
  APP_IN_DD="$(find ~/Library/Developer/Xcode/DerivedData/Grokestrator-*/Build/Products/Release-iphonesimulator/Grokestrator.app -maxdepth 0 2>/dev/null | head -1)"
  if [[ -n "$APP_IN_DD" && -f "$APP_IN_DD/PrivacyInfo.xcprivacy" ]]; then
    ok "PrivacyInfo.xcprivacy bundled at $APP_IN_DD/PrivacyInfo.xcprivacy"
  elif [[ -n "$APP_IN_DD" ]]; then
    warn "PrivacyInfo.xcprivacy NOT found in built bundle — Apple will reject."
  fi

  echo
  echo "DRY-RUN complete. Pipeline structure verified."
  echo "To produce a real TestFlight build, set in $ENV_FILE:"
  echo "    APPLE_TEAM_ID"
  echo "    APP_STORE_CONNECT_KEY_ID"
  echo "    APP_STORE_CONNECT_ISSUER_ID"
  echo "and place the matching .p8 key at:"
  echo "    ~/.appstoreconnect/private_keys/AuthKey_\$APP_STORE_CONNECT_KEY_ID.p8"
  exit 0
fi

# ---------------------------------------------------------------------------
# SIGNED path: archive + export + upload
# ---------------------------------------------------------------------------

log "Archiving $SCHEME ($CONFIGURATION) for generic iOS"

xcodebuild \
  -project "$PROJECT" \
  -scheme  "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE_PATH" \
  archive \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
  >/dev/null

ok "Archive at $ARCHIVE_PATH"

# ---------------------------------------------------------------------------
# Export .ipa with app-store-connect method
# ---------------------------------------------------------------------------

log "Exporting .ipa (method=app-store-connect)"

EXPORT_OPTIONS_PLIST="$BUILD_DIR/ExportOptions.plist"
cat > "$EXPORT_OPTIONS_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>teamID</key><string>$APPLE_TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>destination</key><string>export</string>
</dict>
</plist>
EOF

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath  "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" \
  >/dev/null

IPA_PATH="$EXPORT_DIR/Grokestrator.ipa"
[[ -f "$IPA_PATH" ]] || die "expected .ipa not found at $IPA_PATH"
ok "Exported $IPA_PATH"

# ---------------------------------------------------------------------------
# Upload to App Store Connect (TestFlight)
# ---------------------------------------------------------------------------

log "Uploading to App Store Connect (this may take several minutes)"

API_KEY_PATH="$(apple_api_key_path)"
# altool discovers keys only in ~/.appstoreconnect/private_keys (or similar).
ASC_KEY_DIR="$HOME/.appstoreconnect/private_keys"
mkdir -p "$ASC_KEY_DIR"
if [[ "$API_KEY_PATH" != "$ASC_KEY_DIR/AuthKey_${APP_STORE_CONNECT_KEY_ID}.p8" ]]; then
  cp "$API_KEY_PATH" "$ASC_KEY_DIR/AuthKey_${APP_STORE_CONNECT_KEY_ID}.p8"
  chmod 600 "$ASC_KEY_DIR/AuthKey_${APP_STORE_CONNECT_KEY_ID}.p8"
fi

xcrun altool --upload-app \
  --type ios \
  --file "$IPA_PATH" \
  --apiKey "$APP_STORE_CONNECT_KEY_ID" \
  --apiIssuer "$APP_STORE_CONNECT_ISSUER_ID"

ok "Upload accepted"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

echo
ok "TestFlight upload complete"
echo "    $IPA_PATH"
echo
echo "Apple's automated processing usually finishes within 5–15 minutes."
echo "Visit appstoreconnect.apple.com → My Apps → Grokestrator → TestFlight"
echo "to see the build appear, then submit for Beta App Review."
