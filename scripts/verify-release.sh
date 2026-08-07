#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Hokuto Takemiya

set -euo pipefail

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=scripts/lib/security-policy.sh
source "$repository_root/scripts/lib/security-policy.sh"

if [[ $# -lt 1 || $# -gt 2 ]]; then
  printf 'usage: %s <Shi-tate.app> [--allow-adhoc]\n' "$0" >&2
  exit 2
fi

app_bundle=$1
allow_adhoc=false
if [[ ${2:-} == --allow-adhoc ]]; then
  allow_adhoc=true
elif [[ $# -eq 2 ]]; then
  printf 'unknown verification mode: %s\n' "$2" >&2
  exit 2
fi

app_bundle=$(perl -MCwd=abs_path -le 'print abs_path($ARGV[0]) // q{}' "$app_bundle")
if [[ -z "$app_bundle" || ! -d "$app_bundle" || ${app_bundle##*.} != app ]]; then
  printf 'invalid app bundle\n' >&2
  exit 1
fi

app_executable="$app_bundle/Contents/MacOS/Shi-tate"
helper_executable="$app_bundle/Contents/Helpers/ShitatePluginScanner"
info_plist="$app_bundle/Contents/Info.plist"
for required in "$app_executable" "$helper_executable" "$info_plist" \
  "$app_bundle/Contents/Resources/LICENSE" \
  "$app_bundle/Contents/Resources/THIRD_PARTY_NOTICES.md" \
  "$app_bundle/Contents/Resources/JUCE-LICENSE.md"; do
  if [[ ! -f "$required" ]]; then
    printf 'required release file is missing: %s\n' "$required" >&2
    exit 1
  fi
done

if [[ $(plutil -extract LSMinimumSystemVersion raw -o - "$info_plist") != 14.0 ]]; then
  printf 'minimum macOS version must be 14.0\n' >&2
  exit 1
fi
if [[ $(lipo -archs "$app_executable") != arm64 ||
  $(lipo -archs "$helper_executable") != arm64 ]]; then
  printf 'release code must contain only arm64\n' >&2
  exit 1
fi
for executable in "$app_executable" "$helper_executable"; do
  if ! otool -l "$executable" |
    awk '/LC_BUILD_VERSION/{found=1} found && /minos/{print $2; exit}' |
    grep -qx '14.0'; then
    printf 'Mach-O minimum OS is not 14.0: %s\n' "$executable" >&2
    exit 1
  fi
done
if [[ $(plutil -extract CFBundleShortVersionString raw -o - "$info_plist") != 0.1.0 ||
  ! $(plutil -extract ShitateCommit raw -o - "$info_plist") =~ ^[0-9a-f]{40}$ ]]; then
  printf 'release version or commit metadata is invalid\n' >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "$app_bundle"
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/shitate-release-verify.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT
app_entitlements="$temporary_directory/app-entitlements.plist"
helper_entitlements="$temporary_directory/helper-entitlements.plist"
codesign -d --entitlements :- "$app_bundle" >"$app_entitlements" 2>/dev/null
codesign -d --entitlements :- "$helper_executable" >"$helper_entitlements" 2>/dev/null
shitate_verify_entitlement_files "$app_entitlements" "$helper_entitlements"

for executable in "$app_executable" "$helper_executable"; do
  signature=$(codesign -dvvv "$executable" 2>&1)
  if ! grep -Eq 'flags=0x[0-9a-f]*10000.*runtime|flags=.*runtime' <<<"$signature"; then
    printf 'Hardened Runtime is missing: %s\n' "$executable" >&2
    exit 1
  fi
  if [[ "$allow_adhoc" == false ]] && grep -q 'Signature=adhoc' <<<"$signature"; then
    printf 'Developer ID signature is required: %s\n' "$executable" >&2
    exit 1
  fi
  mode=$(/usr/bin/stat -f '%Lp' "$executable")
  if (( (8#$mode & 0022) != 0 )); then
    printf 'executable is group/world writable: %s\n' "$executable" >&2
    exit 1
  fi
  dependencies=$(otool -L "$executable")
  shitate_verify_dependency_text "$dependencies"
  while IFS= read -r dependency; do
    case "$dependency" in
      /System/Library/* | /usr/lib/* | "$executable":) ;;
      *)
        printf 'unexpected non-system dependency: %s\n' "$dependency" >&2
        exit 1
        ;;
    esac
  done < <(printf '%s\n' "$dependencies" | sed -n '2,$s/^[[:space:]]*\([^[:space:]]*\).*/\1/p')
  shitate_verify_symbol_text "$(nm -u "$executable" 2>/dev/null || true)"
  codesign --verify --strict --verbose=2 "$executable"
done

shitate_verify_bundle_content "$app_bundle"

mode_label=developer-id
if [[ "$allow_adhoc" == true ]]; then
  mode_label=adhoc-unverified-distribution
fi
printf 'release verification passed: mode=%s app=%s\n' "$mode_label" "$app_bundle"
