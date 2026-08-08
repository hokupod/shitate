#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Hokuto Takemiya

set -euo pipefail

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=scripts/lib/version.sh
source "$repository_root/scripts/lib/version.sh"
shitate_read_version_contract "$repository_root"
preset=${1:-release}
if [[ "$preset" != release ]]; then
  printf 'usage: %s release\n' "$0" >&2
  exit 2
fi

version=$SHITATE_VERSION
release_mode=${SHITATE_RELEASE_MODE:-adhoc}
case $release_mode in
  adhoc) ;;
  developer-id) shitate_require_publishable_version "$version" ;;
  *)
    printf 'SHITATE_RELEASE_MODE must be adhoc or developer-id\n' >&2
    exit 2
    ;;
esac
app_bundle="$repository_root/build/release/Release/Shi-tate.app"
artifact_directory=${SHITATE_ARTIFACT_DIR:-"$repository_root/build/artifacts"}
dmg_name="Shi-tate_${version}_arm64.dmg"
dmg="$artifact_directory/$dmg_name"
hash_file="$dmg.sha256"
destinations=("$dmg")
if [[ ${SHITATE_DEFER_HASH:-NO} != YES ]]; then
  destinations+=("$hash_file")
fi
for destination in "${destinations[@]}"; do
  if [[ -e "$destination" ]]; then
    printf 'refusing to overwrite release artifact: %s\n' "$destination" >&2
    exit 1
  fi
done

verification_arguments=("$app_bundle")
if [[ "$release_mode" == adhoc ]]; then
  verification_arguments+=(--allow-adhoc)
fi
"$repository_root/scripts/verify-release.sh" "${verification_arguments[@]}"

mkdir -p "$artifact_directory"
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/shitate-package.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT
staging="$temporary_directory/Shi-tate"
mkdir -m 700 "$staging"
ditto "$app_bundle" "$staging/Shi-tate.app"
ln -s /Applications "$staging/Applications"
hdiutil create -quiet -fs HFS+ -format UDZO \
  -volname "Shi-tate $version" -srcfolder "$staging" "$temporary_directory/$dmg_name"
mv "$temporary_directory/$dmg_name" "$dmg"
(
  cd "$artifact_directory"
  if [[ ${SHITATE_DEFER_HASH:-NO} != YES ]]; then
    shasum -a 256 "$dmg_name" >"$dmg_name.sha256"
  fi
)

printf 'packaged %s; DMG filesystem/signing layers are verified separately from source reproducibility\n' \
  "$dmg"
