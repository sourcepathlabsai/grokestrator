#!/usr/bin/env bash
#
# build-mac-release.sh — build a release Grokestrator.app, optionally
# sign + notarize it, and package it as a distributable DMG.
#
# Two modes, selected automatically by whether the signing env vars are set:
#
#   1. SIGNED (production): If APPLE_TEAM_ID + NOTARY_KEYCHAIN_PROFILE are
#      set, the script signs with Developer ID Application, submits the
#      DMG to Apple's notary service, waits for approval, and staples the
#      ticket. The output DMG is fully Gatekeeper-acceptable and can be
#      handed to end users.
#
#   2. UNSIGNED (no cert yet): If the env vars are not set (or --unsigned is
#      passed), the script ad-hoc-signs the .app and packages a real,
#      distributable "Grokestrator-X.Y.Z-unsigned.dmg" with first-launch
#      install instructions bundled inside. This is a genuine Mac-to-Mac
#      release — recipients just clear Gatekeeper once (see the bundled
#      "How to open Grokestrator.txt"). It is NOT notarized, so the first
#      launch shows a Gatekeeper warning that must be overridden manually.
#
# Configuration: copy scripts/release.env.example to scripts/release.env
# and fill in the values for the SIGNED mode. release.env is gitignored.
#
# Usage:
#   scripts/build-mac-release.sh                    # release.env-driven
#   scripts/build-mac-release.sh --version 0.2.0    # override version
#   scripts/build-mac-release.sh --unsigned         # force unsigned even if creds set
#   scripts/build-mac-release.sh --clean            # nuke build/ first

set -euo pipefail

# ---------------------------------------------------------------------------
# Paths + defaults
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build/mac-release"
ARCHIVE_PATH="$BUILD_DIR/Grokestrator.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
DMG_STAGE_DIR="$BUILD_DIR/dmg-stage"
ENV_FILE="$SCRIPT_DIR/release.env"

SCHEME="GrokestratorMac"
CONFIGURATION="Release"
PROJECT="Grokestrator.xcodeproj"

CLEAN=0
VERSION_OVERRIDE=""
FORCE_UNSIGNED=0

# Pull credentials/team from release.env if present. Anything already set in
# the shell env wins (CI override).
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
    --unsigned)  FORCE_UNSIGNED=1; shift ;;
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

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

cd "$REPO_ROOT"

require_cmd xcodebuild
require_cmd xcodegen
require_cmd hdiutil
require_cmd codesign
require_cmd plutil

# Decide mode. Signing creds trigger SIGNED; --unsigned forces UNSIGNED even
# when creds are present (handy for a quick public build before notarization).
SIGNED_MODE=0
if [[ -n "${APPLE_TEAM_ID:-}" && -n "${NOTARY_KEYCHAIN_PROFILE:-}" && "$FORCE_UNSIGNED" -eq 0 ]]; then
  SIGNED_MODE=1
fi

# Marketing version — from CLI override, env, or project.yml.
if [[ -n "$VERSION_OVERRIDE" ]]; then
  VERSION="$VERSION_OVERRIDE"
elif [[ -n "${MARKETING_VERSION:-}" ]]; then
  VERSION="$MARKETING_VERSION"
else
  VERSION="$(grep -E '^[[:space:]]+MARKETING_VERSION:' project.yml | head -1 | sed 's/.*"\(.*\)".*/\1/')"
fi
[[ -n "$VERSION" ]] || die "could not determine MARKETING_VERSION"

if [[ "$SIGNED_MODE" -eq 1 ]]; then
  DMG_NAME="Grokestrator-$VERSION.dmg"
  log "Build mode: SIGNED + NOTARIZED  (team=$APPLE_TEAM_ID, version=$VERSION)"
else
  DMG_NAME="Grokestrator-$VERSION-unsigned.dmg"
  warn "Build mode: UNSIGNED  (no Developer ID / notarization)"
  warn "Distributable Mac-to-Mac, but the first launch needs a one-time"
  warn "Gatekeeper override — install steps are bundled in the DMG."
fi

# ---------------------------------------------------------------------------
# Clean
# ---------------------------------------------------------------------------

if [[ $CLEAN -eq 1 ]]; then
  log "Cleaning $BUILD_DIR"
  rm -rf "$BUILD_DIR"
fi
mkdir -p "$BUILD_DIR" "$EXPORT_DIR" "$DMG_STAGE_DIR"

# ---------------------------------------------------------------------------
# Regenerate xcodeproj from project.yml
# ---------------------------------------------------------------------------

log "Regenerating $PROJECT from project.yml"
xcodegen generate >/dev/null

# ---------------------------------------------------------------------------
# Archive
# ---------------------------------------------------------------------------

log "Archiving $SCHEME ($CONFIGURATION)"

ARCHIVE_ARGS=(
  -project "$PROJECT"
  -scheme  "$SCHEME"
  -configuration "$CONFIGURATION"
  -destination "generic/platform=macOS"
  -archivePath "$ARCHIVE_PATH"
  archive
  CODE_SIGN_STYLE=Manual
)

if [[ "$SIGNED_MODE" -eq 1 ]]; then
  ARCHIVE_ARGS+=(
    DEVELOPMENT_TEAM="$APPLE_TEAM_ID"
    CODE_SIGN_IDENTITY="Developer ID Application"
  )
else
  ARCHIVE_ARGS+=(
    CODE_SIGN_IDENTITY="-"   # ad-hoc
    OTHER_CODE_SIGN_FLAGS="--timestamp=none"
  )
