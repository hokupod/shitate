#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Hokuto Takemiya

set -euo pipefail

repository_root=${1:?repository root is required}
# shellcheck source=scripts/lib/version.sh
source "$repository_root/scripts/lib/version.sh"
shitate_read_version_contract "$repository_root"
repository_version=$SHITATE_VERSION
test_root=$(mktemp -d "${TMPDIR:-/tmp}/shitate-docs-version.XXXXXX")
trap 'rm -rf "$test_root"' EXIT

for source_version in 0.2.0-dev 0.2.0-alpha.1; do
  source_fixture="$test_root/source-$source_version"
  mkdir -p "$source_fixture"
  cp "$repository_root"/README*.md "$source_fixture/"
  perl -pi -e "s/\\Q${repository_version}\\E/${source_version}/g" \
    "$source_fixture"/README*.md

  for target_version in 0.2.0-dev 0.2.0-alpha.1; do
    fixture="$source_fixture/target-$target_version"
    mkdir -p "$fixture"
    cp "$source_fixture"/README*.md "$fixture/"
    perl -pi -e "s/\\Q${source_version}\\E/${target_version}/g" \
      "$fixture"/README*.md
    printf '%s\n' "$target_version" >"$fixture/VERSION"
    printf '%s\n' "$SHITATE_BUNDLE_VERSION" >"$fixture/BUNDLE_VERSION"
    "$repository_root/scripts/check-docs.sh" --version-only "$fixture" >/dev/null
  done
done

mismatch_fixture="$test_root/source-0.2.0-alpha.1/target-0.2.0-dev"
printf '0.2.0-beta.1\n' >"$mismatch_fixture/VERSION"
if "$repository_root/scripts/check-docs.sh" \
  --version-only "$mismatch_fixture" >/dev/null 2>&1; then
  printf 'docs checker accepted mismatched VERSION\n' >&2
  exit 1
fi

printf 'docs version fixtures passed\n'
