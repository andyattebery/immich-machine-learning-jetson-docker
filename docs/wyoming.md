# Building `wyoming-whisper` / `wyoming-piper` on top of the existing ORT image

This project's `make build` compiles `onnxruntime` from source (1–2 hours on a
Jetson Orin) and tags the result as `onnxruntime-jetson:<ver>-py311`. That same
image is a valid base for the `wyoming-whisper` and `wyoming-piper` packages
shipped in the vendored [jetson-containers](../vendor/jetson-containers/packages/smart-home/wyoming/)
tree, so you can build either without re-compiling CUDA, cudastack, python, or
onnxruntime.

Everything below applies to both packages. Where the two differ, the
wyoming-specific column is called out.

| | wyoming-whisper | wyoming-piper |
| --- | --- | --- |
| Upstream project | `rhasspy/wyoming-faster-whisper` | `rhasspy/wyoming-piper` |
| TTS/STT engine | `faster-whisper` | `piper1-tts` |
| Default service port | `10300` | `10200` |
| GPU flag | `--device cuda` (always on) | `PIPER_USE_CUDA=true` (env-gated) |
| Healthcheck match string | `faster-whisper` | `piper` |

## Prerequisites

- `make build` (or at least `make build-onnxruntime`) has completed successfully.
- `docker images | grep onnxruntime-jetson` lists an `onnxruntime-jetson:<ver>-py311` tag.
- The `vendor/jetson-containers/venv/` virtualenv exists (created by `make build-onnxruntime`).

## Why this works

- **Python**: the ORT image is built on Python 3.11. `wyoming-whisper`,
  `wyoming-piper`, and their upstream engines (`faster-whisper`, `piper1-tts`)
  declare the generic `python` dependency with no explicit version pin, so 3.11
  is accepted.
- **ORT version**: neither [`faster-whisper`'s install
  step](../vendor/jetson-containers/packages/speech/faster-whisper/install.sh) nor
  `piper1-tts` pins `onnxruntime`, so whichever version the Makefile detected
  from Immich's `pyproject.toml` (typically 1.22.x or newer) is fine.
- **CUDA / L4T / cudastack**: already baked into the ORT image, so there is no
  drift risk when reusing it on the same host.

## Build command

### Recommended: `make build-wyoming-whisper` / `make build-wyoming-piper`

The Makefile ships two wrapper targets that handle everything end-to-end:

```bash
make build-wyoming-whisper
# or
make build-wyoming-piper
```

Both are thin wrappers around a shared `build-wyoming` recipe; everything
below applies to either.

What each does, in order:

1. Runs `build-onnxruntime` if needed, so the `$(ORT_IMAGE)` base exists.
2. Refreshes `vendor/jetson-containers/` to the latest upstream master
   (via the shared `update-jetson-containers` helper).
3. Reads the wyoming-`<pkg>` version registered as `default=True` in
   `vendor/jetson-containers/packages/smart-home/wyoming/wyoming-<pkg>/config.py`.
4. Skips the build if a `wyoming-<pkg>:<version>-*` image already exists.
5. Otherwise runs `jetson-containers build --base $(ORT_IMAGE) --skip-packages
   "cuda*,cudastack*,python,numpy,onnxruntime" --skip-tests all wyoming-<pkg>`.
