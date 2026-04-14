#!/usr/bin/env bash
TEST_NAME="test_ort_base"
source "$(dirname "$0")/test_lib.sh"

cd "$REPO_ROOT"

need docker
need make

ort_image=$(make help 2>/dev/null | awk -F'=' '/^[[:space:]]*ORT_IMAGE[[:space:]]*=/ {sub(/^[[:space:]]*/,"",$2); print $2; exit}')
[ -n "$ort_image" ] || fail "$TEST_NAME" "could not resolve ORT_IMAGE from make help"

docker image inspect "$ort_image" >/dev/null 2>&1 \
    || fail "$TEST_NAME" "image '$ort_image' not found locally — run 'make build-onnxruntime' first"

out=$(docker run --rm --runtime=nvidia "$ort_image" \
        python3 -c "import onnxruntime; print(onnxruntime.__version__); print(','.join(onnxruntime.get_available_providers()))" 2>&1) \
    || { printf '%s\n' "$out" >&2; fail "$TEST_NAME" "container failed to import onnxruntime"; }

providers=$(printf '%s\n' "$out" | tail -1)
printf '%s\n' "$providers" | grep -q "CUDAExecutionProvider" \
    || fail "$TEST_NAME" "CUDAExecutionProvider missing; providers=$providers"

pass "$TEST_NAME ($ort_image: $providers)"
