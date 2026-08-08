#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Hokuto Takemiya

set -euo pipefail

if [[ $# -ne 4 ]]; then
  printf 'usage: %s <output.json> <dmg> <source-archive> <notices>\n' "$0" >&2
  exit 2
fi
output=$1
shift
if [[ -e "$output" ]]; then
  printf 'refusing to overwrite provenance: %s\n' "$output" >&2
  exit 1
fi

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=scripts/lib/version.sh
source "$repository_root/scripts/lib/version.sh"
shitate_read_version_contract "$repository_root"

expected_names=(
  "Shi-tate_${SHITATE_VERSION}_arm64.dmg"
  "shitate-${SHITATE_VERSION}-source.tar.zst"
  THIRD_PARTY_NOTICES.md
)
index=0
for artifact in "$@"; do
  if [[ $(basename "$artifact") != "${expected_names[$index]}" ]]; then
    printf 'unexpected provenance subject: %s\n' "$artifact" >&2
    exit 1
  fi
  index=$((index + 1))
done

commit=$(git -C "$repository_root" rev-parse HEAD)
subjects='[]'
for artifact in "$@"; do
  name=$(basename "$artifact")
  digest=$(shasum -a 256 "$artifact" | awk '{print $1}')
  subjects=$(jq -c --arg name "$name" --arg digest "$digest" \
    '. + [{name:$name,digest:{sha256:$digest}}]' <<<"$subjects")
done
jq -n \
  --arg commit "$commit" \
  --arg juce f8f8864172464b9adf9eba6101e1f784838d1597 \
  --arg version "$SHITATE_VERSION" \
  --arg version_core "$SHITATE_VERSION_CORE" \
  --arg bundle_version "$SHITATE_BUNDLE_VERSION" \
  --argjson subjects "$subjects" \
  '{_type:"https://in-toto.io/Statement/v1",subject:$subjects,predicateType:"https://slsa.dev/provenance/v1",predicate:{buildDefinition:{buildType:"https://github.com/hokupod/shitate/release/v2",externalParameters:{version:$version,versionCore:$version_core,bundleVersion:$bundle_version,commit:$commit,juceCommit:$juce}},runDetails:{builder:{id:"local-or-github-actions"}}}}' \
  >"$output"

printf 'created provenance statement: %s\n' "$output"