6. When `PKG=whisper`, layers `zeroconf` onto the final image (see
   [Known upstream issues](#known-upstream-issues)).
7. Prints the resulting image tag(s).

The image is tagged with the stable L4T-prefix form (e.g.
`wyoming-whisper:r36.5.tegra-aarch64-cu126-22.04` or
`wyoming-piper:r36.5.tegra-aarch64-cu126-22.04`) — the upstream version is
not in the tag, so downstream references (e.g. docker-compose) stay stable
across upstream bumps. The resolved version is baked into the image as
`WYOMING_WHISPER_VERSION` / `WYOMING_PIPER_VERSION`, which the skip logic
reads via `docker history` to decide whether to rebuild.

### Manual equivalent

If you want to run the build yourself, e.g. with a custom `--base` or
different skip patterns, run from the project root (substitute `$PKG` with
`whisper` or `piper`):

```bash
# Put the jetson-containers CLI on PATH and activate its venv
source vendor/jetson-containers/venv/bin/activate
export PATH="$PWD/vendor/jetson-containers:$PATH"

# Resolve the exact ORT image tag produced by `make build`
ORT_IMAGE=$(docker images --format '{{.Repository}}:{{.Tag}}' \
    | grep '^onnxruntime-jetson:' | head -1)
echo "Using base: $ORT_IMAGE"

# Build wyoming-$PKG on top of the existing ORT image
PKG=whisper   # or: PKG=piper
jetson-containers build \
    --base "$ORT_IMAGE" \
    --skip-packages "cuda*,cudastack*,python,numpy,onnxruntime" \
    --skip-tests all \
    wyoming-$PKG
```

For `wyoming-whisper`, remember to layer `zeroconf` afterward (see
[Known upstream issues](#known-upstream-issues)) — `make build-wyoming-whisper`
does this automatically.

## Under the hood

### What `--base` and `--skip-packages` do

- `--base <image>` replaces the default L4T base image for the **first**
  Dockerfile in the chain, so the build starts from your pre-built ORT image.
- `--skip-packages "<patterns>"` removes matching packages from the resolved
  dependency graph. This prevents `jetson-containers` from rebuilding layers
  that are already present in the base image.

The build system does **not** auto-detect already-built dependencies — without
these flags every layer from CUDA up would be rebuilt from scratch.

### What still gets built on top of the ORT base

**wyoming-whisper:**

- `ctranslate2`
- `huggingface_hub`
- `homeassistant-base`
- `faster-whisper`
- `wyoming-whisper`

**wyoming-piper:**

- `homeassistant-base`
- `piper1-tts`
- `wyoming-piper`

## Building the newest version

The vendored jetson-containers checkout in `vendor/jetson-containers/` is
refreshed to upstream master by every `make build-*` target that uses it
(via the `update-jetson-containers` helper in the Makefile), so re-running
`make build-wyoming-whisper` or `make build-wyoming-piper` is enough to pick
up newer upstream releases. No edits inside `vendor/jetson-containers/` are
needed.

If you want to refresh the checkout without rebuilding, the manual
equivalent is:

```bash
# Convert the shallow clone to a full one (only needed the first time)
git -C vendor/jetson-containers fetch --unshallow 2>/dev/null || true

# Pull the newest upstream master
git -C vendor/jetson-containers pull --ff-only origin master

# Inspect which version is now registered as default
grep -E 'create_package\(' \
    vendor/jetson-containers/packages/smart-home/wyoming/wyoming-whisper/config.py
grep -E 'create_package\(' \
    vendor/jetson-containers/packages/smart-home/wyoming/wyoming-piper/config.py
```

Re-running `make build-wyoming-whisper` or `make build-wyoming-piper` then
produces an image tagged with the resolved version.

Upstream bumps can also change `faster-whisper`, `ctranslate2`, `piper1-tts`,
`numpy`, etc. Those packages will rebuild on top of the ORT base — much
faster than rebuilding ORT, but no longer free. Note also that `git pull
--ff-only` refuses to merge if you have local commits in
`vendor/jetson-containers/`; resolve those first or re-clone the directory.

## Verification

1. Confirm the final image was produced:
   ```bash
   docker images | grep wyoming-whisper
   docker images | grep wyoming-piper
   ```

2. Smoke-test the Python stack inside each image:
   ```bash
   # whisper
   docker run --rm --runtime nvidia <wyoming-whisper-image> \
       python3 -c 'import faster_whisper, onnxruntime; \
                   print(onnxruntime.__version__, faster_whisper.__version__)'

   # piper
   docker run --rm --runtime nvidia <wyoming-piper-image> \
       python3 -c 'import wyoming_piper, onnxruntime; \
                   print(onnxruntime.__version__, wyoming_piper.__version__)'
   ```

3. Optionally run the service and hit its healthcheck:
   ```bash
   # whisper (port 10300)
   docker run --rm --runtime nvidia -p 10300:10300 <wyoming-whisper-image> &
   sleep 30
   echo '{ "type": "describe" }' | nc -w 1 localhost 10300 | grep faster-whisper

   # piper (port 10200)
   docker run --rm --runtime nvidia -p 10200:10200 <wyoming-piper-image> &
   sleep 30
   echo '{ "type": "describe" }' | nc -w 1 localhost 10200 | grep piper
   ```

## Known upstream issues

### `wyoming-whisper`: `ModuleNotFoundError: No module named 'zeroconf'` at container start

Upstream commit `ebc826a6` added `--zeroconf` to the whisper run script and
`zeroconf` to `build.sh` but forgot `install.sh`, so the default-alias
(`FORCE_BUILD=off`) image is missing the package at runtime. Tracked at
[dusty-nv/jetson-containers#1524](https://github.com/dusty-nv/jetson-containers/issues/1524).

- **Workaround:** `make build-wyoming-whisper` layers `zeroconf` onto the
  final image via [`Dockerfile.wyoming-whisper-zeroconf`](../Dockerfile.wyoming-whisper-zeroconf).
  Nothing inside `vendor/jetson-containers/` is modified.
- **Removal:** once upstream merges the fix, delete
  `Dockerfile.wyoming-whisper-zeroconf`, drop the trailing `zeroconf`-layering
  block from the `build-wyoming` target in the Makefile, and delete this
  section.

`wyoming-piper` is **not** affected — its run script does not pass `--zeroconf`,
so the missing package is never imported at runtime.

## Caveats

- **Best-effort ORT reuse.** If a future Immich release pins an `onnxruntime`
  version that `faster-whisper` or `piper1-tts` (or their transitive deps)
  rejects, the build will fail at the engine install step. The fix is to
  build a separate ORT version explicitly:
  ```bash
  jetson-containers build onnxruntime:<ver>
  ```
  and pass that image via `--base` instead.
- **Skip list must be complete.** `--skip-packages` must cover every package
  already baked into the ORT image (cuda, cudastack, python, numpy,
  onnxruntime). Missing one causes a spurious rebuild of that layer. This can
  also bite after an upstream refresh if a package gets renamed or split —
  watch the build output for an unexpected `Building Container onnxruntime`
  (or `cuda` / `python`) line and update the skip patterns accordingly.
- **Same host only.** The ORT image encodes a specific CUDA / L4T / GPU arch.
  Don't copy it to a different Jetson model and expect it to work as a base.
