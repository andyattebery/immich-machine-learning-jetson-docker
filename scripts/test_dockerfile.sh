#!/usr/bin/env bash
TEST_NAME="test_dockerfile"
source "$(dirname "$0")/test_lib.sh"

cd "$REPO_ROOT"

if ! command -v hadolint >/dev/null 2>&1; then
    skip "$TEST_NAME" "hadolint not installed"
fi

hadolint --failure-threshold error Dockerfile.immich-builder \
    || fail "$TEST_NAME" "hadolint reported errors"

pass "$TEST_NAME"
