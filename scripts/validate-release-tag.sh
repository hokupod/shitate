#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Hokuto Takemiya

set -euo pipefail

if [[ $# -lt 5 || $# -gt 6 ]]; then
  printf '%s\n' \
    "usage: $0 <tag> <expected-commit> <expected-tagger-email> <ref-json> <tag-json> [expected-tag-object]" >&2
  exit 2
fi

tag=$1
expected_commit=$2
expected_tagger_email=$3
ref_json=$4
tag_json=$5
expected_tag_object=${6:-}
if [[ ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ||
  ! "$expected_commit" =~ ^[0-9a-f]{40}$ ||
  ! "$expected_tagger_email" =~ ^[^[:space:]@]+@[^[:space:]@]+$ ||
  ( -n "$expected_tag_object" && ! "$expected_tag_object" =~ ^[0-9a-f]{40}$ ) ]]; then
  printf 'release tag, commit, tagger, or expected tag object is invalid\n' >&2
  exit 1
fi

if ! jq -e \
  --arg tag "$tag" \
  '.ref == ("refs/tags/" + $tag) and
   .object.type == "tag" and
   (.object.sha | test("^[0-9a-f]{40}$"))' \
  "$ref_json" >/dev/null; then
  printf 'release ref must resolve to an annotated tag object\n' >&2
  exit 1
fi
tag_object_sha=$(jq -r '.object.sha' "$ref_json")
if [[ -n "$expected_tag_object" && "$tag_object_sha" != "$expected_tag_object" ]]; then
  printf 'release tag object changed after validation\n' >&2
  exit 1
fi

if ! jq -e \
  --arg tag "$tag" \
  --arg tag_object_sha "$tag_object_sha" \
  --arg expected_commit "$expected_commit" \
  --arg expected_tagger_email "$expected_tagger_email" \
  '.sha == $tag_object_sha and
   .tag == $tag and
   .tagger.email == $expected_tagger_email and
   .object.type == "commit" and
   .object.sha == $expected_commit and
   .verification.verified == true and
   .verification.reason == "valid" and
   (.verification.signature | type == "string" and length > 0) and
   (.verification.payload | type == "string" and length > 0)' \
  "$tag_json" >/dev/null; then
  printf 'release tag must be signed, verified, and point to the build commit\n' >&2
  exit 1
fi

printf 'verified signed annotated release tag: %s -> %s\n' "$tag" "$expected_commit"
