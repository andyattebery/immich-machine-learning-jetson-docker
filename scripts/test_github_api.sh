#!/usr/bin/env bash
TEST_NAME="test_github_api"
source "$(dirname "$0")/test_lib.sh"

need curl
need jq

tag=$(curl -sfL https://api.github.com/repos/immich-app/immich/releases/latest | jq -r .tag_name) \
    || fail "$TEST_NAME" "GitHub API call failed"

[ -n "$tag" ] && [ "$tag" != "null" ] \
    || fail "$TEST_NAME" "tag_name empty or null (rate-limited?)"

[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || fail "$TEST_NAME" "tag '$tag' does not match ^v[0-9]+\\.[0-9]+\\.[0-9]+$"

pass "$TEST_NAME (resolved $tag)"
