# ComfyUI-StrixHalo

Run **ComfyUI** for image & video generation on the **AMD Ryzen AI Max "Strix
Halo"** iGPU (gfx1151, Radeon 8060S) under **Ubuntu 26.04**, in a self-contained
**distrobox** container built on top of **rootless Podman**.

Targets machines like the Framework Desktop / Ryzen AI MAX+ 395 with 96–128 GB
unified memory. Everything — ROCm, PyTorch, ComfyUI, the plugins, and the tuned
launch flags — is baked into a single locally-built image; your models and
outputs live in your home directory and persist across rebuilds.

> **Why distrobox?** Ubuntu doesn't ship Fedora's `toolbox`. `distrobox` is the
> Ubuntu-native equivalent — it runs an OCI image as a tightly host-integrated
> container (shared `$HOME`, GPU passthrough), which is exactly what we need to
> expose `/dev/kfd` and `/dev/dri` to ROCm.

---

## What's in the box

- **`Dockerfile`** — `ubuntu:26.04` base, ROCm nightlies (TheRock, gfx1151) +
  PyTorch, ComfyUI with `ComfyUI_essentials`, `ComfyUI-AMDGPUMonitor`,
  `ComfyUI-GGUF`, plus Qwen Image Studio and Wan Video Studio.
- **`scripts/`** — `model_manager` and `start_comfy_ui` (both installed as real
  commands on PATH, so they work in interactive *and* non-interactive shells),
  `set_extra_paths.sh`, per-model fetchers (`get_qwen_image.sh`, `get_wan22.sh`,
  `get_hunyuan15.sh`, `get_ltx2.sh`), ROCm env vars, and a login banner.
  `start_comfy_ui` carries the Strix-Halo-critical flags
  (`--disable-mmap --cache-none --bf16-vae --gpu-only --disable-smart-memory`).
- **`workflows/`** — ready-to-load ComfyUI workflows for Qwen Image / Edit,
  Wan 2.2, HunyuanVideo 1.5, and LTX2.
- **`vendor/`** — our own snapshot of every build-time source dependency
  (ComfyUI + the three custom nodes + both studios), so the image is built
  entirely from sources we control rather than cloned from third-party accounts
  at build time. Refreshed by `vendor.sh`; each dir records its origin + commit
  in a `.vendor-source` file.

### Host & build scripts

| File | Purpose |
|------|---------|
| `host-setup-ubuntu.sh` | Installs podman + distrobox, sets up rootless sub-UID/GID, adds you to `render`/`video`, verifies `/dev/kfd` + `/dev/dri`. |
| `setup-kernel-ubuntu.sh` | Guided editor for `GRUB_CMDLINE_LINUX_DEFAULT` with `amd_iommu`/`gttsize`/`ttm.pages_limit` auto-sized to your RAM. Backup + dry-run. |
| `vendor.sh` | Clones every build-time dependency into `vendor/` (strips `.git`/nested `.gitignore`, pins commit SHAs). Run to refresh deps; commit the result. |
| `build-image.sh` | Builds the image from `vendor/` with rootless podman → `localhost/comfyui-strixhalo:latest`. `--push` + `REGISTRY`/`IMAGE_NAMESPACE` to publish under your own registry. |
| `refresh-distrobox.sh` | Creates/recreates the `comfyui-strixhalo` distrobox from your built image. |

> **Self-contained build.** Once `vendor/` is committed, `podman build` pulls no
> code from anyone else's GitHub — only OS packages (apt) and Python wheels
> (ROCm index + PyPI). To re-own a component, repoint its URL in `vendor.sh`
> (e.g. to your fork) and re-run it.

---

## Quick start

```bash
# 1. One-time host bootstrap (podman, distrobox, GPU groups, rootless setup)
./host-setup-ubuntu.sh
#    Then LOG OUT and back in (or reboot) so the render/video groups apply.

# 2. One-time unified-memory kernel params (then reboot)
./setup-kernel-ubuntu.sh           # auto-sizes from your RAM; --dry-run to preview
sudo reboot

# 3. Build the container image locally (long first build, several GB)
./build-image.sh                   # -> localhost/comfyui-strixhalo:latest

# 4. Create the distrobox and enter it
./refresh-distrobox.sh             # creates the container from your local image
distrobox enter comfyui-strixhalo

# 5. Inside the container — first-time model setup, then launch
/opt/set_extra_paths.sh            # writes extra_model_paths.yaml -> ~/comfy-models
model_manager                      # TUI to download model weights
start_comfy_ui                     # serves http://localhost:8000
```

Open <http://localhost:8000>. Outputs land in `~/comfy-outputs`, models in
`~/comfy-models` — both in your **host** home directory (distrobox shares
`$HOME`), so they survive container rebuilds.

