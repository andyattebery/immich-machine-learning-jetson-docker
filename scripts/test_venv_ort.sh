#!/usr/bin/env bash
TEST_NAME="test_venv_ort"
source "$(dirname "$0")/test_lib.sh"

cd "$REPO_ROOT"

need docker
need make

ml_image=$(make help 2>/dev/null | awk -F'=' '/^[[:space:]]*ML_IMAGE[[:space:]]*=/ {sub(/^[[:space:]]*/,"",$2); print $2; exit}')
[ -n "$ml_image" ] || fail "$TEST_NAME" "could not resolve ML_IMAGE from make help"

docker image inspect "$ml_image" >/dev/null 2>&1 \
    || fail "$TEST_NAME" "image '$ml_image' not found locally — run 'make build' first"

out=$(docker run --rm --runtime=nvidia --entrypoint /opt/venv/bin/python3 "$ml_image" \
        -c "import sys, onnxruntime; print(sys.prefix); print(onnxruntime.__version__); print(','.join(onnxruntime.get_available_providers()))" 2>&1) \
    || { printf '%s\n' "$out" >&2; fail "$TEST_NAME" "venv python failed to import onnxruntime"; }

prefix=$(printf '%s\n' "$out" | sed -n '1p')
providers=$(printf '%s\n' "$out" | sed -n '3p')

[ "$prefix" = "/opt/venv" ] \
    || fail "$TEST_NAME" "sys.prefix=$prefix, expected /opt/venv"
printf '%s\n' "$providers" | grep -q "CUDAExecutionProvider" \
    || fail "$TEST_NAME" "CUDAExecutionProvider missing from venv ORT; providers=$providers"

pass "$TEST_NAME ($providers)"
