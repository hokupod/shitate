#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Hokuto Takemiya

set -euo pipefail

scanner=${1:?scanner path is required}
expected_version=${2:?expected version is required}

if [[ ! -x "$scanner" ]]; then
  printf 'scanner is not executable: %s\n' "$scanner" >&2
  exit 1
fi

actual_version=$("$scanner" --version)
if [[ "$actual_version" != "ShitatePluginScanner $expected_version" ]]; then
  printf 'unexpected scanner version: %s\n' "$actual_version" >&2
  exit 1
fi

set +e
"$scanner" >/dev/null 2>&1
missing_status=$?
"$scanner" --unsupported >/dev/null 2>&1
unknown_status=$?
set -e

if [[ $missing_status -ne 2 || $unknown_status -ne 2 ]]; then
  printf 'scanner argument exits must both be 2; got missing=%d unknown=%d\n' \
    "$missing_status" "$unknown_status" >&2
  exit 1
fi
