# Immich ML on NVIDIA Jetson

## Overview

Standalone project to build and run the Immich machine learning service on NVIDIA Jetson devices (Orin Nano, Orin NX, AGX Orin, etc.) using GPU-accelerated ONNX Runtime with CUDA.

Jetson requires a separate build because:

- Standard ONNX Runtime GPU wheels on PyPI don't support Jetson (aarch64 + CUDA)
- Jetson needs an L4T (Linux for Tegra) base image with bundled CUDA, cuDNN, and TensorRT
- No pre-built `dustynv/onnxruntime` Docker Hub image meets the `>=1.23.2` requirement (latest published is 1.22)
- ORT must be compiled against Python 3.11 to match Immich's `requires-python = ">=3.11"` constraint

## Target Environment

| Component        | Version                                       |
| ---------------- | --------------------------------------------- |
| Platform         | NVIDIA Jetson (aarch64)                       |
| L4T              | R36.5.0                                       |
| JetPack          | 6.2                                           |
| CUDA             | 12.6                                          |
| Python           | 3.11                                          |
| ONNX Runtime GPU | >= 1.23.2 (auto-detected from immich source)  |

## Project Structure

```
immich-machine-learning-jetson-docker/
├── Makefile              # orchestrates checkout, ORT build, ML image build
├── Dockerfile.jetson     # multi-stage ML image build
├── docker-compose.yaml   # runs the ML service
├── .env.example          # example environment variables
├── .gitignore
├── README.md             # this file
└── src/                  # cloned external repos (gitignored)
    ├── immich/           # checked out by `make checkout`
    └── jetson-containers/ # cloned automatically by `make build-onnxruntime`
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
│  3. detect-onnxruntime-version                           │
│     parse pyproject.toml → onnxruntime-gpu>=1.23.2       │
│                                                          │
│  4. build-onnxruntime                                    │
│     check local image || clone jetson-containers + build │
│     (chains python:3.11 → onnxruntime:VERSION)           │
│     tags final image as onnxruntime-jetson:VERSION-py311 │
│     tags cudastack intermediate as                       │
│       onnxruntime-cudastack-jetson:VERSION-py311         │
│                                                          │
│  6. docker build -f Dockerfile.jetson                    │
│     ┌─────────────────────────────────────────────────┐  │
│     │  builder stage                                  │  │
│     │  base: onnxruntime-jetson:VERSION-py311         │  │
│     │  (L4T + Python 3.11 + CUDA + cuDNN + TRT + ORT)│  │
│     │  - python3.11 -m venv --clear /opt/venv         │  │
│     │    (guarantees Python 3.11 ABI in venv)         │  │
│     │  - uv sync immich deps into /opt/venv           │  │
│     │  - uv pip install /opt/onnxruntime*.whl         │  │
│     │    (reinstates the Jetson GPU wheel)            │  │
│     ├─────────────────────────────────────────────────┤  │
│     │  prod stage                                     │  │
│     │  base: onnxruntime-cudastack-jetson:VERSION-py311│ │
│     │  (L4T + Python 3.11 + CUDA + cuDNN + TRT only) │  │
│     │  - runtime deps (tini, libgl1, etc.)            │  │
│     │  - /opt/venv from builder                       │  │
│     │  - immich_ml source from src/immich             │  │
│     │  - DEVICE=cuda → CUDAExecutionProvider          │  │
│     └─────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────┘
```

### Why two base images

The jetson-containers build produces intermediate images for each stage in the dependency chain. The final ORT image (`onnxruntime-jetson:VERSION-py311`) contains cmake, numpy, onnx, the full ORT source tree, and CMake build artifacts — none of which are needed at runtime. The `cudastack_standard` intermediate image has only CUDA + cuDNN + TRT runtime, saving ~8GB in the final ML image.

- **builder** uses the full ORT image: needs `python3.11` and `/opt/onnxruntime*.whl`
- **prod** uses the cudastack image: needs only the CUDA/cuDNN/TRT runtime libraries

### Why Python 3.11 must be in the ORT build chain

Ubuntu 22.04 (JetPack 6.2) defaults to Python 3.10. ORT C extension modules (`.so` files) carry a Python ABI tag (`cp310` vs `cp311`) and cannot be loaded across versions. Immich requires `>=3.11`, so the jetson-containers build chain must include `python:3.11` before `onnxruntime:VERSION` to compile everything against 3.11.

The Dockerfile also explicitly recreates `/opt/venv` with `python3.11 -m venv --clear /opt/venv` in the builder stage. This guarantees the correct ABI regardless of what the base image's venv was built with.

### Why no immich code changes are needed