> **Verifying on real hardware?** Follow [docs/TESTING.md](docs/TESTING.md) — a
> phased checklist from host setup through GPU visibility to per-workflow
> generation. Inside the container, `/opt/smoke-test.sh` runs the mechanical
> checks (venv, ROCm/torch GPU access, ComfyUI startup) and prints pass/fail.

---

## The Python pin (important)

Ubuntu 26.04's default Python is **3.14**, but TheRock's gfx1151 torch wheels
target the **3.13** ABI — and ComfyUI itself recommends 3.13 ("very well
supported") over 3.14. So the Dockerfile installs Python **3.13 from the
deadsnakes PPA** and builds the venv from it.

> Do **not** switch the Dockerfile to the system `python3`: there's no cp314
> torch wheel for gfx1151 and the `pip install ... torch` step will fail to
> resolve. The gfx1151 nightly index ships cp313 wheels (verified: torch 2.10.0).
> If a future ROCm nightly ships cp314 wheels, bump the deadsnakes package and
> the `python3.13` references together.

The base image layer (`ubuntu:26.04` → deadsnakes → python3.13 venv) is
build-tested and yields Python 3.13.x in `/opt/venv`. The ROCm/PyTorch and
ComfyUI layers require the real gfx1151 hardware to exercise.

---

## Kernel / unified-memory parameters

Strix Halo needs the iGPU's GTT window opened up so ROCm can use most of system
RAM as VRAM. `setup-kernel-ubuntu.sh` edits **`GRUB_CMDLINE_LINUX_DEFAULT`** in
`/etc/default/grub` and runs `update-grub`.

For a 128 GB machine it sets (reserving 4 GiB for the OS):

```
amd_iommu=off amdgpu.gttsize=126976 ttm.pages_limit=32505856
```

- `gttsize` is in **MiB**; `ttm.pages_limit` is in **4 KiB pages** (`= gttsize_MiB × 256`).
- Override the size: `./setup-kernel-ubuntu.sh --gtt-gib 124`
- Preview without writing: `./setup-kernel-ubuntu.sh --dry-run`
- A timestamped backup of `/etc/default/grub` is made before any edit.

> Also set your **BIOS** UMA / "GPU memory" allocation appropriately, and note
> that on newer kernels (≥ 6.16.9) some of these params may no longer be needed.
> If the machine won't boot, pick the prior kernel in GRUB or restore the backup.

---

## Updating / rebuilding

```bash
./vendor.sh                        # refresh vendored deps to latest (optional)
./build-image.sh                   # rebuild the image
./refresh-distrobox.sh             # recreate the container from the new image
```

`./vendor.sh comfyui` re-vendors just ComfyUI; `./vendor.sh` with no args
refreshes everything. Recreating the container **never** deletes
`~/comfy-models` or `~/comfy-outputs`.

## Publishing under your own registry

The build is local-only by default (`localhost/comfyui-strixhalo`). To push the
image you built to your own registry:

```bash
# Docker Hub
REGISTRY=docker.io IMAGE_NAMESPACE=youruser ./build-image.sh --push
# or GitHub Container Registry
REGISTRY=ghcr.io   IMAGE_NAMESPACE=youruser ./build-image.sh --push
```

`podman login <registry>` first if you aren't already authenticated. The same
`REGISTRY`/`IMAGE_NAMESPACE` env vars make `refresh-distrobox.sh` pick up the
image from that repo, so a second machine can pull instead of rebuild.

---

## Troubleshooting

- **`Permission denied: /dev/kfd`** — you're not in the `render`/`video` groups
  yet, or haven't re-logged in since `host-setup-ubuntu.sh`. Run `id` to check;
  log out/in or reboot.
- **`rootless` / sub-id errors from podman** — re-run `./host-setup-ubuntu.sh`
  (it configures `/etc/subuid` + `/etc/subgid`), then `podman system migrate`.
- **GPU not seen inside the container** — confirm on the host: `ls /dev/kfd
  /dev/dri/renderD*`. Inside the box: `rocminfo | grep -i gfx` (expect
  `gfx1151`) and `rocm-smi`.
- **OOM during VAE decode / slow above 64 GB** — these are exactly what the
  `start_comfy_ui` flags address; make sure you launched via `start_comfy_ui`,
  not a bare `python main.py`.

---

## License & attribution

Distributed under **GPL-3.0** (see [LICENSE](LICENSE)) because the build bundles
the full ComfyUI source, which is GPL-3.0. Vendored third-party components keep
their own licenses (MIT / Apache-2.0 / GPL-3.0) — see [NOTICE.md](NOTICE.md) for
the full attribution table, and each `vendor/<component>/` directory for its
original license and pinned commit.

Built on AMD ROCm / the TheRock gfx1151 PyTorch wheels, ComfyUI, and the wider
Strix Halo community's unified-memory tuning work.
