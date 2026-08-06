#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Hokuto Takemiya

set -euo pipefail

app_bundle=${1:?app bundle path is required}
app_executable="$app_bundle/Contents/MacOS/Shi-tate"
helper="$app_bundle/Contents/Helpers/ShitatePluginScanner"
resources="$app_bundle/Contents/Resources"

required_files=(
  "$app_bundle/Contents/Info.plist"
  "$app_executable"
  "$helper"
  "$resources/LICENSE"
  "$resources/THIRD_PARTY_NOTICES.md"
  "$resources/JUCE-LICENSE.md"
)

for file in "${required_files[@]}"; do
  if [[ ! -e "$file" ]]; then
    printf 'required bundle file is missing: %s\n' "$file" >&2
    exit 1
  fi
done

if [[ ! -x "$app_executable" || ! -x "$helper" ]]; then
  printf 'app and helper must both be executable\n' >&2
  exit 1
fi

if [[ -e "$resources/ShitatePluginScanner" \
  || -e "$app_bundle/Contents/MacOS/ShitatePluginScanner" ]]; then
  printf 'helper is present outside Contents/Helpers\n' >&2
  exit 1
fi

for executable in "$app_executable" "$helper"; do
  architectures=$(/usr/bin/lipo -archs "$executable")
  if [[ "$architectures" != "arm64" ]]; then
    printf 'expected arm64-only executable at %s; got %s\n' \
      "$executable" "$architectures" >&2
    exit 1
  fi
done

bundle_executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' \
  "$app_bundle/Contents/Info.plist")
if [[ "$bundle_executable" != "Shi-tate" ]]; then
  printf 'unexpected CFBundleExecutable: %s\n' "$bundle_executable" >&2
  exit 1
fi
