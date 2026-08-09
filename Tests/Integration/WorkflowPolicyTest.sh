#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Hokuto Takemiya

set -euo pipefail

if [[ $# -ne 1 ]]; then
  printf 'usage: %s <repository-root>\n' "$0" >&2
  exit 2
fi

repository_root=$1
policy="$repository_root/scripts/check-ci-policy.sh"
tag_policy="$repository_root/scripts/validate-release-tag.sh"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/shitate-workflow-policy.XXXXXX")
trap 'chmod -R u+w "$test_root" 2>/dev/null || true; rm -rf "$test_root"' EXIT

reset_fixture() {
  rm -rf "$test_root/.github" "$test_root/scripts"
  mkdir -p "$test_root/.github" "$test_root/scripts/lib"
  cp -R "$repository_root/.github/workflows" "$test_root/.github/workflows"
  cp "$repository_root/scripts/lib/apple-credentials.sh" "$test_root/scripts/lib/"
}

expect_rejection() {
  local label=$1
  if "$policy" "$test_root" >/dev/null 2>&1; then
    printf 'workflow fixture passed unexpectedly: %s\n' "$label" >&2
    exit 1
  fi
}

expect_tag_rejection() {
  local label=$1
  if "$tag_policy" "v1.2.3" "$expected_commit" \
    "$expected_tagger_email" "$test_root/tag-ref.json" \
    "$test_root/tag-object.json" "$expected_tag_object" >/dev/null 2>&1; then
    printf 'release tag fixture passed unexpectedly: %s\n' "$label" >&2
    exit 1
  fi
}

expect_tag_value_rejection() {
  local label=$1
  local invalid_tag=$2
  if "$tag_policy" "$invalid_tag" "$expected_commit" \
    "$expected_tagger_email" "$test_root/tag-ref.json" \
    "$test_root/tag-object.json" "$expected_tag_object" >/dev/null 2>&1; then
    printf 'release tag value passed unexpectedly: %s\n' "$label" >&2
    exit 1
  fi
}

write_valid_tag_fixture() {
  local fixture_tag=${1:-v1.2.3}
  jq -n \
    --arg tag "$fixture_tag" \
    --arg tag_object_sha "$tag_object_sha" \
    '{ref:("refs/tags/" + $tag),object:{type:"tag",sha:$tag_object_sha}}' \
    >"$test_root/tag-ref.json"
  jq -n \
    --arg tag "$fixture_tag" \
    --arg tag_object_sha "$tag_object_sha" \
    --arg expected_commit "$expected_commit" \
    --arg expected_tagger_email "$expected_tagger_email" \
    '{sha:$tag_object_sha,tag:$tag,tagger:{email:$expected_tagger_email},object:{type:"commit",sha:$expected_commit},verification:{verified:true,reason:"valid",signature:"signed",payload:"payload"}}' \
    >"$test_root/tag-object.json"
}

"$policy" "$repository_root"

expected_commit=$(printf 'a%.0s' {1..40})
tag_object_sha=$(printf 'b%.0s' {1..40})
expected_tag_object=$tag_object_sha
expected_tagger_email='release@shitate.invalid'
write_valid_tag_fixture
"$tag_policy" "v1.2.3" "$expected_commit" \
  "$expected_tagger_email" "$test_root/tag-ref.json" \
  "$test_root/tag-object.json" "$expected_tag_object" >/dev/null

write_valid_tag_fixture v1.2.3-alpha.1
"$tag_policy" "v1.2.3-alpha.1" "$expected_commit" \
  "$expected_tagger_email" "$test_root/tag-ref.json" \
  "$test_root/tag-object.json" "$expected_tag_object" >/dev/null
for invalid_tag in \
  v1.2.3-dev \
  v1.2.3-alpha.01 \
  v1.2.3+build.1; do
  expect_tag_value_rejection malformed-publishable-tag "$invalid_tag"
done

write_valid_tag_fixture
jq '.object.type = "commit"' "$test_root/tag-ref.json" \
  >"$test_root/tag-ref-invalid.json"
mv "$test_root/tag-ref-invalid.json" "$test_root/tag-ref.json"
expect_tag_rejection lightweight-tag

write_valid_tag_fixture
jq '.verification.verified = false' "$test_root/tag-object.json" \
  >"$test_root/tag-object-invalid.json"
mv "$test_root/tag-object-invalid.json" "$test_root/tag-object.json"
expect_tag_rejection unsigned-tag

write_valid_tag_fixture
jq '.verification.reason = "unknown_key"' "$test_root/tag-object.json" \
  >"$test_root/tag-object-invalid.json"
mv "$test_root/tag-object-invalid.json" "$test_root/tag-object.json"
expect_tag_rejection invalid-signature-reason

write_valid_tag_fixture
jq '.tagger.email = "unexpected@shitate.invalid"' "$test_root/tag-object.json" \
  >"$test_root/tag-object-invalid.json"
mv "$test_root/tag-object-invalid.json" "$test_root/tag-object.json"
expect_tag_rejection unexpected-tagger

write_valid_tag_fixture
jq --arg wrong "$(printf 'c%.0s' {1..40})" '.object.sha = $wrong' \
  "$test_root/tag-object.json" >"$test_root/tag-object-invalid.json"
mv "$test_root/tag-object-invalid.json" "$test_root/tag-object.json"
expect_tag_rejection mismatched-build-commit

write_valid_tag_fixture
printf '{}\n' >"$test_root/tag-ref.json"
expect_tag_rejection missing-tag

write_valid_tag_fixture
expected_tag_object=$(printf 'd%.0s' {1..40})
expect_tag_rejection retargeted-after-gate
expected_tag_object=$tag_object_sha

reset_fixture
perl -pi -e 's/checkout@[0-9a-f]{40}/checkout@v4/' \
  "$test_root/.github/workflows/ci.yml"
expect_rejection floating-action

reset_fixture
perl -0pi -e 's/permissions:\n  contents: read/permissions:\n  contents: write/' \
  "$test_root/.github/workflows/ci.yml"
expect_rejection broad-permission

reset_fixture
printf '\npull_request_target:\n' >>"$test_root/.github/workflows/ci.yml"
expect_rejection pull-request-target

reset_fixture
yq -i 'del(.on.schedule)' "$test_root/.github/workflows/codeql.yml"
expect_rejection codeql-without-weekly-gate

reset_fixture
yq -i '.concurrency."cancel-in-progress" = true' \
  "$test_root/.github/workflows/codeql.yml"
expect_rejection codeql-cancels-in-progress

reset_fixture
yq -i '.jobs.analyze.if = "needs.gate.outputs.analyze"' \
  "$test_root/.github/workflows/codeql.yml"
expect_rejection codeql-without-gate-failure-fallback

reset_fixture
perl -0pi -e 's/needs\.gate\.result != \x27success\x27 \|\| needs\.gate\.outputs\.analyze/needs.gate.result != \x27success\x27 && needs.gate.outputs.analyze/' \
  "$test_root/.github/workflows/codeql.yml"
expect_rejection codeql-with-broken-gate-failure-fallback

reset_fixture
perl -0pi -e 's/\n              "Sources",//' \
  "$test_root/.github/workflows/codeql.yml"
expect_rejection codeql-without-source-trigger

reset_fixture
yq -i '(.jobs.gate.steps[] | select(.id == "decision").env.ANALYSIS_ENVIRONMENT) = "{\"language\":\"swift\"}"' \
  "$test_root/.github/workflows/codeql.yml"
expect_rejection codeql-without-combined-language-record

reset_fixture
perl -pi -e 's/1814400/2419200/' "$test_root/.github/workflows/codeql.yml"
expect_rejection codeql-without-28-day-scan-bound

reset_fixture
perl -0pi -e 's/(      - name: Verify toolchain and dependency pins\n)/$1        env:\n          UNTRUSTED: \${{ secrets.UNTRUSTED_PR_SECRET }}\n/' \
  "$test_root/.github/workflows/ci.yml"
expect_rejection pr-secret

reset_fixture
perl -0pi -e 's/environment: release/environment: staging/' \
  "$test_root/.github/workflows/release.yml"
expect_rejection unprotected-release

reset_fixture
perl -0pi -e 's/environment: release/environment: staging/' \
  "$test_root/.github/workflows/release-preflight.yml"
expect_rejection unprotected-preflight

reset_fixture
yq -i '.on.push = {"branches":["main"]}' \
  "$test_root/.github/workflows/release-preflight.yml"
expect_rejection preflight-push-trigger

reset_fixture
yq -i '.on.push.tags = ["v*"]' \
  "$test_root/.github/workflows/release.yml"
expect_rejection broad-release-tag-trigger

reset_fixture
yq -i '.jobs.credential.steps = [.jobs.credential.steps[] |
  select(.name != "Revalidate identity before materializing credentials")]' \
  "$test_root/.github/workflows/release-preflight.yml"
expect_rejection missing-preflight-revalidation

reset_fixture
perl -pi -e 's/^  export SHITATE_NOTARY_KEY_PATH=/  SHITATE_NOTARY_KEY_PATH=/' \
  "$test_root/scripts/lib/apple-credentials.sh"
expect_rejection unexported-notary-key-path

reset_fixture
perl -0pi -e \
  's/            \$\{\{ env\.SHITATE_DMG_SHA256 \}\}\n//' \
  "$test_root/.github/workflows/release.yml"
expect_rejection unattested-release-asset

reset_fixture
perl -0pi -e 's/      - test\n/      - package\n/' \
  "$test_root/.github/workflows/release.yml"
expect_rejection release-before-test

reset_fixture
printf '\n# gh release upload --clobber\n' \
  >>"$test_root/.github/workflows/release.yml"
expect_rejection mutable-release-assets

reset_fixture
perl -pi -e 's/ --verify-tag//' "$test_root/.github/workflows/release.yml"
expect_rejection release-without-verified-tag

reset_fixture
perl -ni -e 'print unless /SHITATE_IMMUTABLE_RELEASE_TAGS.*== YES/' \
  "$test_root/.github/workflows/release.yml"
expect_rejection mutable-release-tag-policy

printf 'workflow policy negative fixtures passed\n'
