#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Hokuto Takemiya

set -euo pipefail

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
preset=${1:-dev}

case "$preset" in
  dev | ci | release) ;;
  *)
    printf 'usage: %s [dev|ci|release]\n' "$0" >&2
    exit 2
    ;;
esac

cd "$repository_root"
cmake --build --preset "$preset"
