#!/usr/bin/env bash
TEST_NAME="test_onnxruntime_version"
source "$(dirname "$0")/test_lib.sh"

cd "$REPO_ROOT"

need make
need git

out=$(make checkout detect-onnxruntime-version 2>&1) \
    || { printf '%s\n' "$out" >&2; fail "$TEST_NAME" "make checkout detect-onnxruntime-version failed"; }

version=$(printf '%s\n' "$out" | grep -oE 'onnxruntime-gpu >= [0-9]+\.[0-9]+\.[0-9]+' | head -1 | awk '{print $NF}')

[ -n "$version" ] || fail "$TEST_NAME" "could not detect onnxruntime-gpu version in output"

pass "$TEST_NAME (detected $version)"
