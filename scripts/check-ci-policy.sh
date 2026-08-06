#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Hokuto Takemiya

set -euo pipefail

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
workflow_directory="$repository_root/.github/workflows"

if [[ ! -d "$workflow_directory" ]]; then
  printf 'workflow directory is missing: %s\n' "$workflow_directory" >&2
  exit 1
fi

uses_lines=$(grep -ERh '^[[:space:]]*uses:' "$workflow_directory")
if [[ -z "$uses_lines" ]]; then
  printf 'no GitHub Action uses entries found\n' >&2
  exit 1
fi

while IFS= read -r line; do
  if [[ ! "$line" =~ @[0-9a-f]{40}([[:space:]]*#.*)?$ ]]; then
    printf 'GitHub Action is not pinned to a 40-character SHA: %s\n' "$line" >&2
    exit 1
  fi
done <<<"$uses_lines"

if grep -ERn 'pull_request_target|permissions:[[:space:]]*write-all|@[vV][0-9]+([[:space:]]|$)' \
  "$repository_root/.github"; then
  printf 'prohibited GitHub Actions policy found\n' >&2
  exit 1
fi
