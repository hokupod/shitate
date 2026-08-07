#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Hokuto Takemiya

set -euo pipefail

generator=${1:?generator path is required}
source_image=${2:?source image path is required}
committed_layer=${3:?committed artwork layer path is required}
icon_definition=${4:?Icon Composer definition path is required}

temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/shitate-app-icon-test.XXXXXX")
cleanup() {
  rm -rf -- "$temporary_directory"
}
trap cleanup EXIT

generated_layer="$temporary_directory/Shitate.png"
"$generator" "$source_image" "$generated_layer"

if ! cmp -s "$committed_layer" "$generated_layer"; then
  printf 'committed Icon Composer layer does not match the source generator\n' >&2
  exit 1
fi

read -r layer_width layer_height layer_format < <(
  magick identify -format '%w %h %m\n' "$committed_layer"
)
if [[ "$layer_width" != 1024 || "$layer_height" != 1024 \
  || "$layer_format" != PNG ]]; then
  printf 'unexpected artwork layer: %sx%s %s\n' \
    "$layer_width" "$layer_height" "$layer_format" >&2
  exit 1
fi

read -r corner_is_clear artwork_is_opaque background_is_clear < <(
  magick "$committed_layer" \
    -format '%[fx:p{0,0}.a==0] %[fx:p{512,150}.a>0.9] %[fx:p{512,512}.a==0]\n' \
    info:
)
if [[ "$corner_is_clear" != 1 || "$artwork_is_opaque" != 1 \
  || "$background_is_clear" != 1 ]]; then
  printf 'Icon Composer artwork does not have the expected alpha mask\n' >&2
  exit 1
fi

if ! jq -e '
    .["supported-platforms"].squares == ["macOS"]
    and .fill.solid != null
    and (.groups | length == 1)
    and (.groups[0].layers | length == 1)
    and .groups[0].layers[0]["image-name"] == "Shitate.png"
  ' "$icon_definition" >/dev/null; then
  printf 'Icon Composer definition is invalid\n' >&2
  exit 1
fi
