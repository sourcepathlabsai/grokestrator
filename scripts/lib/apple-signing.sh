#!/usr/bin/env bash
# Shared Apple signing helpers for release scripts and CI.
# Source from build-mac-release.sh / build-ios-release.sh — do not execute directly.

# Returns 0 when notarization credentials are configured (keychain profile or API key).
apple_notary_ready() {
  if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
    return 0
  fi
  if [[ -n "${APP_STORE_CONNECT_KEY_ID:-}" && -n "${APP_STORE_CONNECT_ISSUER_ID:-}" ]]; then
    local key_path
    key_path="$(apple_api_key_path)" || return 1
    [[ -f "$key_path" ]]
    return $?
  fi
  return 1
}

# Path to the App Store Connect API .p8 key.
apple_api_key_path() {
  if [[ -n "${APP_STORE_CONNECT_API_KEY_PATH:-}" && -f "${APP_STORE_CONNECT_API_KEY_PATH}" ]]; then
    echo "${APP_STORE_CONNECT_API_KEY_PATH}"
    return 0
  fi
  if [[ -n "${APP_STORE_CONNECT_KEY_ID:-}" ]]; then
    local default="$HOME/.appstoreconnect/private_keys/AuthKey_${APP_STORE_CONNECT_KEY_ID}.p8"
    if [[ -f "$default" ]]; then
      echo "$default"
      return 0
    fi
  fi
  return 1
}

# Import a base64-encoded .p12 into a temporary keychain (CI). No-op when unset.
apple_import_certificate_if_needed() {
  if [[ -z "${APPLE_CERTIFICATE_BASE64:-}" ]]; then
    return 0
  fi
  [[ -n "${APPLE_CERTIFICATE_PASSWORD:-}" ]] || die "APPLE_CERTIFICATE_PASSWORD required with APPLE_CERTIFICATE_BASE64"

  local p12="$BUILD_DIR/signing-cert.p12"
  local keychain="${APPLE_KEYCHAIN_PATH:-$BUILD_DIR/signing.keychain-db}"
  local keychain_password="${APPLE_KEYCHAIN_PASSWORD:-}"

  mkdir -p "$(dirname "$p12")"
  echo "$APPLE_CERTIFICATE_BASE64" | base64 --decode > "$p12"

  security create-keychain -p "$keychain_password" "$keychain"
  security set-keychain-settings -lut 21600 "$keychain"
  security unlock-keychain -p "$keychain_password" "$keychain"
  security import "$p12" -k "$keychain" -P "$APPLE_CERTIFICATE_PASSWORD" \
    -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/xcodebuild
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain"
  security list-keychains -d user -s "$keychain" $(security list-keychains -d user | tr -d '"')
  ok "Imported signing certificate into $keychain"
}

# Submit a DMG/ZIP to Apple's notary service and wait for approval.
apple_notarize() {
  local artifact="$1"
  if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
    xcrun notarytool submit "$artifact" \
      --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
      --wait
    return $?
  fi

  local key_path
  key_path="$(apple_api_key_path)" || die "App Store Connect API key not found for notarization"
  xcrun notarytool submit "$artifact" \
    --key "$key_path" \
    --key-id "$APP_STORE_CONNECT_KEY_ID" \
    --issuer "$APP_STORE_CONNECT_ISSUER_ID" \
    --wait
}

# Write API key to disk from base64 env (CI). Returns path via stdout.
apple_materialize_api_key() {
  if [[ -z "${APP_STORE_CONNECT_API_KEY_BASE64:-}" ]]; then
    apple_api_key_path
    return $?
  fi
  [[ -n "${APP_STORE_CONNECT_KEY_ID:-}" ]] || die "APP_STORE_CONNECT_KEY_ID required with APP_STORE_CONNECT_API_KEY_BASE64"
  local dir="$BUILD_DIR/appstoreconnect-keys"
  local path="$dir/AuthKey_${APP_STORE_CONNECT_KEY_ID}.p8"
  mkdir -p "$dir"
  echo "$APP_STORE_CONNECT_API_KEY_BASE64" | base64 --decode > "$path"
  chmod 600 "$path"
  echo "$path"
}