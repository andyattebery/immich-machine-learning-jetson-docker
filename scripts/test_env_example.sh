#!/usr/bin/env bash
TEST_NAME="test_env_example"
source "$(dirname "$0")/test_lib.sh"

cd "$REPO_ROOT"

[ -f docker-compose.yaml ] || fail "$TEST_NAME" "docker-compose.yaml missing"
[ -f .env.example ]        || fail "$TEST_NAME" ".env.example missing"

refs=$(grep -oE '\$\{[A-Z_][A-Z0-9_]*(:-[^}]*)?\}' docker-compose.yaml \
       | sed -E 's/\$\{([A-Z_][A-Z0-9_]*).*/\1/' | sort -u)

defined=$(grep -oE '^[A-Z_][A-Z0-9_]*=' .env.example | sed 's/=$//' | sort -u)

missing=""
for r in $refs; do
    if ! printf '%s\n' "$defined" | grep -qx "$r"; then
        # Variables with a ${VAR:-default} form are optional; check if default was set.
        if grep -qE "\\\$\\{$r:-" docker-compose.yaml; then
            continue
        fi
        missing="$missing $r"
    fi
done

[ -z "$missing" ] || fail "$TEST_NAME" "vars referenced in compose but missing from .env.example:$missing"

pass "$TEST_NAME"
