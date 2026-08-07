#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Hokuto Takemiya

set -euo pipefail

shitate_plist_true() {
  local plist=$1
  local key=$2
  [[ $(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true) == true ]]
}

shitate_verify_entitlement_files() {
  local app_entitlements=$1
  local helper_entitlements=$2

  local app_keys helper_keys
  app_keys=$(/usr/bin/plutil -convert json -o - "$app_entitlements" |
    jq -c 'keys | sort')
  helper_keys=$(/usr/bin/plutil -convert json -o - "$helper_entitlements" |
    jq -c 'keys | sort')
  if [[ "$app_keys" != \
    '["com.apple.security.cs.disable-library-validation","com.apple.security.device.audio-input"]' ]]; then
    printf 'app entitlement set is broader or narrower than documented\n' >&2
    return 1
  fi
  if [[ "$helper_keys" != \
    '["com.apple.security.cs.disable-library-validation"]' ]]; then
    printf 'helper entitlement set is broader or narrower than documented\n' >&2
    return 1
  fi

  shitate_plist_true "$app_entitlements" com.apple.security.device.audio-input || {
    printf 'app audio-input entitlement is missing\n' >&2
    return 1
  }
  shitate_plist_true "$app_entitlements" com.apple.security.cs.disable-library-validation || {
    printf 'app library-validation exception is missing\n' >&2
    return 1
  }
  shitate_plist_true "$helper_entitlements" com.apple.security.cs.disable-library-validation || {
    printf 'helper library-validation exception is missing\n' >&2
    return 1
  }
  if shitate_plist_true "$helper_entitlements" com.apple.security.device.audio-input; then
    printf 'helper must not have audio-input entitlement\n' >&2
    return 1
  fi
  if shitate_plist_true "$app_entitlements" com.apple.security.app-sandbox ||
    shitate_plist_true "$helper_entitlements" com.apple.security.app-sandbox; then
    printf 'App Sandbox is outside the documented v0.2 boundary\n' >&2
    return 1
  fi

  local forbidden
  for forbidden in \
    com.apple.security.cs.allow-jit \
    com.apple.security.cs.allow-unsigned-executable-memory \
    com.apple.security.cs.disable-executable-page-protection \
    com.apple.security.cs.allow-dyld-environment-variables \
    com.apple.security.get-task-allow; do
    if shitate_plist_true "$app_entitlements" "$forbidden" ||
      shitate_plist_true "$helper_entitlements" "$forbidden"; then
      printf 'forbidden release entitlement: %s\n' "$forbidden" >&2
      return 1
    fi
  done
}

shitate_verify_bundle_content() {
  local app_bundle=$1
  local unexpected
  unexpected=$(find "$app_bundle" \
    \( -iname '*.vst3' -o -iname '*blackhole*' -o -iname '*testplugin*' \
    -o -iname '*.xctest' -o -iname '*.dylib' -o -iname '*.framework' \) \
    -print -quit)
  if [[ -n "$unexpected" ]]; then
    printf 'forbidden release bundle content: %s\n' "$unexpected" >&2
    return 1
  fi

  unexpected=$(find "$app_bundle" -type l -print -quit)
  if [[ -n "$unexpected" ]]; then
    printf 'unexpected release bundle symlink: %s\n' "$unexpected" >&2
    return 1
  fi

  local candidate kind relative mode
  while IFS= read -r -d '' candidate; do
    kind=$(/usr/bin/file -b "$candidate")
    if [[ ! -x "$candidate" && "$kind" != Mach-O* ]]; then
      continue
    fi
    relative=${candidate#"$app_bundle"/}
    case "$relative" in
      Contents/MacOS/Shi-tate | Contents/Helpers/ShitatePluginScanner) ;;
      *)
        printf 'unexpected release executable: %s\n' "$relative" >&2
        return 1
        ;;
    esac
    if [[ "$kind" != Mach-O* ]]; then
      printf 'release executable is not Mach-O: %s\n' "$relative" >&2
      return 1
    fi
    mode=$(/usr/bin/stat -f '%Lp' "$candidate")
    if (( (8#$mode & 0022) != 0 )); then
      printf 'release executable is group/world writable: %s\n' "$relative" >&2
      return 1
    fi
  done < <(find "$app_bundle" -type f -print0)
}

shitate_verify_dependency_text() {
  local dependencies=$1
  if printf '%s\n' "$dependencies" |
    grep -Eq 'WebKit\.framework|CFNetwork\.framework|Network\.framework|libcurl'; then
    printf 'network-capable dependency is linked\n' >&2
    return 1
  fi
}

shitate_verify_symbol_text() {
  local symbols=$1
  if printf '%s\n' "$symbols" |
    grep -Eq 'curl_easy_|NSURLSession|NWConnection|CFHTTP|WKWebView'; then
    printf 'network-client symbol is present\n' >&2
    return 1
  fi
}
