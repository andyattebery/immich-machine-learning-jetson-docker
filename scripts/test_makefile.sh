#!/usr/bin/env bash
TEST_NAME="test_makefile"
source "$(dirname "$0")/test_lib.sh"

cd "$REPO_ROOT"

need make

make -n build >/dev/null 2>&1 || fail "$TEST_NAME" "make -n build failed (target graph broken)"

help_out=$(make help 2>&1) || fail "$TEST_NAME" "make help failed"

for var in IMMICH_VERSION ML_IMAGE; do
    line=$(printf '%s\n' "$help_out" | grep -E "^[[:space:]]*$var[[:space:]]*=" || true)
    [ -n "$line" ] || fail "$TEST_NAME" "'$var' row missing from make help"
    value=$(printf '%s\n' "$line" | sed -E "s/^[[:space:]]*$var[[:space:]]*=[[:space:]]*//")
    [ -n "$value" ] || fail "$TEST_NAME" "'$var' resolved to empty"
done

pass "$TEST_NAME"
