#!/usr/bin/env bash
TEST_NAME="test_rebuild"
source "$(dirname "$0")/test_lib.sh"

cd "$REPO_ROOT"

need make

# Re-run build at the currently-resolved version. The onnxruntime base image should
# already exist, so build-onnxruntime should hit its "already exists" short-circuit.
out=$(make build-onnxruntime 2>&1) \
    || { printf '%s\n' "$out" >&2; fail "$TEST_NAME" "make build-onnxruntime failed"; }

printf '%s\n' "$out" | grep -q "already exists, skipping build" \
    || fail "$TEST_NAME" "ORT base rebuild did not short-circuit (see Makefile:78-79)"

pass "$TEST_NAME"
