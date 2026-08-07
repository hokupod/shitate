#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Hokuto Takemiya

set -euo pipefail

if [[ $# -ne 1 ]]; then
  printf 'usage: %s <repository-root>\n' "$0" >&2
  exit 2
fi

repository_root=$1
# shellcheck source=scripts/lib/security-policy.sh
source "$repository_root/scripts/lib/security-policy.sh"

test_root=$(mktemp -d "${TMPDIR:-/tmp}/shitate-security-policy.XXXXXX")
trap 'chmod -R u+w "$test_root" 2>/dev/null || true; rm -rf "$test_root"' EXIT

app_entitlements="$test_root/app.plist"
helper_entitlements="$test_root/helper.plist"
cp "$repository_root/resources/Shitate.entitlements" "$app_entitlements"
cp "$repository_root/resources/Scanner.entitlements" "$helper_entitlements"
shitate_verify_entitlement_files "$app_entitlements" "$helper_entitlements"

for forbidden in \
  com.apple.security.cs.allow-jit \
  com.apple.security.cs.allow-unsigned-executable-memory \
  com.apple.security.cs.disable-executable-page-protection \
  com.apple.security.cs.allow-dyld-environment-variables \
  com.apple.security.get-task-allow; do
  cp "$repository_root/resources/Shitate.entitlements" "$app_entitlements"
  /usr/libexec/PlistBuddy -c "Add :$forbidden bool true" "$app_entitlements"
  if shitate_verify_entitlement_files "$app_entitlements" "$helper_entitlements" 2>/dev/null; then
    printf 'forbidden entitlement fixture passed: %s\n' "$forbidden" >&2
    exit 1
  fi
done

cp "$repository_root/resources/Shitate.entitlements" "$app_entitlements"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.network.client bool true' \
  "$app_entitlements"
if shitate_verify_entitlement_files "$app_entitlements" "$helper_entitlements" 2>/dev/null; then
  printf 'unexpected entitlement fixture passed unexpectedly\n' >&2
  exit 1
fi

fake_bundle="$test_root/Shi-tate.app"
mkdir -p "$fake_bundle/Contents/Resources"
touch "$fake_bundle/Contents/Resources/BlackHole.driver"
if shitate_verify_bundle_content "$fake_bundle" 2>/dev/null; then
  printf 'bundled BlackHole fixture passed unexpectedly\n' >&2
  exit 1
fi
rm "$fake_bundle/Contents/Resources/BlackHole.driver"
touch "$fake_bundle/Contents/Resources/ThirdParty.vst3"
if shitate_verify_bundle_content "$fake_bundle" 2>/dev/null; then
  printf 'bundled VST3 fixture passed unexpectedly\n' >&2
  exit 1
fi

if shitate_verify_dependency_text '/System/Library/Frameworks/CFNetwork.framework/CFNetwork' \
  2>/dev/null; then
  printf 'network dependency fixture passed unexpectedly\n' >&2
  exit 1
fi
if shitate_verify_symbol_text '_curl_easy_perform' 2>/dev/null; then
  printf 'network symbol fixture passed unexpectedly\n' >&2
  exit 1
fi

rm "$fake_bundle/Contents/Resources/ThirdParty.vst3"
touch "$fake_bundle/Contents/Resources/Injected.dylib"
if shitate_verify_bundle_content "$fake_bundle" 2>/dev/null; then
  printf 'unexpected dylib fixture passed unexpectedly\n' >&2
  exit 1
fi
rm "$fake_bundle/Contents/Resources/Injected.dylib"
touch "$fake_bundle/Contents/Resources/unexpected-tool"
chmod 755 "$fake_bundle/Contents/Resources/unexpected-tool"
if shitate_verify_bundle_content "$fake_bundle" 2>/dev/null; then
  printf 'unexpected executable fixture passed unexpectedly\n' >&2
  exit 1
fi
rm "$fake_bundle/Contents/Resources/unexpected-tool"
ln -s /usr/lib/libSystem.B.dylib "$fake_bundle/Contents/Resources/injected-link"
if shitate_verify_bundle_content "$fake_bundle" 2>/dev/null; then
  printf 'unexpected symlink fixture passed unexpectedly\n' >&2
  exit 1
fi

printf 'security negative fixtures passed\n'
