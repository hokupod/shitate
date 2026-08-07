#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Hokuto Takemiya

set -euo pipefail

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [[ $# -ne 1 || ${SHITATE_ALLOW_SIGNING:-} != YES || -z ${SHITATE_SIGNING_IDENTITY:-} ]]; then
  printf 'usage: SHITATE_ALLOW_SIGNING=YES SHITATE_SIGNING_IDENTITY=<Developer ID> %s <app>\n' \
    "$0" >&2
  exit 2
fi

app_bundle=$1
helper="$app_bundle/Contents/Helpers/ShitatePluginScanner"
if [[ ! -f "$helper" ]]; then
  printf 'scanner helper is missing\n' >&2
  exit 1
fi

codesign --force --sign "$SHITATE_SIGNING_IDENTITY" --options runtime --timestamp \
  --entitlements "$repository_root/resources/Scanner.entitlements" "$helper"
codesign --force --sign "$SHITATE_SIGNING_IDENTITY" --options runtime --timestamp \
  --entitlements "$repository_root/resources/Shitate.entitlements" "$app_bundle"
codesign --verify --strict --verbose=2 "$helper"
codesign --verify --deep --strict --verbose=2 "$app_bundle"

printf 'signed helper then app without codesign --deep mutation\n'
