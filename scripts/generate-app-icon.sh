#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Hokuto Takemiya

set -euo pipefail

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source_image=${1:-"$repository_root/resources/AppIcon/Shitate-source.jpg"}
layer_output=${2:-"$repository_root/resources/Shitate.icon/Assets/Shitate.png"}

if ! command -v magick >/dev/null 2>&1; then
  printf 'ImageMagick is missing; enter the pinned environment with nix develop.\n' >&2
  exit 1
fi

if [[ ! -f "$source_image" ]]; then
  printf 'source image is missing: %s\n' "$source_image" >&2
  exit 1
fi

read -r source_width source_height < <(
  magick identify -format '%w %h\n' "$source_image"
)
if [[ "$source_width" != "$source_height" || "$source_width" -lt 1024 ]]; then
  printf 'source image must be square and at least 1024px: %sx%s\n' \
    "$source_width" "$source_height" >&2
  exit 1
fi

temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/shitate-app-icon.XXXXXX")
cleanup() {
  rm -rf -- "$temporary_directory"
}
trap cleanup EXIT

generated_layer="$temporary_directory/Shitate.png"

# Icon Composer supplies the platform-specific material, mask, and legacy
# fallback. Keep only the black artwork as a transparent 1024px source layer.
magick -size 780x780 xc:black \
  \( "$source_image" -auto-orient -resize 780x780 \
    -colorspace Gray -level '0%,92%' -negate \) \
  -alpha off -compose CopyOpacity -composite \
  -gravity center -background none -extent 1024x1024 \
  -depth 8 -strip -define png:color-type=6 "$generated_layer"

mkdir -p "$(dirname "$layer_output")"
cp "$generated_layer" "$layer_output"

printf 'generated %s\n' "$layer_output"
