#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Hokuto Takemiya

set -euo pipefail

if [[ $# -lt 1 || ${SHITATE_ALLOW_NOTARIZATION:-} != YES ]]; then
  printf 'usage: SHITATE_ALLOW_NOTARIZATION=YES %s <app-or-dmg>...\n' "$0" >&2
  exit 2
fi
for variable in SHITATE_NOTARY_KEY_PATH SHITATE_NOTARY_KEY_ID SHITATE_NOTARY_ISSUER_ID; do
  if [[ -z ${!variable:-} ]]; then
    printf 'required notarization variable is missing: %s\n' "$variable" >&2
    exit 2
  fi
done

temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/shitate-notary.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT

index=0
for artifact in "$@"; do
  index=$((index + 1))
  submission=$artifact
  case "$artifact" in
    *.app)
      submission="$temporary_directory/Shi-tate-$index.zip"
      ditto -c -k --keepParent "$artifact" "$submission"
      ;;
    *.dmg) ;;
    *)
      printf 'unsupported notarization artifact: %s\n' "$artifact" >&2
      exit 2
      ;;
  esac
  result=$(xcrun notarytool submit "$submission" --wait --output-format json \
    --key "$SHITATE_NOTARY_KEY_PATH" \
    --key-id "$SHITATE_NOTARY_KEY_ID" \
    --issuer "$SHITATE_NOTARY_ISSUER_ID")
  if [[ $(jq -r '.status // ""' <<<"$result") != Accepted ]]; then
    printf 'notarization was not accepted: %s\n' "$artifact" >&2
    exit 1
  fi
  xcrun stapler staple "$artifact"
  xcrun stapler validate "$artifact"
done

printf 'notarization and staple completed for explicitly authorized artifacts\n'