fi

xcodebuild "${ARCHIVE_ARGS[@]}" \
  | xcbeautify --quiet 2>/dev/null \
  || xcodebuild "${ARCHIVE_ARGS[@]}" >/dev/null
# (Re-runs without xcbeautify if not installed; we don't want a missing
# pretty-printer to fail the build.)

ok "Archive at $ARCHIVE_PATH"

# ---------------------------------------------------------------------------
# Export .app from archive
# ---------------------------------------------------------------------------

log "Exporting .app from archive"

EXPORT_OPTIONS_PLIST="$BUILD_DIR/ExportOptions.plist"
if [[ "$SIGNED_MODE" -eq 1 ]]; then
  cat > "$EXPORT_OPTIONS_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$APPLE_TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
  <key>destination</key><string>export</string>
</dict>
</plist>
EOF
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath  "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" \
    >/dev/null
else
  # No -exportArchive for ad-hoc; just copy the .app out of the archive.
  cp -R "$ARCHIVE_PATH/Products/Applications/Grokestrator.app" "$EXPORT_DIR/"
fi

APP_PATH="$EXPORT_DIR/Grokestrator.app"
[[ -d "$APP_PATH" ]] || die "expected .app not found at $APP_PATH"
ok "Exported $APP_PATH"

# ---------------------------------------------------------------------------
# Verify codesign + hardened runtime
# ---------------------------------------------------------------------------

log "Verifying code signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH" 2>&1 | tail -5

if [[ "$SIGNED_MODE" -eq 1 ]]; then
  if ! codesign --display --verbose=2 "$APP_PATH" 2>&1 | grep -q 'flags=.*runtime'; then
    die "Hardened Runtime is NOT enabled on the signed app — Apple will reject notarization."
  fi
  ok "Hardened Runtime confirmed"
fi

# ---------------------------------------------------------------------------
# Build DMG
# ---------------------------------------------------------------------------

log "Packaging DMG"

rm -rf "$DMG_STAGE_DIR"
mkdir -p "$DMG_STAGE_DIR"
cp -R "$APP_PATH" "$DMG_STAGE_DIR/"
ln -s /Applications "$DMG_STAGE_DIR/Applications"

# Unsigned builds: bundle first-launch instructions so recipients aren't
# stranded at the Gatekeeper warning. (Signed+notarized builds open cleanly,
# so no note is needed there.)
if [[ "$SIGNED_MODE" -ne 1 ]]; then
  cat > "$DMG_STAGE_DIR/How to open Grokestrator.txt" <<'EOF'
Opening Grokestrator — first launch only
=========================================

Grokestrator isn't notarized by Apple yet, so macOS Gatekeeper blocks the
very first launch with a scary-looking warning. This is expected for a
direct (non–App Store) download. You only have to do this once.

Step 1 — Install
  Drag Grokestrator onto the Applications folder in this window.

Step 2 — Open it once via Settings (macOS 13–15)
  1. Double-click Grokestrator in Applications. macOS will refuse and say it
     "cannot be opened because Apple cannot check it for malicious software."
     Click "Done."
  2. Open  System Settings → Privacy & Security.
  3. Scroll down. You'll see: "Grokestrator was blocked to protect your Mac."
     Click  "Open Anyway."
  4. Confirm with Touch ID / your password, then click "Open" in the dialog.
  Grokestrator now launches normally every time.

Faster, if you're comfortable in Terminal
  Run this once, then open the app normally:
     xattr -dr com.apple.quarantine /Applications/Grokestrator.app

Why the warning?
  It just means the app hasn't been through Apple's paid notarization
  service yet — not that anything is wrong. A notarized build (no warning,
  one-click open) is coming.

— SourcePath Labs
EOF
  ok "Bundled first-launch instructions into the DMG"
fi

DMG_PATH="$BUILD_DIR/$DMG_NAME"
rm -f "$DMG_PATH"
hdiutil create \
  -volname "Grokestrator" \
  -srcfolder "$DMG_STAGE_DIR" \
  -ov -format UDZO \
  "$DMG_PATH" \
  >/dev/null

ok "DMG built: $DMG_PATH"

# ---------------------------------------------------------------------------
# Notarize + staple (signed mode only)
# ---------------------------------------------------------------------------

if [[ "$SIGNED_MODE" -eq 1 ]]; then
  log "Submitting to Apple notary service (may take several minutes)"
  xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
    --wait
  ok "Notarization accepted"

  log "Stapling notary ticket"
  xcrun stapler staple "$DMG_PATH"
  ok "Stapled"

  log "Gatekeeper acceptance check"
  spctl --assess --type open --context context:primary-signature -vv "$DMG_PATH" 2>&1 | tail -3
  ok "Gatekeeper accepts the DMG"
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

echo
ok "Release build complete"
echo "    $DMG_PATH"
echo
if [[ "$SIGNED_MODE" -eq 1 ]]; then
  echo "Distribute via:  upload to GitHub Releases, sourcepathlabs.ai, etc."
else
  echo "UNSIGNED release — ready to share Mac-to-Mac (GitHub Releases, direct link)."
  echo "Recipients clear Gatekeeper once; steps are in the DMG's"
  echo "\"How to open Grokestrator.txt\". For a one-click, no-warning install,"
  echo "set APPLE_TEAM_ID + NOTARY_KEYCHAIN_PROFILE in $ENV_FILE to notarize."
fi
