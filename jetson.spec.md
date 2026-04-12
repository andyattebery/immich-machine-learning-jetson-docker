# Immich ML on NVIDIA Jetson

## Overview

Standalone project to build and run the Immich machine learning service on NVIDIA Jetson devices (Orin Nano, Orin NX, AGX Orin, etc.) using GPU-accelerated ONNX Runtime with CUDA.

Jetson requires a separate build because:

- Standard ONNX Runtime GPU wheels on PyPI don't support Jetson (aarch64 + CUDA)
- Jetson needs an L4T (Linux for Tegra) base image with bundled CUDA, cuDNN, and TensorRT
- No pre-built `dustynv/onnxruntime` Docker Hub image meets the `>=1.23.2` requirement (latest published is 1.22)

## Target Environment

| Component        | Version                                       |
| ---------------- | --------------------------------------------- |
| Platform         | NVIDIA Jetson (aarch64)                       |
| L4T              | R36.5.0                                       |
| JetPack          | 6.2                                           |
| CUDA             | 12.6                                          |
| Python           | >= 3.11                                       |
| ONNX Runtime GPU | >= 1.23.2 (auto-detected from immich source)  |

## Project Structure

```
immich-machine-learning-jetson-docker/
├── Makefile              # orchestrates checkout, ORT build, ML image build
├── Dockerfile.jetson     # multi-stage ML image build
├── docker-compose.yaml   # runs the ML service
├── .env.example          # example environment variables
├── .gitignore
└── jetson.spec.md        # this file
```

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│  Makefile                                                │
│                                                          │
│  1. resolve-version                                      │
│     IMMICH_VERSION=latest → curl GitHub API → v2.7.4     │
│                                                          │
│  2. checkout                                             │
│     git clone --depth 1 --branch v2.7.4 immich → src/   │
│                                                          │
│  3. detect-ort-version                                   │
│     parse pyproject.toml → onnxruntime-gpu>=1.23.2       │
│                                                          │
│  4. ort-base                                             │
│     check local image || jetson-containers build         │
│                                                          │
│  5. docker build -f Dockerfile.jetson                    │
│     ┌─────────────────────────────────────────────────┐  │
│     │  onnxruntime-jetson:1.25.0 (base image)        │  │
│     │  (L4T + Python + CUDA + cuDNN + TensorRT + ORT)│  │
│     ├─────────────────────────────────────────────────┤  │
│     │  builder stage                                  │  │
│     │  - uv sync base deps into /opt/venv            │  │
│     │    (extras not installed → no PyPI ORT pulled) │  │
│     │  - copy ORT from system site-packages → venv   │  │
│     ├─────────────────────────────────────────────────┤  │
│     │  prod stage                                     │  │
│     │  - runtime deps (tini, libgl1, etc.)            │  │
│     │  - /opt/venv from builder                       │  │
│     │  - immich_ml source from src/immich             │  │
│     │  - DEVICE=cuda → CUDAExecutionProvider          │  │
│     └─────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────┘
```

### Why no immich code changes are needed

- `CUDAExecutionProvider` is already in `SUPPORTED_PROVIDERS` (`immich_ml/models/constants.py`)
- The ORT session auto-detects available providers via `ort.get_available_providers()` (`immich_ml/sessions/ort.py`)
- The Jetson ORT build registers `CUDAExecutionProvider`, so it is selected automatically

## Prerequisites

Install [dusty-nv/jetson-containers](https://github.com/dusty-nv/jetson-containers) on the Jetson:

```bash
git clone https://github.com/dusty-nv/jetson-containers
cd jetson-containers
pip install -r requirements.txt
```

Also requires `curl` and `jq` for GitHub API version resolution.

## Build

### One-command build (recommended)

```bash
# Build using latest immich release
make build

# Or pin a specific version
make build IMMICH_VERSION=v2.7.4
```

The Makefile will:
1. Resolve `latest` to the actual release tag via GitHub API (`curl`, no `gh` CLI)
2. Shallow-clone immich at that tag into `src/immich/`
3. Parse `pyproject.toml` to detect the required `onnxruntime-gpu` version
4. Check if `onnxruntime-jetson:<version>` exists locally
5. If not, build it via `jetson-containers build onnxruntime:<version>`
6. Build the Immich ML Docker image on top of it

### Makefile targets

| Target               | Description                                            |
| -------------------- | ------------------------------------------------------ |
| `build`              | Full pipeline: resolve → checkout → ORT → ML image     |
| `image`              | Build ML image (depends on `ort-base`)                 |
| `ort-base`           | Build ORT base image only (skips if already exists)    |
| `up`                 | `docker compose up -d`                                 |
| `down`               | `docker compose down`                                  |
| `clean`              | Remove `src/` and built images                         |
| `help`               | Show targets and resolved variable values              |
| `test`               | Auto: Tier 1 always, Tier 2 if on a Jetson             |
| `test-local`         | Tier 1 static checks (any host)                        |
| `test-jetson`        | Tier 2 integration tests (Jetson, post-`make build`)   |

### Configurable variables

| Variable              | Default                   | Description                          |
| --------------------- | ------------------------- | ------------------------------------ |
| `IMMICH_VERSION`      | `latest`                  | Immich git tag, or `latest`          |
| `ONNXRUNTIME_VERSION` | (auto from pyproject.toml)| ORT version, or manual override      |
| `ORT_IMAGE`           | `onnxruntime-jetson:<ver>`| ORT base image tag                   |
| `ML_IMAGE`            | `immich-machine-learning:jetson` | Final ML image tag            |

### Verify the ORT base image

```bash
docker run --rm onnxruntime-jetson:1.25.0 \
  python3 -c "import onnxruntime; print(onnxruntime.__version__, onnxruntime.get_available_providers())"
