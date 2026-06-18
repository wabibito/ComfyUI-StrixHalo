# ComfyUI-StrixHalo — Ubuntu 26.04 (distrobox edition)

An Ubuntu port of [kyuz0/amd-strix-halo-comfyui-toolboxes](https://github.com/kyuz0/amd-strix-halo-comfyui-toolboxes)
with the **exact same container, ComfyUI stack, workflows, and launch flags** —
but set up to run on **Ubuntu 26.04 (Resolute Raccoon)** using **distrobox +
rootless Podman** instead of Fedora's `toolbox`.

> Ubuntu doesn't ship `toolbox`. It ships `distrobox`, which manages OCI
> containers on the host. Here the image itself is rebuilt on an **Ubuntu 26.04
> base** (the upstream image was Fedora). The ROCm/PyTorch/ComfyUI stack and all
> the launch flags are unchanged — only the base OS layer and the host-side
> plumbing (packages, GPU groups, kernel params) differ.
>
> One subtlety: Ubuntu 26.04's default Python is 3.14, but TheRock's gfx1151
> torch wheels target the 3.13 ABI — so the Dockerfile installs Python 3.13 from
> the deadsnakes PPA and builds the venv from it. (See the Dockerfile header.)

Targets the **AMD Ryzen AI Max "Strix Halo"** iGPU (gfx1151, Radeon 8060S),
e.g. the Framework Desktop / Ryzen AI MAX+ 395 with 96–128 GB unified memory.

---

## What's the same as upstream

- The **`Dockerfile`** installs the same stack as upstream (ROCm nightlies via
  TheRock for gfx1151, PyTorch, ComfyUI + plugins, Qwen Image Studio, Wan Video
  Studio) — the **base is rebased to Ubuntu 26.04** with Python 3.13 from
  deadsnakes to match the torch wheel ABI. The ROCm/PyTorch pip install line is
  identical to upstream.
- The **`scripts/`** and **`workflows/`** are unchanged: same `model_manager`,
  `set_extra_paths.sh`, `get_*.sh` model fetchers, ROCm env vars, and the
  `start_comfy_ui` alias with the critical Strix Halo flags
  (`--disable-mmap --cache-none --bf16-vae --gpu-only --disable-smart-memory`).
- Same GPU passthrough flags (container is named `comfyui-strixhalo`)
  (`--device /dev/dri --device /dev/kfd --group-add video --group-add render
  --security-opt seccomp=unconfined`).

## What's Ubuntu-specific (the new bits)

| File | Purpose |
|------|---------|
| `host-setup-ubuntu.sh` | Installs podman + distrobox + skopeo/jq, sets up rootless sub-UID/GID, adds you to `render`/`video`, verifies `/dev/kfd` + `/dev/dri`. |
| `setup-kernel-ubuntu.sh` | Guided editor for `GRUB_CMDLINE_LINUX_DEFAULT` (Ubuntu's GRUB) with `amd_iommu`/`gttsize`/`ttm.pages_limit` auto-sized to your RAM. Backup + dry-run. |
| `build-image.sh` | Builds the image locally with rootless podman → `localhost/comfyui-strixhalo:latest`. |
| `refresh-toolbox.sh` | distrobox-only, uses your **local** image (no Docker Hub pull). `--pull` opt-in to use kyuz0's prebuilt image instead. |

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
./refresh-toolbox.sh               # creates the container from your local image
distrobox enter comfyui-strixhalo

# 5. Inside the container — first-time model setup, then launch
/opt/set_extra_paths.sh            # writes extra_model_paths.yaml -> ~/comfy-models
model_manager                      # TUI to download model weights
start_comfy_ui                     # serves http://localhost:8000
```

Open <http://localhost:8000>. Outputs land in `~/comfy-outputs`, models in
`~/comfy-models` — both in your **host** home directory (distrobox shares
`$HOME`), so they survive container rebuilds.

---

## Kernel / unified-memory parameters

Strix Halo needs the iGPU's GTT window opened up so ROCm can use most of system
RAM as VRAM. `setup-kernel-ubuntu.sh` edits **`GRUB_CMDLINE_LINUX_DEFAULT`** in
`/etc/default/grub` (Ubuntu uses `_DEFAULT`; upstream Fedora used
`GRUB_CMDLINE_LINUX`) and runs `update-grub`.

For a 128 GB machine it sets (reserving 4 GiB for the OS, identical to upstream):

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

## Building vs. pulling

This builds our **own** Ubuntu-based image locally with rootless podman
(`build-image.sh` → `localhost/comfyui-strixhalo:latest`). The base is
`ubuntu:26.04`; Python 3.13 comes from the deadsnakes PPA so it matches TheRock's
gfx1151 torch wheel ABI.

If you ever want to skip the build and use the maintainer's published
(Fedora-based) image instead:

```bash
./refresh-toolbox.sh --pull        # pulls docker.io/kyuz0/amd-strix-halo-comfyui:latest
```

> **Python pin matters.** Do not change the Dockerfile to use Ubuntu's default
> `python3` (3.14 on 26.04). The gfx1151 nightly index ships **cp313** torch
> wheels (verified: torch 2.10.0), and ComfyUI itself recommends 3.13 ("very well
> supported") over 3.14. Keep the deadsnakes 3.13 venv. If a future ROCm nightly
> ships cp314 wheels, bump the PPA package and the `python3.13` references
> together.
>
> The Ubuntu base layer (ubuntu:26.04 → deadsnakes → python3.13 venv) has been
> build-tested; it produces Python 3.13.x inside `/opt/venv`. The ROCm/PyTorch
> and ComfyUI layers are unchanged from upstream and require the real gfx1151
> hardware to exercise.

---

## Updating / rebuilding

```bash
./build-image.sh                   # rebuild the image (re-pulls ROCm/ComfyUI)
./refresh-toolbox.sh               # recreate the container from the new image
```

Recreating the container **never** deletes `~/comfy-models` or `~/comfy-outputs`.

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
  `start_comfy_ui` flags address; make sure you launched via the alias, not a
  bare `python main.py`.

---

## Credits

All credit for the container, ComfyUI tuning, ROCm work, and workflows goes to
**[kyuz0](https://github.com/kyuz0)** and the upstream
[amd-strix-halo-comfyui-toolboxes](https://github.com/kyuz0/amd-strix-halo-comfyui-toolboxes)
project. This repo only adds the Ubuntu 26.04 / distrobox host glue.