- `CUDAExecutionProvider` is already in `SUPPORTED_PROVIDERS` (`immich_ml/models/constants.py`)
- The ORT session auto-detects available providers via `ort.get_available_providers()` (`immich_ml/sessions/ort.py`)
- The Jetson ORT build registers `CUDAExecutionProvider`, so it is selected automatically

## Prerequisites

Requires `curl` and `jq` for GitHub API version resolution. The Makefile handles everything else automatically — but two host-level settings must be configured before the first build.

### One-time host setup (run once, then never again)

```bash
sudo make setup-host
```

This target (idempotent — safe to re-run) configures:

1. **Docker default runtime → nvidia** — required so NVCC and the GPU are available during `docker build`. Without this the jetson-containers GPU tests and ORT CUDA compilation fail.

2. **16 GB swap file** — required because ORT CUDA kernel compilation spawns up to 6 parallel jobs (`-j$(nproc)`), each using 4–8 GB, easily exceeding the 8 GB unified RAM on Orin Nano/NX. Without swap the build is OOM-killed (exit code 137).

The swap file is created at `/mnt/16GB.swap` and added to `/etc/fstab` for persistence. Location and size can be overridden:

```bash
sudo make setup-host SWAP_FILE=/nvme/swap SWAP_SIZE=32G
```

## Build

### First-time setup

```bash
sudo make setup-host   # configure nvidia runtime + swap (once)
make build             # full pipeline; takes 1-2 hours on first run (ORT compilation)
```

### Subsequent builds / version upgrades

```bash
make build IMMICH_VERSION=latest   # picks up new immich release
make up                            # restart the service
```

The Makefile will:
1. Resolve `latest` to the actual release tag via GitHub API (`curl`, no `gh` CLI)
2. Shallow-clone immich at that tag into `src/immich/`
3. Parse `pyproject.toml` to detect the required `onnxruntime-gpu` version
4. Clone jetson-containers and set up its Python venv (skipped if already done)
5. Check if `onnxruntime-jetson:<version>-py311` exists locally
6. If not, clone jetson-containers, compile onnxruntime via `jetson-containers build python:3.11 onnxruntime:<version>`, and tag the cudastack intermediate
7. Build the Immich ML Docker image using the full onnxruntime image as builder base and the cudastack image as prod base

### Makefile targets

| Target                   | Description                                                                    |
| ------------------------ | ------------------------------------------------------------------------------ |
| `setup-host`             | One-time: nvidia Docker runtime + 16 GB swap (requires `sudo`)                 |
| `build`                  | Full pipeline: resolve → checkout → onnxruntime → ML image                     |
| `build-immich`           | Build ML image only (skips onnxruntime build; useful for iteration)            |
| `build-onnxruntime`      | Build onnxruntime base image only; also tags cudastack intermediate (skips if exists) |
| `up`                     | `docker compose up -d`                                                         |
| `down`                   | `docker compose down`                                                          |
| `clean`                  | Remove `src/` and the ML image (preserves onnxruntime image)                   |
| `clean-all`              | `clean` + remove all `onnxruntime-jetson:*` and `onnxruntime-cudastack-jetson:*` images |
| `help`                   | Show targets and resolved variable values                                      |
| `test`                   | Auto: Tier 1 always, Tier 2 if on a Jetson                                     |
| `test-local`             | Tier 1 static checks (any host)                                                |
| `test-jetson`            | Tier 2 integration tests (Jetson, post-`make build`)                           |

### Configurable variables

| Variable                  | Default                                    | Description                                      |
| ------------------------- | ------------------------------------------ | ------------------------------------------------ |
| `IMMICH_VERSION`          | `latest`                                   | Immich git tag, or `latest`                      |
| `ONNXRUNTIME_VERSION`     | (auto from pyproject.toml)                 | ORT version, or manual override                  |
| `ORT_PYTHON_VERSION`      | `3.11`                                     | Python version for ORT compilation and venv      |
| `ORT_IMAGE`               | `onnxruntime-jetson:<ver>-py311`           | Full ORT build image tag (builder base)          |
| `CUDASTACK_IMAGE`         | `onnxruntime-cudastack-jetson:<ver>-py311` | Cudastack runtime image tag (prod base)          |
| `ML_IMAGE`                | `immich-machine-learning:jetson`           | Final ML image tag                               |
| `JETSON_CONTAINERS_FLAGS` | `--skip-tests all`                         | Flags passed to `jetson-containers build`        |
| `SWAP_FILE`               | `/mnt/16GB.swap`                           | Swap file path for `setup-host`                  |
| `SWAP_SIZE`               | `16G`                                      | Swap file size for `setup-host`                  |

