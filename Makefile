# Makefile for building Immich ML for NVIDIA Jetson
#
# Usage:
#   make build                           # build using latest immich release
#   make build IMMICH_VERSION=v2.7.4    # pin a specific version
#   make up                              # start the service
#   make down                            # stop the service
#   make clean                           # remove src/, jetson-containers/, and the ML image

IMMICH_VERSION      ?= latest
IMMICH_REPO         ?= https://github.com/immich-app/immich.git
IMMICH_SRC          ?= src/immich
ML_IMAGE            ?= immich-machine-learning:jetson

# Resolve "latest" to actual tag via GitHub API (no gh CLI needed)
ifeq ($(IMMICH_VERSION),latest)
RESOLVED_VERSION := $(shell curl -sfL https://api.github.com/repos/immich-app/immich/releases/latest | jq -r .tag_name)
else
RESOLVED_VERSION := $(IMMICH_VERSION)
endif

# Detect onnxruntime-gpu minimum version from immich's pyproject.toml (after checkout)
ONNXRUNTIME_VERSION ?= $(shell [ -f $(IMMICH_SRC)/machine-learning/pyproject.toml ] && \
	grep 'onnxruntime-gpu' $(IMMICH_SRC)/machine-learning/pyproject.toml \
	| grep -oE '>=[0-9]+\.[0-9]+\.[0-9]+' \
	| head -1 | sed 's/>=//')

ORT_PYTHON_VERSION     ?= 3.11
ORT_IMAGE              ?= onnxruntime-jetson:$(ONNXRUNTIME_VERSION)-py$(subst .,,$(ORT_PYTHON_VERSION))
CUDASTACK_IMAGE        ?= onnxruntime-cudastack-jetson:$(ONNXRUNTIME_VERSION)-py$(subst .,,$(ORT_PYTHON_VERSION))

JETSON_CONTAINERS_REPO  ?= https://github.com/dusty-nv/jetson-containers
JETSON_CONTAINERS_FLAGS  ?= --skip-tests all
JETSON_CONTAINERS_DIR  ?= src/jetson-containers
JETSON_VENV            := $(JETSON_CONTAINERS_DIR)/venv
SWAP_FILE              ?= /mnt/16GB.swap
SWAP_SIZE              ?= 16G
# Use mise-managed Python if available, otherwise fall back to system python3
PYTHON                 := $(if $(shell command -v mise 2>/dev/null),mise exec -- python,python3)

# Put the repo dir on PATH so the `jetson-containers` shell script is found by all recipes
export PATH := $(CURDIR)/$(JETSON_CONTAINERS_DIR):$(PATH)

.DEFAULT_GOAL := help

.PHONY: build resolve-version checkout detect-onnxruntime-version build-onnxruntime build-immich generate-dockerfile \
        up down clean clean-all help \
        setup-host \
        test test-local test-jetson \
        test-makefile test-github-api test-onnxruntime-version test-compose test-dockerfile test-env-example \
        test-onnxruntime-base test-onnxruntime-venv test-service test-rebuild


help:
	@echo "Targets:"
	@echo "  setup-host          - one-time Jetson host setup: nvidia Docker runtime + swap (requires sudo)"
	@echo "  build               - full pipeline: checkout immich + build onnxruntime + build immich image"
	@echo "  build-immich        - build Immich ML image only (skips onnxruntime build; useful for iteration)"
	@echo "  build-onnxruntime   - build onnxruntime base image only (skips if already exists)"
	@echo "  generate-dockerfile - generate Dockerfile.generated from upstream immich prod stage"
	@echo "  up                  - start the ML service via docker compose"
	@echo "  down                - stop the ML service"
	@echo "  clean               - remove src/ and the ML image (preserves onnxruntime image)"
	@echo "  clean-all           - clean + remove onnxruntime images (full reset; rebuild takes hours)"
	@echo "  test                - auto: runs test-local (+ test-jetson if on Jetson)"
	@echo "  test-local          - Tier 1 static checks (runs anywhere)"
	@echo "  test-jetson         - Tier 2 integration tests (Jetson only; requires 'make build')"
	@echo ""
	@echo "Variables:"
	@echo "  IMMICH_VERSION      = $(IMMICH_VERSION) (resolved: $(RESOLVED_VERSION))"
	@echo "  ONNXRUNTIME_VERSION = $(ONNXRUNTIME_VERSION)"
	@echo "  ORT_IMAGE           = $(ORT_IMAGE)"
	@echo "  ML_IMAGE            = $(ML_IMAGE)"

# ---- One-time host setup (requires sudo) ----
# Sets the two prerequisites documented at https://github.com/dusty-nv/jetson-containers/blob/master/docs/setup.md
# before jetson-containers build will succeed:
#   1. nvidia default Docker runtime  (needed so NVCC/GPU are available during docker build)
#   2. 16 GB swap file                (needed so ORT CUDA compilation doesn't OOM)
setup-host:
	@echo "==> [1/2] Configuring Docker default runtime to nvidia..."
	@if sudo docker info 2>/dev/null | grep -q 'Default Runtime: nvidia'; then \
		echo "    Already set to nvidia, skipping"; \
	else \
		DAEMON=/etc/docker/daemon.json; \
		if [ -f "$$DAEMON" ]; then \
			sudo python3 -c " \
import json, sys; \
d = json.load(open('$$DAEMON')); \
d.setdefault('runtimes', {})['nvidia'] = {'path': 'nvidia-container-runtime', 'runtimeArgs': []}; \
d['default-runtime'] = 'nvidia'; \
json.dump(d, open('$$DAEMON', 'w'), indent=4); \
print('    Updated existing $$DAEMON') \
"; \
		else \
			echo '    Creating $$DAEMON'; \
			echo '{\n    "runtimes": {\n        "nvidia": {\n            "path": "nvidia-container-runtime",\n            "runtimeArgs": []\n        }\n    },\n    "default-runtime": "nvidia"\n}' | sudo tee $$DAEMON > /dev/null; \
		fi; \
		echo "    Restarting Docker..."; \
		sudo systemctl restart docker; \
		sudo docker info 2>/dev/null | grep 'Default Runtime'; \
	fi
	@echo ""
	@echo "==> [2/2] Configuring swap ($(SWAP_SIZE) at $(SWAP_FILE))..."
	@if swapon --show | grep -q '$(SWAP_FILE)'; then \
		echo "    Swap file $(SWAP_FILE) already active, skipping"; \
	else \
		if [ ! -f $(SWAP_FILE) ]; then \
			echo "    Disabling ZRAM..."; \
			sudo systemctl disable nvzramconfig 2>/dev/null || true; \
			sudo swapoff -a 2>/dev/null || true; \
			echo "    Creating $(SWAP_SIZE) swap at $(SWAP_FILE)..."; \
			sudo fallocate -l $(SWAP_SIZE) $(SWAP_FILE); \
			sudo chmod 600 $(SWAP_FILE); \
			sudo mkswap $(SWAP_FILE); \
		fi; \
		sudo swapon $(SWAP_FILE); \
		echo "    Adding to /etc/fstab (idempotent)..."; \
		grep -qF '$(SWAP_FILE)' /etc/fstab || echo '$(SWAP_FILE)  none  swap  sw  0  0' | sudo tee -a /etc/fstab > /dev/null; \
		if ! swapon --show | grep -q '$(SWAP_FILE)'; then \
			echo "ERROR: swap file $(SWAP_FILE) is not active after swapon"; \
			exit 1; \
		fi; \
		echo "    Swap active:"; \
		free -h | grep Swap; \
	fi
	@echo ""
	@echo "==> Host setup complete. You can now run: make build"

resolve-version:
	@if [ -z "$(RESOLVED_VERSION)" ] || [ "$(RESOLVED_VERSION)" = "null" ]; then \
		echo "ERROR: Could not resolve IMMICH_VERSION=$(IMMICH_VERSION)"; \
		exit 1; \
	fi
	@echo "==> Immich version: $(RESOLVED_VERSION)"

checkout: resolve-version
	@if [ -d $(IMMICH_SRC)/.git ]; then \
		CURRENT=$$(cd $(IMMICH_SRC) && git describe --tags --exact-match 2>/dev/null || echo ""); \
		if [ "$$CURRENT" = "$(RESOLVED_VERSION)" ]; then \
			echo "==> $(IMMICH_SRC) already at $(RESOLVED_VERSION)"; \
		else \
			echo "==> Updating $(IMMICH_SRC) to $(RESOLVED_VERSION)..."; \
			cd $(IMMICH_SRC) && git fetch --depth 1 origin tag $(RESOLVED_VERSION) && git checkout $(RESOLVED_VERSION); \
		fi; \
	else \
		echo "==> Cloning immich at $(RESOLVED_VERSION)..."; \
		mkdir -p $(dir $(IMMICH_SRC)); \
		git clone --depth 1 --branch $(RESOLVED_VERSION) $(IMMICH_REPO) $(IMMICH_SRC); \
	fi

detect-onnxruntime-version: checkout
	@DETECTED=$$(grep 'onnxruntime-gpu' $(IMMICH_SRC)/machine-learning/pyproject.toml \
		| grep -oE '>=[0-9]+\.[0-9]+\.[0-9]+' | head -1 | sed 's/>=//'); \
	if [ -z "$$DETECTED" ]; then \
		echo "ERROR: Could not detect onnxruntime-gpu version from pyproject.toml"; \
		exit 1; \
	fi; \
	echo "==> Detected onnxruntime-gpu >= $$DETECTED (will use: $(ONNXRUNTIME_VERSION))"

build-onnxruntime: detect-onnxruntime-version
	@if docker image inspect $(ORT_IMAGE) >/dev/null 2>&1; then \
		echo "==> onnxruntime image '$(ORT_IMAGE)' already exists, skipping build"; \
	else \
		echo "==> No local onnxruntime image '$(ORT_IMAGE)' found"; \
		if [ ! -f $(JETSON_VENV)/.done ]; then \
			if [ ! -d $(JETSON_CONTAINERS_DIR)/.git ]; then \
				echo "==> Cloning jetson-containers..."; \
				git clone --depth 1 $(JETSON_CONTAINERS_REPO) $(JETSON_CONTAINERS_DIR); \
			fi; \
			echo "==> Creating jetson-containers venv at $(JETSON_VENV) using $(PYTHON)..."; \
			if [ "$(PYTHON)" = "python3" ] && ! python3 -m venv --help >/dev/null 2>&1; then \
				echo "==> Installing python3-venv (required for system Python venv creation)..."; \
				sudo apt-get install -y python3-venv; \
			fi; \
			$(PYTHON) -m venv $(JETSON_VENV); \
			$(JETSON_VENV)/bin/pip install --upgrade pip --quiet; \
			$(JETSON_VENV)/bin/pip install -r $(JETSON_CONTAINERS_DIR)/requirements.txt; \
			touch $(JETSON_VENV)/.done; \
		fi; \
		echo "==> Building onnxruntime $(ONNXRUNTIME_VERSION) via jetson-containers..."; \
		echo "    (This may take a long time on first build)"; \
		jetson-containers build python:$(ORT_PYTHON_VERSION) onnxruntime:$(ONNXRUNTIME_VERSION) $(JETSON_CONTAINERS_FLAGS); \
		echo "==> Locating built image..."; \
		BUILT_TAG=$$(docker images --format '{{.Repository}}:{{.Tag}}' \
			| grep '^onnxruntime:' \
			| grep -- '-onnxruntime_$(ONNXRUNTIME_VERSION)$$' \
			| head -1); \
		if [ -z "$$BUILT_TAG" ]; then \
			echo "ERROR: Could not find final onnxruntime image (expected tag suffix: -onnxruntime_$(ONNXRUNTIME_VERSION))"; \
			echo "       The onnxruntime source compilation likely failed or was killed (OOM)."; \
			echo "       Tip: add swap space before retrying (see README.md)."; \
			echo "       Run 'docker images | grep onnxruntime' to inspect, or set ORT_IMAGE manually."; \
			exit 1; \
		fi; \
		echo "    Found: $$BUILT_TAG"; \
		docker tag "$$BUILT_TAG" $(ORT_IMAGE); \
		echo "==> Tagged as $(ORT_IMAGE)"; \
	fi
	@if docker image inspect $(CUDASTACK_IMAGE) >/dev/null 2>&1; then \
		echo "==> Cudastack image '$(CUDASTACK_IMAGE)' already exists, skipping tag"; \
	else \
		CUDASTACK_TAG=$$(docker images --format '{{.Repository}}:{{.Tag}}' \
			| grep '^onnxruntime:' \
			| grep -- '-cudastack_standard$$' \
			| head -1); \
		if [ -z "$$CUDASTACK_TAG" ]; then \
			echo "ERROR: Could not find cudastack_standard intermediate image"; \
			exit 1; \
		fi; \
		docker tag "$$CUDASTACK_TAG" $(CUDASTACK_IMAGE); \
		echo "==> Tagged prod base as $(CUDASTACK_IMAGE)"; \
	fi

generate-dockerfile: checkout
	@echo "==> Generating Dockerfile.generated from upstream prod stage..."
	$(PYTHON) scripts/generate_dockerfile.py \
		--builder Dockerfile.builder \
		--upstream $(IMMICH_SRC)/machine-learning/Dockerfile \
		--version $(RESOLVED_VERSION) \
		--output Dockerfile.generated

build-immich: generate-dockerfile build-onnxruntime
	@CURRENT=$$(docker inspect $(ML_IMAGE) \
		--format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
		| awk -F= '/^IMMICH_SOURCE_REF=/{print $$2}'); \
	if [ "$$CURRENT" = "$(RESOLVED_VERSION)" ]; then \
		echo "==> ML image already at $(RESOLVED_VERSION), skipping build"; \
	else \
		echo "==> Building Immich ML image $(ML_IMAGE)..."; \
		docker build \
			-f Dockerfile.generated \
			--build-arg ONNXRUNTIME_BASE_IMAGE=$(ORT_IMAGE) \
			--build-arg PROD_BASE_IMAGE=$(CUDASTACK_IMAGE) \
			--build-arg BUILD_SOURCE_REF=$(RESOLVED_VERSION) \
			-t $(ML_IMAGE) \
			$(IMMICH_SRC)/machine-learning/ && \
		echo "==> Built $(ML_IMAGE)"; \
	fi

build: build-immich

up:
	docker compose up -d

down:
	docker compose down

clean:
	-docker rmi $(ML_IMAGE) 2>/dev/null
	-rm -rf src/

# Removes everything including all ORT base images. Use when you need a true fresh start.
# Warning: the ORT image takes 1-2 hours to rebuild from source.
# Matches by prefix (onnxruntime-jetson:*) so it works even when ONNXRUNTIME_VERSION
# is empty (e.g. after clean has already removed src/).
clean-all: clean
	-docker images --format '{{.Repository}}:{{.Tag}}' \
		| grep -E '^onnxruntime-(jetson|cudastack-jetson):' | xargs -r docker rmi 2>/dev/null || true

# -------- Tests --------
# Tier 1: runs anywhere, no Jetson required.
test-local: test-makefile test-github-api test-onnxruntime-version \
            test-compose test-dockerfile test-env-example
	@echo "==> Tier 1 (local) tests passed"

test-makefile:            ; @scripts/test_makefile.sh
test-github-api:          ; @scripts/test_github_api.sh
test-onnxruntime-version: ; @scripts/test_ort_detect.sh
test-compose:             ; @scripts/test_compose.sh
test-dockerfile:          ; @scripts/test_dockerfile.sh
test-env-example:         ; @scripts/test_env_example.sh

# Tier 2: requires Jetson + completed `make build`.
test-jetson: test-onnxruntime-base test-onnxruntime-venv test-service test-rebuild
	@echo "==> Tier 2 (Jetson integration) tests passed"

test-onnxruntime-base: ; @scripts/test_ort_base.sh
test-onnxruntime-venv: ; @scripts/test_venv_ort.sh
test-service:          ; @scripts/test_service_up.sh
test-rebuild:          ; @scripts/test_rebuild.sh

# Default: auto-detect Jetson and run the appropriate tier(s).
test:
	@if [ -f /etc/nv_tegra_release ]; then \
	    $(MAKE) test-local && $(MAKE) test-jetson; \
	else \
	    echo "==> Non-Jetson host: running Tier 1 only"; \
	    $(MAKE) test-local; \
	fi
