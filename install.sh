#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# install.sh — one command to stand up ComfyUI on AMD Strix Halo (gfx1151).
#
# Just run:   ./install.sh
#
# It is STATE-AWARE and re-runnable: it figures out what's already done and does
# only the next step. Two steps need a reboot / re-login (kernel params, GPU
# groups) — when one is required, the script tells you and exits; just run
# ./install.sh again afterwards and it continues from where it left off.
#
# Everything else (ROCm, PyTorch, ComfyUI, custom nodes, the studios, workflows,
# tuned launch flags, model-path wiring) is baked into the container image — the
# only thing you download separately is the model weights (large), via
# `model_manager` inside the container.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

c_blue='\033[1;34m'; c_grn='\033[1;32m'; c_yel='\033[1;33m'; c_red='\033[1;31m'; c_off='\033[0m'
step() { printf "${c_blue}==>${c_off} %s\n" "$*"; }
ok()   { printf "${c_grn}✓${c_off} %s\n" "$*"; }
note() { printf "${c_yel}!${c_off} %s\n" "$*"; }
die()  { printf "${c_red}✗${c_off} %s\n" "$*" >&2; exit 1; }

IMAGE="localhost/comfyui-strixhalo:latest"
BOX="comfyui-strixhalo"

# --- 0. GPU present on the host? --------------------------------------------
step "Checking GPU devices"
[[ -e /dev/kfd && -n "$(ls /dev/dri/renderD* 2>/dev/null)" ]] \
    || die "/dev/kfd or /dev/dri/renderD* missing. Is this a Strix Halo with the amdgpu driver loaded? (lsmod | grep amdgpu)"
ok "/dev/kfd and /dev/dri present"

# --- 1. host prerequisites ---------------------------------------------------
# Check everything host-setup provides, not just that podman/distrobox exist.
# Gating on those two alone meant a host set up by an older revision of this
# script never picked up newly-required packages: podman was present, so setup
# was skipped, and the build then died ~40 layers in on a missing dependency.
# host-setup-ubuntu.sh is idempotent, so re-running it to fill a gap is cheap.
host_deps_ok() {
    command -v podman    >/dev/null || return 1
    command -v distrobox >/dev/null || return 1

    # podman >= 5 defaults to `pasta` (package: passt) and does NOT fall back to
    # slirp4netns when the binary is absent — every build/run fails at the first
    # networked step. Verify whichever backend podman is actually configured for.
    local net_cmd
    net_cmd="$(podman info --format '{{.Host.RootlessNetworkCmd}}' 2>/dev/null || true)"
    case "$net_cmd" in
        pasta)       command -v pasta       >/dev/null || return 1 ;;
        slirp4netns) command -v slirp4netns >/dev/null || return 1 ;;
    esac
    return 0
}

if ! host_deps_ok; then
    step "Installing host prerequisites (podman, distrobox, rootless networking)"
    ./host-setup-ubuntu.sh
    note "Host setup done. If it added you to the render/video groups, LOG OUT and"
    note "back in (or reboot) so they apply."
    note "Then run ./install.sh again to continue."
    exit 0
fi
ok "podman + distrobox + rootless networking present"

# --- 2. kernel unified-memory (GTT) params ----------------------------------
if ! grep -q 'amdgpu.gttsize=' /proc/cmdline; then
    step "Configuring kernel unified-memory params"
    ./setup-kernel-ubuntu.sh
    note "Kernel params written. REBOOT, then run ./install.sh again to continue."
    exit 0
fi
ok "kernel GTT params live ($(grep -o 'amdgpu.gttsize=[0-9]*' /proc/cmdline))"

# --- 3. build the image (all software baked in) -----------------------------
if ! podman image exists "$IMAGE"; then
    step "Building the container image (long first build, ~15 GB)"
    ./build-image.sh
fi
ok "image present: $IMAGE"

# --- 4. create the distrobox -------------------------------------------------
if ! distrobox list 2>/dev/null | grep -q "$BOX"; then
    step "Creating the distrobox"
    ./refresh-distrobox.sh
fi
ok "distrobox present: $BOX"

# --- Done --------------------------------------------------------------------
cat <<EOF

${c_grn}ComfyUI-StrixHalo is ready.${c_off}

  1. Enter the container:   distrobox enter $BOX
  2. Download model weights: model_manager        # the only large, separate download
  3. Launch ComfyUI:         start_comfy_ui        # serves http://localhost:8000

(start_comfy_ui auto-wires model paths and the tuned Strix-Halo flags — no other
setup needed. Models live in ~/comfy-models, outputs in ~/comfy-outputs, both in
your home dir so they survive container rebuilds.)
EOF
