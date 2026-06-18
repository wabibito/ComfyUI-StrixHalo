<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Hardware Testing Plan — AMD Strix Halo (gfx1151)

Everything in this repo is validated *off* the GPU (script lint, Ubuntu base +
deadsnakes Python 3.13 venv + vendored layers build in CI). The items below are
the parts that can **only** be verified on a real Ryzen AI Max "Strix Halo"
machine. Run them in order — each phase gates the next. Check the boxes as you go
and open an issue for any ✗, quoting the exact command + output.

**System under test**
- Machine: __________________  RAM: ______ GB  Ubuntu: ______  Kernel: ______
- Date: __________  Tester: __________

Legend: ⬜ not run · ✅ pass · ❌ fail (file issue) · ⏭️ skipped

> **Shortcut:** once you're inside the container (Phase 4+), `/opt/smoke-test.sh`
> automates the mechanical checks in Phases 4–6 (venv, commands on PATH, ROCm
> device visibility, torch GPU access, a 10s ComfyUI startup probe) and prints a
> pass/fail summary. It does **not** download models or run a full generation —
> that's Phase 7, by hand in the UI.

---

## Phase 0 — Prerequisites (host, before any repo script)

- ⬜ BIOS UMA / "GPU memory" allocation set appropriately for your RAM.
- ⬜ `amdgpu` kernel driver loaded: `lsmod | grep amdgpu` returns rows.
- ⬜ Kernel devices exist on the host: `ls -l /dev/kfd /dev/dri/renderD*`
- ⬜ `git clone https://github.com/wabibito/ComfyUI-StrixHalo && cd ComfyUI-StrixHalo`

**Pass criteria:** `/dev/kfd` and at least one `/dev/dri/renderD*` are present.

---

## Phase 1 — Host setup (`host-setup-ubuntu.sh`)

- ⬜ `./host-setup-ubuntu.sh` completes without error.
- ⬜ podman + distrobox installed: `podman --version && distrobox --version`
- ⬜ Rootless ranges present: `grep "^$USER:" /etc/subuid /etc/subgid`
- ⬜ User in groups: `id -nG | tr ' ' '\n' | grep -E 'render|video'` (both)
- ⬜ **Log out and back in (or reboot)** so the new groups apply, then re-check `id`.

**Pass criteria:** script exits 0; you are in `render` *and* `video` after re-login.
**Watch for:** if `render`/`video` groups don't exist, the amdgpu driver isn't
loaded (back to Phase 0).

---

## Phase 2 — Kernel / unified memory (`setup-kernel-ubuntu.sh`)

- ⬜ Preview first: `./setup-kernel-ubuntu.sh --dry-run` — sanity-check the
  computed `gttsize` / `ttm.pages_limit` for your RAM.
- ⬜ Apply: `./setup-kernel-ubuntu.sh` (or `--gtt-gib N` to force a size).
- ⬜ Confirm backup created: `ls /etc/default/grub.bak.*`
- ⬜ `sudo reboot`
- ⬜ After reboot, params are live: `cat /proc/cmdline | grep -o 'amdgpu.gttsize=[0-9]*\|ttm.pages_limit=[0-9]*'`

**Pass criteria:** system boots normally; `/proc/cmdline` shows the new params.
**Rollback if it won't boot:** pick the previous kernel in GRUB, then
`sudo cp /etc/default/grub.bak.* /etc/default/grub && sudo update-grub`.

---

## Phase 3 — Build the image (`build-image.sh`)

> This is the **highest-risk hardware-dependent step** — it pulls the ROCm
> nightly + PyTorch wheels for gfx1151, which CI cannot exercise.

- ⬜ `./build-image.sh` completes (expect a long first build, several GB).
- ⬜ Image exists: `podman image exists localhost/comfyui-strixhalo:latest && echo OK`
- ⬜ **If the torch step fails to resolve a wheel:** note the exact error — it's
  almost always a Python-minor / nightly-index mismatch (see README "Python pin").
  File an issue with the failing `pip install` line.

**Pass criteria:** `podman image exists ...` returns OK.

---

## Phase 4 — Create + enter the distrobox (`refresh-distrobox.sh`)

- ⬜ `./refresh-distrobox.sh` creates the container without error.
- ⬜ `distrobox enter comfyui-strixhalo` — the **banner** prints with the machine
  + GPU name + ROCm nightly version (confirms profile.d + GPU detection work).
- ⬜ Commands resolve on PATH: `command -v start_comfy_ui model_manager`
- ⬜ The venv is active: `python --version` → 3.13.x, `which python` → `/opt/venv/bin/python`

