#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Hokuto Takemiya

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd)"

fail() {
  printf 'docs check failed: %s\n' "$1" >&2
  exit 1
}

required_files=(
  README.md
  README.ja.md
  README.zh-CN.md
  docs/design.md
  docs/architecture.md
  docs/threat-model.md
  docs/manual-qa.md
  docs/plugin-compatibility.md
  LICENSE
  LICENSES/AGPL-3.0-only.txt
  THIRD_PARTY_NOTICES.md
  SECURITY.md
  CONTRIBUTING.md
  VERSION
)

for relative_path in "${required_files[@]}"; do
  [[ -f "${repo_root}/${relative_path}" ]] || fail "missing ${relative_path}"
done

version="$(tr -d '\r\n' < "${repo_root}/VERSION")"
[[ "${version}" == "0.1.0-dev" ]] || fail "VERSION must be 0.1.0-dev"

readmes=(README.md README.ja.md README.zh-CN.md)
for readme in "${readmes[@]}"; do
  path="${repo_root}/${readme}"
  grep -Fq '[English](README.md)' "${path}" || fail "${readme}: missing English link"
  grep -Fq '[日本語](README.ja.md)' "${path}" || fail "${readme}: missing Japanese link"
  grep -Fq '[简体中文](README.zh-CN.md)' "${path}" || fail "${readme}: missing Chinese link"
  grep -Fq '0.1.0-dev' "${path}" || fail "${readme}: version mismatch"
  grep -Fq 'f8f8864172464b9adf9eba6101e1f784838d1597' "${path}" || fail "${readme}: JUCE pin mismatch"
  grep -Fq 'AGPL-3.0-only' "${path}" || fail "${readme}: license mismatch"
  grep -Fq 'BlackHole 2ch' "${path}" || fail "${readme}: BlackHole requirement missing"
  grep -Fq 'arm64' "${path}" || fail "${readme}: architecture missing"
  grep -Fq 'macOS 14' "${path}" || fail "${readme}: minimum OS missing"
  grep -Fq 'docs/architecture.md' "${path}" || fail "${readme}: architecture link missing"
  grep -Fq 'docs/threat-model.md' "${path}" || fail "${readme}: threat-model link missing"
  grep -Eiq 'pre-alpha|プレアルファ' "${path}" || fail "${readme}: pre-alpha status missing"
done

[[ "$(grep -c '^## ' "${repo_root}/docs/design.md")" == "33" ]] ||
  fail 'design must contain sections 0 through 32'

fixed_design_tokens=(
  D-001
  D-024
  AGPL-3.0-only
  "48,000"
  1024
  README.zh-CN.md
  resumeAfterWake
  MasterOutputStage
  posix_spawn
  f8f8864172464b9adf9eba6101e1f784838d1597
)

for token in "${fixed_design_tokens[@]}"; do
  grep -Fq "${token}" "${repo_root}/docs/design.md" || fail "design missing ${token}"
done

cmp -s "${repo_root}/LICENSE" "${repo_root}/LICENSES/AGPL-3.0-only.txt" ||
  fail 'AGPL license copies differ'

printf 'docs check passed: version=%s, readmes=%d, design_sections=33\n' \
  "${version}" "${#readmes[@]}"
