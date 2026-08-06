#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Hokuto Takemiya

set -euo pipefail

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
mode=${1:-local}

case "$mode" in
  local | ci) ;;
  *)
    printf 'usage: %s [local|ci]\n' "$0" >&2
    exit 2
    ;;
esac

"$repository_root/scripts/check-docs.sh"
"$repository_root/scripts/check-ci-policy.sh"

if [[ "$mode" == local ]]; then
  shell_scripts=()
  while IFS= read -r file; do
    shell_scripts+=("$file")
  done < <(find "$repository_root/scripts" "$repository_root/Tests/Integration" \
    -type f -name '*.sh' -print | sort)
  shellcheck "${shell_scripts[@]}"
fi

xcrun swift format lint --recursive \
  --configuration "$repository_root/.swift-format" \
  "$repository_root/Sources" "$repository_root/Tests/Swift"

formatted_sources=()
while IFS= read -r file; do
  formatted_sources+=("$file")
done < <(find "$repository_root/Sources" "$repository_root/Tests/Cpp" \
  -type f \( -name '*.h' -o -name '*.cpp' -o -name '*.mm' \) -print | sort)
xcrun clang-format --dry-run --Werror --style=file "${formatted_sources[@]}"

if [[ "$mode" == local ]]; then
  if command -v nixfmt >/dev/null 2>&1; then
    nixfmt --check "$repository_root/flake.nix"
  else
    printf 'nixfmt is missing; enter the pinned environment with nix develop.\n' >&2
    exit 1
  fi
fi