**Pass criteria:** banner shows a real GPU name (not "Unknown AMD GPU"); both
commands resolve.

---

## Phase 5 — GPU visible to ROCm *inside* the container

Run these inside `distrobox enter comfyui-strixhalo`:

- ⬜ `rocminfo | grep -i 'gfx1151'` — the gfx1151 agent is listed.
- ⬜ `rocm-smi` — shows the GPU and current VRAM/usage.
- ⬜ `rocm-smi --showmeminfo vram` — total VRAM ≈ your configured GTT window
  (e.g. ~124 GiB on a 128 GB machine), confirming Phase 2 took effect.
- ⬜ Torch sees the GPU:
  ```bash
  python -c "import torch; print(torch.__version__); print(torch.cuda.is_available()); print(torch.cuda.get_device_name(0))"
  ```

**Pass criteria:** `torch.cuda.is_available()` is `True` and the device name is
the Radeon 8060S / gfx1151. **This is the make-or-break check** — if it fails,
the GPU passthrough or ROCm stack is the problem, not ComfyUI.

---

## Phase 6 — Launch ComfyUI (`start_comfy_ui`)

- ⬜ `start_comfy_ui` starts and logs "Starting server" on port 8000 with no
  fatal ROCm errors.
- ⬜ From the host (or via `ssh -L 8000:localhost:8000 user@host`), open
  <http://localhost:8000> — the ComfyUI web UI loads.
- ⬜ Non-interactive form also works:
  `distrobox enter comfyui-strixhalo -- start_comfy_ui` (validates the
  command-not-alias fix).
- ⬜ Ctrl-C stops it cleanly.

**Pass criteria:** UI reachable; no crash on startup.

---

## Phase 7 — Models + a real generation (per workflow)

First wire up model paths, then download + run. Inside the container:

- ⬜ `/opt/set_extra_paths.sh` — writes `extra_model_paths.yaml`, creates
  `~/comfy-models/*` subdirs.
- ⬜ `model_manager` — the TUI opens (validates `dialog`), lists families,
  downloads complete and land under `~/comfy-models/`.

Then, for **each** model family you intend to use, load the matching workflow
from `user/default/workflows/` in the UI and run it end to end:

| Family | Workflow to load | ⬜ Downloads | ⬜ Generates |
|--------|------------------|:--:|:--:|
| Qwen Image (text→image) | `Qwen-Image-2512-*` | ⬜ | ⬜ |
| Qwen Image + Lightning LoRA | `Qwen-Image-2512-*-4-Step-LoRA` | ⬜ | ⬜ |
| Qwen Image Edit | `Qwen-Image-Edit-2511-*` | ⬜ | ⬜ |
| Wan 2.2 — Image→Video | `Wan2.2-I2V-*` | ⬜ | ⬜ |
| Wan 2.2 — Text→Video | `Wan2.2-T2V-*` | ⬜ | ⬜ |
| HunyuanVideo 1.5 — I2V | `Hunyuan-Video-1.5_720p_i2v-*` | ⬜ | ⬜ |
| HunyuanVideo 1.5 — T2V | `Hunyuan-Video-1.5_720p_t2v-*` | ⬜ | ⬜ |
| LTX-2 | `LTX2-*` | ⬜ | ⬜ |

**Pass criteria per row:** the workflow runs without OOM and produces an output
in `~/comfy-outputs/`. Record approximate generation time + peak VRAM
(`rocm-smi` in another shell).

**Watch for:** OOM during VAE decode or slowness above 64 GB → confirm you
launched via `start_comfy_ui` (the tuned flags), not a bare `python main.py`.

---

## Phase 8 — Persistence & rebuild (optional but recommended)

- ⬜ Models survive a container rebuild: re-run `./refresh-distrobox.sh`, re-enter,
  confirm `~/comfy-models` and `~/comfy-outputs` are intact.
- ⬜ Outputs written to the **host** home dir (distrobox shares `$HOME`).

---

## Phase 9 — Performance / diagnostics (optional)

- ⬜ Benchmarks: `python /opt/benchmark_workflows.py --warm-start` → writes
  `benchmark_results.json` (cold + warm timings per workflow).
- ⬜ Perf logs for kernel/AMD issue reports: `python /opt/collect_perf_logs.py`.

---

## Reporting

For any ❌, open an issue at
<https://github.com/wabibito/ComfyUI-StrixHalo/issues> with:
the phase number, the exact command, the full error output, and
`uname -r` + `rocminfo | head -30` for environment context.
