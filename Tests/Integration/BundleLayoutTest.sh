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
  "$resources/Shitate.icns"
  "$resources/Assets.car"
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

if ! /usr/bin/codesign --verify --strict --deep "$app_bundle" \
  || ! /usr/bin/codesign --verify --strict "$helper"; then
  printf 'app or embedded helper signature is invalid\n' >&2
  exit 1
fi

helper_identifier=$(/usr/bin/codesign -d --verbose=4 "$helper" 2>&1 \
  | /usr/bin/sed -n 's/^Identifier=//p')
if [[ "$helper_identifier" != "dev.hokupod.shitate.plugin-scanner" ]]; then
  printf 'unexpected helper signing identifier: %s\n' "$helper_identifier" >&2
  exit 1
fi

if [[ -e "$resources/ShitatePluginScanner" \
  || -e "$app_bundle/Contents/MacOS/ShitatePluginScanner" ]]; then
  printf 'helper is present outside Contents/Helpers\n' >&2
  exit 1
fi

if find "$app_bundle" -type d -name '*Plugin.vst3' -print -quit | grep -q .; then
  printf 'test VST3 fixture leaked into the app bundle\n' >&2
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

bundle_icon_file=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' \
  "$app_bundle/Contents/Info.plist")
bundle_icon_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' \
  "$app_bundle/Contents/Info.plist")
if [[ "$bundle_icon_file" != "Shitate" || "$bundle_icon_name" != "Shitate" ]]; then
  printf 'unexpected app icon metadata: file=%s name=%s\n' \
    "$bundle_icon_file" "$bundle_icon_name" >&2
  exit 1
fi

temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/shitate-bundle-icon.XXXXXX")
cleanup() {
  rm -rf -- "$temporary_directory"
}
trap cleanup EXIT

iconset="$temporary_directory/Shitate.iconset"
/usr/bin/iconutil --convert iconset --output "$iconset" \
  "$resources/Shitate.icns"

shopt -s nullglob
icon_representations=("$iconset"/*.png)
shopt -u nullglob
if [[ "${#icon_representations[@]}" -eq 0 ]]; then
  printf 'compiled legacy app icon has no PNG representations\n' >&2
  exit 1
fi

for icon in "${icon_representations[@]}"; do
  read -r width height < <(magick identify -format '%w %h\n' "$icon")
  last_x=$((width - 1))
  last_y=$((height - 1))
  center_x=$((width / 2))
  center_y=$((height / 2))
  read -r top_left top_right bottom_left bottom_right center < <(
    magick "$icon" -format \
      "%[fx:p{0,0}.a==0] %[fx:p{$last_x,0}.a==0] \
%[fx:p{0,$last_y}.a==0] %[fx:p{$last_x,$last_y}.a==0] \
%[fx:p{$center_x,$center_y}.a>0.9]\n" info:
  )
  if [[ "$top_left" != 1 || "$top_right" != 1 \
    || "$bottom_left" != 1 || "$bottom_right" != 1 \
    || "$center" != 1 ]]; then
    printf 'compiled legacy app icon has an invalid alpha mask: %s\n' \
      "$icon" >&2
    exit 1
  fi
done
