#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Hokuto Takemiya

shitate_require_apple_credentials() {
  local variable=
  for variable in \
    SHITATE_CERTIFICATE_P12_BASE64 \
    SHITATE_CERTIFICATE_PASSWORD \
    SHITATE_KEYCHAIN_PASSWORD \
    SHITATE_NOTARY_ISSUER_ID \
    SHITATE_NOTARY_KEY_BASE64 \
    SHITATE_NOTARY_KEY_ID \
    SHITATE_SIGNING_IDENTITY; do
    if [[ -z ${!variable-} ]]; then
      printf 'required Apple credential variable is missing: %s\n' "$variable" >&2
      return 1
    fi
  done
}

shitate_prepare_apple_credentials() {
  local credential_root=$1
  shitate_require_apple_credentials || return 1
  install -d -m 700 "$credential_root"

  SHITATE_CREDENTIAL_KEYCHAIN="$credential_root/shitate-signing.keychain-db"
  SHITATE_CREDENTIAL_CERTIFICATE="$credential_root/shitate-signing.p12"
  SHITATE_CREDENTIAL_CERTIFICATE_PEM="$credential_root/shitate-signing.pem"
  export SHITATE_NOTARY_KEY_PATH="$credential_root/AuthKey_$SHITATE_NOTARY_KEY_ID.p8"
  SHITATE_CREDENTIAL_ORIGINAL_KEYCHAIN=$(
    security default-keychain -d user 2>/dev/null |
      sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
        -e 's/^"//' -e 's/"$//' || true
  )

  umask 077
  printf '%s' "$SHITATE_CERTIFICATE_P12_BASE64" |
    base64 --decode >"$SHITATE_CREDENTIAL_CERTIFICATE"
  printf '%s' "$SHITATE_NOTARY_KEY_BASE64" |
    base64 --decode >"$SHITATE_NOTARY_KEY_PATH"
  security create-keychain -p "$SHITATE_KEYCHAIN_PASSWORD" \
    "$SHITATE_CREDENTIAL_KEYCHAIN"
  security set-keychain-settings -lut 21600 "$SHITATE_CREDENTIAL_KEYCHAIN"
  security unlock-keychain -p "$SHITATE_KEYCHAIN_PASSWORD" \
    "$SHITATE_CREDENTIAL_KEYCHAIN"
  security default-keychain -d user -s "$SHITATE_CREDENTIAL_KEYCHAIN"
  security import "$SHITATE_CREDENTIAL_CERTIFICATE" \
    -k "$SHITATE_CREDENTIAL_KEYCHAIN" \
    -P "$SHITATE_CERTIFICATE_PASSWORD" \
    -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple: -s \
    -k "$SHITATE_KEYCHAIN_PASSWORD" "$SHITATE_CREDENTIAL_KEYCHAIN" >/dev/null
}

shitate_validate_apple_credentials() {
  local validation_root=$1
  local identities=
  local canary="$validation_root/codesign-canary"

  identities=$(security find-identity -v -p codesigning "$SHITATE_CREDENTIAL_KEYCHAIN")
  if ! grep -Fq -- "\"$SHITATE_SIGNING_IDENTITY\"" <<<"$identities"; then
    printf 'configured Developer ID identity is unavailable\n' >&2
    return 1
  fi
  security find-certificate -c "$SHITATE_SIGNING_IDENTITY" -p \
    "$SHITATE_CREDENTIAL_KEYCHAIN" >"$SHITATE_CREDENTIAL_CERTIFICATE_PEM"
  if ! /usr/bin/openssl x509 -checkend 0 -noout \
    -in "$SHITATE_CREDENTIAL_CERTIFICATE_PEM"; then
    printf 'Developer ID certificate is expired or invalid\n' >&2
    return 1
  fi

  cp /usr/bin/true "$canary"
  chmod 700 "$canary"
  codesign --force --sign "$SHITATE_SIGNING_IDENTITY" \
    --options runtime --timestamp "$canary"
  codesign --verify --strict --verbose=2 "$canary"
  xcrun notarytool history \
    --key "$SHITATE_NOTARY_KEY_PATH" \
    --key-id "$SHITATE_NOTARY_KEY_ID" \
    --issuer "$SHITATE_NOTARY_ISSUER_ID" \
    --output-format json >/dev/null

  /usr/bin/openssl x509 -fingerprint -sha256 -noout \
    -in "$SHITATE_CREDENTIAL_CERTIFICATE_PEM"
  /usr/bin/openssl x509 -enddate -noout \
    -in "$SHITATE_CREDENTIAL_CERTIFICATE_PEM"
  printf 'Apple signing and notary credentials are usable\n'
}

shitate_cleanup_apple_credentials() {
  if [[ -n ${SHITATE_CREDENTIAL_ORIGINAL_KEYCHAIN:-} ]]; then
    if ! security default-keychain -d user -s \
      "$SHITATE_CREDENTIAL_ORIGINAL_KEYCHAIN" >/dev/null 2>&1; then
      printf 'warning: failed to restore the original default keychain\n' >&2
    fi
  fi
  if [[ -n ${SHITATE_CREDENTIAL_KEYCHAIN:-} ]]; then
    security delete-keychain "$SHITATE_CREDENTIAL_KEYCHAIN" >/dev/null 2>&1 || true
  fi
  if [[ -n ${SHITATE_CREDENTIAL_CERTIFICATE:-} ]]; then
    rm -f "$SHITATE_CREDENTIAL_CERTIFICATE"
  fi
  if [[ -n ${SHITATE_CREDENTIAL_CERTIFICATE_PEM:-} ]]; then
    rm -f "$SHITATE_CREDENTIAL_CERTIFICATE_PEM"
  fi
  if [[ -n ${SHITATE_NOTARY_KEY_PATH:-} ]]; then
    rm -f "$SHITATE_NOTARY_KEY_PATH"
  fi
}