```

Expected output should include `CUDAExecutionProvider`.

## Run

### Start the service

```bash
make up
```

Or directly:

```bash
docker compose up -d
```

### Verify

```bash
docker logs immich-machine-learning 2>&1 | grep -i "provider"
# Should show: Available ORT providers: {'CUDAExecutionProvider', 'CPUExecutionProvider'}
# Should show: Setting execution providers to ['CUDAExecutionProvider', 'CPUExecutionProvider']
```

### Upgrade to a new immich version

```bash
make build IMMICH_VERSION=latest
make up
```

## Testing

The repo includes a two-tier automated test suite, driven from the Makefile and implemented as shell scripts in `scripts/`.

### Tier 1 — local static checks (any host)

Runs on macOS or Linux without Docker builds. Requires `make`, `curl`, `jq`, and (for compose validation) the Docker CLI with the compose plugin.

```bash
make test-local
```

Checks:

| Subtarget            | Verifies                                                                  |
| -------------------- | ------------------------------------------------------------------------- |
| `test-makefile`      | `make -n build` works; `make help` resolves all variables to non-empty    |
| `test-github-api`    | GitHub API returns a valid immich release tag (`vX.Y.Z`)                  |
| `test-ort-detect`    | `make checkout detect-ort-version` extracts ORT version from pyproject    |
| `test-compose`       | `docker compose config` parses `docker-compose.yaml`                      |
| `test-dockerfile`    | `hadolint` clean (skipped if hadolint not installed)                      |
| `test-env-example`   | Every `${VAR}` in compose has either a default or a row in `.env.example` |

### Tier 2 — Jetson integration (Jetson only)

Requires a Jetson device with JetPack 6.2 and a completed `make build`. Runs the real containers and asserts runtime behavior.

```bash
make test-jetson
```

Checks:

| Subtarget       | Verifies                                                                     |
| --------------- | ---------------------------------------------------------------------------- |
| `test-ort-base` | ORT base image imports `onnxruntime` with `CUDAExecutionProvider` available  |
| `test-venv-ort` | `/opt/venv/bin/python3` in the ML image imports ORT with CUDA (copy worked)  |
| `test-service`  | `docker compose up`; logs show CUDA provider; `GET /ping` returns 200        |
| `test-rebuild`  | Re-running `make ort-base` short-circuits on the cached image                |

### Default `make test`

`make test` auto-detects the host: it runs `test-local` always, plus `test-jetson` if `/etc/nv_tegra_release` exists.

Inference smoke testing (driving a real model with a Jetson GPU spike) is intentionally kept manual — it requires an Immich server and is out of scope for the automated suite.

## Limitations

### GPU memory

The Jetson Orin Nano has 4-8 GB of shared memory (CPU + GPU). The Dockerfile sets `MACHINE_LEARNING_MODEL_ARENA=false` by default to reduce memory pressure. If you encounter OOM errors:

- Disable facial recognition in Immich settings (the face detection/recognition models are memory-intensive)
- Ensure `MACHINE_LEARNING_WORKERS=1` (default)
- Reduce `MACHINE_LEARNING_MODEL_TTL` to unload idle models sooner

### TensorRT

The Jetson ORT build may include `TensorrtExecutionProvider`, but it is not currently in Immich's `SUPPORTED_PROVIDERS` list. CUDA EP will be used instead. TensorRT support could be added as a future enhancement.

### Image size

The jetson-containers base image is large (several GB) due to bundled CUDA, cuDNN, and TensorRT libraries. This is inherent to the Jetson ecosystem.

## References

- [Immich Discussion #10647](https://github.com/immich-app/immich/discussions/10647) — Community discussion on Jetson support
- [dusty-nv/jetson-containers](https://github.com/dusty-nv/jetson-containers) — NVIDIA Jetson container build system
- [jetson-containers ONNX Runtime package](https://github.com/dusty-nv/jetson-containers/tree/master/packages/ml/onnxruntime) — ORT build configs and Dockerfile
