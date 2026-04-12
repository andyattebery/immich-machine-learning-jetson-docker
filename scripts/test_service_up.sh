#!/usr/bin/env bash
TEST_NAME="test_service"
source "$(dirname "$0")/test_lib.sh"

cd "$REPO_ROOT"

need docker
need curl

if [ ! -f .env ]; then
    cp .env.example .env
    : "${MACHINE_LEARNING_CACHE_DIR:=/tmp/immich-ml-cache}"
    mkdir -p "$MACHINE_LEARNING_CACHE_DIR"
    # ensure MACHINE_LEARNING_CACHE_DIR has a value in the .env
    if ! grep -q '^MACHINE_LEARNING_CACHE_DIR=' .env; then
        printf 'MACHINE_LEARNING_CACHE_DIR=%s\n' "$MACHINE_LEARNING_CACHE_DIR" >> .env
    fi
fi

cleanup() { docker compose down >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker compose up -d >/dev/null 2>&1 \
    || fail "$TEST_NAME" "docker compose up failed"

# Poll logs up to 60s for provider selection.
found_providers=0
for _ in $(seq 1 30); do
    logs=$(docker logs immich-machine-learning 2>&1 || true)
    if printf '%s\n' "$logs" | grep -q "Available ORT providers" \
       && printf '%s\n' "$logs" | grep -q "CUDAExecutionProvider"; then
        found_providers=1
        break
    fi
    sleep 2
done

[ "$found_providers" = "1" ] \
    || fail "$TEST_NAME" "did not observe 'Available ORT providers' + CUDAExecutionProvider in logs within 60s"

port="${ML_PORT:-3003}"
curl -fsS "http://localhost:${port}/ping" >/dev/null \
    || fail "$TEST_NAME" "GET /ping on port $port failed"

pass "$TEST_NAME"