### Verify the ORT base image

```bash
docker run --rm onnxruntime-jetson:1.23.2-py311 \
  python3 -c "import onnxruntime; print(onnxruntime.__version__, onnxruntime.get_available_providers())"
```

Expected output should include `CUDAExecutionProvider`.

### Protecting ORT images from docker prune

`docker image prune` (without `-a`) only removes untagged images — the ORT and cudastack images are safe. `docker image prune -a` or `docker system prune -a` will remove them since no running container references them.

To protect the ORT image from aggressive prune, create a sentinel container:

```bash
docker create --name ort-pin onnxruntime-jetson:1.23.2-py311 true
```

Only `onnxruntime-jetson:*` needs protecting. The cudastack image is trivially recreatable from the ORT image via `make build-onnxruntime` (seconds, no recompilation).

## Run

### Start the service

```bash
make up
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

If the new immich version requires a newer `onnxruntime-gpu`, the Makefile will detect the new version, find no matching `onnxruntime-jetson:*-py311` image, and rebuild ORT automatically.

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
| `test-onnxruntime-version` | `make checkout detect-onnxruntime-version` extracts ORT version from pyproject |
| `test-compose`       | `docker compose config` parses `docker-compose.yaml`                      |
| `test-dockerfile`    | `hadolint` clean (skipped if hadolint not installed)                      |
| `test-env-example`   | Every `${VAR}` in compose has either a default or a row in `.env.example` |

### Tier 2 — Jetson integration (Jetson only)

Requires a Jetson device with JetPack 6.2 and a completed `make build`. Runs the real containers and asserts runtime behavior.

```bash
make test-jetson
```

Checks:

| Subtarget                  | Verifies                                                                     |
| -------------------------- | ---------------------------------------------------------------------------- |
| `test-onnxruntime-base`    | ORT base image imports `onnxruntime` with `CUDAExecutionProvider` available  |
| `test-onnxruntime-venv`    | `/opt/venv/bin/python3` in the ML image imports ORT with CUDA                |
| `test-service`             | `docker compose up`; logs show CUDA provider; `GET /ping` returns 200        |
| `test-rebuild`             | Re-running `make build-onnxruntime` short-circuits on the cached image       |

### Default `make test`

`make test` auto-detects the host: it runs `test-local` always, plus `test-jetson` if `/etc/nv_tegra_release` exists.

Inference smoke testing (driving a real model with a Jetson GPU spike) is intentionally kept manual — it requires an Immich server and is out of scope for the automated suite.

## Limitations

### ORT compilation time

There are no pre-built ORT tarballs for JetPack 6.2 / CUDA 12.6 at `apt.jetson-ai-lab.io`. Every version (`>=1.23.2`) falls back to full source compilation, which takes **1–2 hours** on Jetson hardware. This is a one-time cost per ORT version; subsequent `make build` runs skip it if the tagged image already exists.

### GPU memory

The Jetson Orin Nano has 4–8 GB of shared memory (CPU + GPU). The Dockerfile sets `MACHINE_LEARNING_MODEL_ARENA=false` by default to reduce memory pressure. If you encounter OOM errors at runtime:

- Disable facial recognition in Immich settings (face detection/recognition models are memory-intensive)
- Ensure `MACHINE_LEARNING_WORKERS=1` (default)
- Reduce `MACHINE_LEARNING_MODEL_TTL` to unload idle models sooner

### TensorRT

The Jetson ORT build may include `TensorrtExecutionProvider`, but it is not currently in Immich's `SUPPORTED_PROVIDERS` list. CUDA EP will be used instead. TensorRT support could be added as a future enhancement.

### Image size

The final `immich-machine-learning:jetson` image is ~19GB uncompressed (~6.6GB compressed). The dominant cost is the L4T base with CUDA, cuDNN, and TensorRT runtime libraries — inherent to the Jetson ecosystem. The prod stage uses the `cudastack_standard` intermediate image rather than the full ORT build image, which avoids carrying cmake, numpy, onnx, and ORT source/build artifacts (~8GB savings over a naive build).

## References

- [Immich Discussion #10647](https://github.com/immich-app/immich/discussions/10647) — Community discussion on Jetson support
- [dusty-nv/jetson-containers](https://github.com/dusty-nv/jetson-containers) — NVIDIA Jetson container build system
- [jetson-containers ONNX Runtime package](https://github.com/dusty-nv/jetson-containers/tree/master/packages/ml/onnxruntime) — ORT build configs and Dockerfile
- [jetson-containers setup docs](https://github.com/dusty-nv/jetson-containers/blob/master/docs/setup.md) — Required host configuration (nvidia runtime, swap)
