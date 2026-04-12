#!/usr/bin/env bash
TEST_NAME="test_compose"
source "$(dirname "$0")/test_lib.sh"

cd "$REPO_ROOT"

need docker

if ! docker compose version >/dev/null 2>&1; then
    skip "$TEST_NAME" "docker compose plugin not installed"
fi

MACHINE_LEARNING_CACHE_DIR=/tmp/cache \
    docker compose -f docker-compose.yaml config >/dev/null 2>&1 \
    || fail "$TEST_NAME" "docker compose config failed"

pass "$TEST_NAME"
