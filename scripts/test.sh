#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Hokuto Takemiya

set -euo pipefail

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
preset=${1:-dev}
label=${2:-}

case "$preset" in
  dev | ci | release) ;;
  *)
    printf 'usage: %s [dev|ci|release] [label-regex]\n' "$0" >&2
    exit 2
    ;;
esac

arguments=(--preset "$preset")
if [[ -n "$label" ]]; then
  arguments+=(--label-regex "$label")
fi

cd "$repository_root"
ctest "${arguments[@]}"
