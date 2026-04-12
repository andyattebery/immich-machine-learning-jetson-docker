# Makefile for building Immich ML for NVIDIA Jetson
#
# Usage:
#   make build                           # build using latest immich release
#   make build IMMICH_VERSION=v2.7.4    # pin a specific version
#   make up                              # start the service
#   make down                            # stop the service
#   make clean                           # remove src/ and built images

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

ORT_IMAGE ?= onnxruntime-jetson:$(ONNXRUNTIME_VERSION)

.PHONY: build resolve-version checkout detect-ort-version ort-base image up down clean help \
        test test-local test-jetson \
        test-makefile test-github-api test-ort-detect test-compose test-dockerfile test-env-example \
        test-ort-base test-venv-ort test-service test-rebuild

help:
	@echo "Targets:"
	@echo "  build    - full pipeline: checkout immich + build ORT base + build ML image"
	@echo "  ort-base - build ORT base image only (skips if already exists)"
	@echo "  up       - start the ML service via docker compose"
	@echo "  down     - stop the ML service"
	@echo "  clean    - remove src/ and built images"
	@echo "  test         - auto: runs test-local (+ test-jetson if on Jetson)"
	@echo "  test-local   - Tier 1 static checks (runs anywhere)"
	@echo "  test-jetson  - Tier 2 integration tests (Jetson only; requires 'make build')"
	@echo ""
	@echo "Variables:"
	@echo "  IMMICH_VERSION      = $(IMMICH_VERSION) (resolved: $(RESOLVED_VERSION))"
	@echo "  ONNXRUNTIME_VERSION = $(ONNXRUNTIME_VERSION)"
	@echo "  ORT_IMAGE           = $(ORT_IMAGE)"
	@echo "  ML_IMAGE            = $(ML_IMAGE)"

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

detect-ort-version: checkout
	@DETECTED=$$(grep 'onnxruntime-gpu' $(IMMICH_SRC)/machine-learning/pyproject.toml \
		| grep -oE '>=[0-9]+\.[0-9]+\.[0-9]+' | head -1 | sed 's/>=//'); \
	if [ -z "$$DETECTED" ]; then \
		echo "ERROR: Could not detect onnxruntime-gpu version from pyproject.toml"; \
		exit 1; \
	fi; \
	echo "==> Detected onnxruntime-gpu >= $$DETECTED (will use: $(ONNXRUNTIME_VERSION))"

ort-base: detect-ort-version
	@if docker image inspect $(ORT_IMAGE) >/dev/null 2>&1; then \
		echo "==> ORT base image '$(ORT_IMAGE)' already exists, skipping build"; \
	else \
		echo "==> No local ORT image '$(ORT_IMAGE)' found"; \
		echo "==> Building ORT $(ONNXRUNTIME_VERSION) via jetson-containers..."; \
		echo "    (This may take a long time on first build)"; \
		jetson-containers build onnxruntime:$(ONNXRUNTIME_VERSION); \
		echo "==> Locating built image..."; \
		BUILT_TAG=$$(docker images --format '{{.Repository}}:{{.Tag}}' \
			| grep 'onnxruntime' \
			| grep '$(ONNXRUNTIME_VERSION)' \
			| head -1); \
		if [ -z "$$BUILT_TAG" ]; then \
			echo "ERROR: Could not find built onnxruntime image with version $(ONNXRUNTIME_VERSION)"; \
			echo "       Run 'docker images | grep onnxruntime' and set ORT_IMAGE manually"; \
			exit 1; \
		fi; \
		echo "    Found: $$BUILT_TAG"; \
		docker tag "$$BUILT_TAG" $(ORT_IMAGE); \
		echo "==> Tagged as $(ORT_IMAGE)"; \
	fi

image: ort-base
	@echo "==> Building Immich ML image $(ML_IMAGE)..."
	docker build \
		-f Dockerfile.jetson \
		--build-arg ONNXRUNTIME_BASE_IMAGE=$(ORT_IMAGE) \
		--build-arg BUILD_SOURCE_REF=$(RESOLVED_VERSION) \
		-t $(ML_IMAGE) \
		$(IMMICH_SRC)/machine-learning/
	@echo "==> Built $(ML_IMAGE)"

build: image

up:
	docker compose up -d

down:
	docker compose down

clean:
	-docker rmi $(ML_IMAGE) 2>/dev/null
	-rm -rf src/

# -------- Tests --------
# Tier 1: runs anywhere, no Jetson required.
test-local: test-makefile test-github-api test-ort-detect \
            test-compose test-dockerfile test-env-example
	@echo "==> Tier 1 (local) tests passed"

test-makefile:     ; @scripts/test_makefile.sh
test-github-api:   ; @scripts/test_github_api.sh
test-ort-detect:   ; @scripts/test_ort_detect.sh
test-compose:      ; @scripts/test_compose.sh
test-dockerfile:   ; @scripts/test_dockerfile.sh
test-env-example:  ; @scripts/test_env_example.sh

# Tier 2: requires Jetson + completed `make build`.
test-jetson: test-ort-base test-venv-ort test-service test-rebuild
	@echo "==> Tier 2 (Jetson integration) tests passed"

test-ort-base:     ; @scripts/test_ort_base.sh
test-venv-ort:     ; @scripts/test_venv_ort.sh
test-service:      ; @scripts/test_service_up.sh
test-rebuild:      ; @scripts/test_rebuild.sh

# Default: auto-detect Jetson and run the appropriate tier(s).
test:
	@if [ -f /etc/nv_tegra_release ]; then \
	    $(MAKE) test-local && $(MAKE) test-jetson; \
	else \
	    echo "==> Non-Jetson host: running Tier 1 only"; \
	    $(MAKE) test-local; \
	fi
