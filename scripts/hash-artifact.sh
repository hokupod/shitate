#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Hokuto Takemiya

set -euo pipefail

if [[ $# -ne 1 || ! -f $1 ]]; then
  printf 'usage: %s <artifact>\n' "$0" >&2
  exit 2
fi

artifact=$1
hash_file="$artifact.sha256"
if [[ -e "$hash_file" ]]; then
  printf 'refusing to overwrite artifact hash: %s\n' "$hash_file" >&2
  exit 1
fi

(
  cd "$(dirname "$artifact")"
  shasum -a 256 "$(basename "$artifact")" >"$(basename "$hash_file")"
)
printf 'created artifact hash: %s\n' "$hash_file"
