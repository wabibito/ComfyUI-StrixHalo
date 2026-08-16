#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# host-setup-ubuntu.sh
# One-time Ubuntu 26.04 (Resolute) host bootstrap for the AMD Strix Halo ComfyUI
# distrobox. Installs rootless Podman + distrobox + image tooling, grants the
# current user GPU device access, and verifies the AMD GPU is visible.
#
# Idempotent: safe to re-run. Does NOT touch GRUB / kernel params — use
# setup-kernel-ubuntu.sh for that.

set -euo pipefail

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }
have() { command -v "$1" &>/dev/null; }

if [[ ${EUID} -eq 0 ]]; then
    err "Run this as your normal user (it will call sudo when needed), not as root."
    exit 1
fi

# ----------------------------------------------------------------------------
# 0. Sanity: are we on Ubuntu / Debian-like with apt?
# ----------------------------------------------------------------------------
if ! have apt-get; then
    err "This script targets Ubuntu (apt-based). apt-get not found."
    exit 1
fi

if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    log "Detected: ${PRETTY_NAME:-unknown}"
    case "${VERSION_ID:-}" in
        26.04|25.10|25.04|24.04) : ;;
        *) warn "Tested on Ubuntu 24.04–26.04. ${VERSION_ID:-?} may work but is untested." ;;
    esac
fi

# ----------------------------------------------------------------------------
# 1. Install packages
#    - podman          : rootless container runtime (distrobox backend)
#    - distrobox       : runs the locally-built image as an integrated container
#    - uidmap, fuse-overlayfs : rootless podman plumbing
#    - passt           : provides `pasta`, the DEFAULT rootless network backend
#                        for podman >= 5. Ubuntu only *recommends* it from the
#                        podman package, and we install with
#                        --no-install-recommends, so without listing it here
#                        every build dies at the first RUN with
#                        "could not find pasta, the network namespace can't be
#                        configured".
#    - slirp4netns     : legacy rootless network backend, kept as a fallback
#    - curl, ca-certificates : misc
# ----------------------------------------------------------------------------
PKGS=(podman distrobox uidmap passt slirp4netns fuse-overlayfs curl ca-certificates)

log "Installing host packages: ${PKGS[*]}"
sudo apt-get update -y
sudo apt-get install -y --no-install-recommends "${PKGS[@]}"

# ----------------------------------------------------------------------------
# 2. Rootless podman: ensure subuid/subgid ranges exist for this user.
#    Modern Ubuntu sets these automatically when the user is created, but a
#    user added before subordinate ranges existed (or a server image) may lack
#    them — podman is unusable rootless without them.
# ----------------------------------------------------------------------------
USER_NAME="${USER:-$(id -un)}"

ensure_subids() {
    local file="$1" cmd="$2"
    if ! grep -q "^${USER_NAME}:" "$file" 2>/dev/null; then
        log "Adding subordinate ID range to ${file} for ${USER_NAME}"
        sudo "$cmd" --add-subuids 100000-165535 --add-subgids 100000-165535 "${USER_NAME}" \
            || warn "Could not add sub-IDs automatically; check ${file}."
        return
    fi
}
# usermod handles both files in one call on Ubuntu.
if ! grep -q "^${USER_NAME}:" /etc/subuid 2>/dev/null || \
   ! grep -q "^${USER_NAME}:" /etc/subgid 2>/dev/null; then
    log "Configuring rootless sub-UID/GID ranges for ${USER_NAME}"
    sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "${USER_NAME}" \
        || warn "usermod sub-id setup failed; podman rootless may not work."
    have podman && podman system migrate || true
else
    log "Rootless sub-UID/GID ranges already present."
fi

# ----------------------------------------------------------------------------
# 3. GPU access: add user to render + video groups.
#    Inside the container distrobox passes --group-add render/video, but the
#    *host* user must also belong to these groups so /dev/kfd and /dev/dri/*
#    are accessible to the rootless container process.
# ----------------------------------------------------------------------------
NEED_RELOGIN=0
for grp in render video; do
    if getent group "$grp" >/dev/null 2>&1; then
        if id -nG "$USER_NAME" | tr ' ' '\n' | grep -qx "$grp"; then
            log "User already in group: $grp"
        else
            log "Adding ${USER_NAME} to group: $grp"
            sudo usermod -aG "$grp" "$USER_NAME"
            NEED_RELOGIN=1
        fi
    else
        warn "Group '$grp' does not exist on this host (amdgpu/kfd driver loaded?)."
    fi
done

# ----------------------------------------------------------------------------
# 4. Verify rootless podman networking works.
#    podman >= 5 defaults to `pasta` (from the passt package). If the binary is
#    missing, podman does not fall back — every `podman build`/`run` fails at
#    the first network-using step with "could not find pasta". Catch it here
#    instead of ~40 build layers in.
# ----------------------------------------------------------------------------
if have podman; then
    net_cmd="$(podman info --format '{{.Host.RootlessNetworkCmd}}' 2>/dev/null || true)"
    log "Rootless network backend: ${net_cmd:-unknown}"
    if [[ "$net_cmd" == "pasta" ]] && ! have pasta; then
        warn "podman is configured to use 'pasta' but the binary is missing."
        warn "Install it with:  sudo apt-get install -y passt"
        warn "Or force the legacy backend for your user with:"
        warn "  mkdir -p ~/.config/containers && \\"
        warn "    printf '[network]\\ndefault_rootless_network_cmd = \"slirp4netns\"\\n' \\"
        warn "    > ~/.config/containers/containers.conf"
    elif [[ "$net_cmd" == "slirp4netns" ]] && ! have slirp4netns; then
        warn "podman is configured to use 'slirp4netns' but the binary is missing."
        warn "Install it with:  sudo apt-get install -y slirp4netns"
    else
        log "Rootless network backend binary present."
    fi
fi

# ----------------------------------------------------------------------------
# 5. Verify the GPU is visible to the host kernel.
# ----------------------------------------------------------------------------
log "Checking for AMD GPU devices..."
if [[ -e /dev/kfd ]]; then
    log "/dev/kfd present (ROCm compute device)."
else
    warn "/dev/kfd missing — the amdgpu kernel driver may not be loaded, or this is not a ROCm-capable GPU."
fi
if ls /dev/dri/renderD* &>/dev/null; then
    log "/dev/dri render node(s) present: $(ls /dev/dri/renderD* | tr '\n' ' ')"
else
    warn "No /dev/dri/renderD* render nodes found."
fi

if have lspci; then
    gpu_line="$(lspci -nn 2>/dev/null | grep -Ei 'vga|display' | grep -i amd | head -n1 || true)"
    [[ -n "$gpu_line" ]] && log "GPU: ${gpu_line#*: }"
fi

# ----------------------------------------------------------------------------
# Done
# ----------------------------------------------------------------------------
echo
log "Host setup complete."
echo "Next steps:"
echo "  1. (If you have not already) configure unified memory:  ./setup-kernel-ubuntu.sh"
echo "  2. Build the container image:                           ./build-image.sh"
echo "  3. Create + enter the distrobox:                        ./refresh-distrobox.sh"
echo
if [[ $NEED_RELOGIN -eq 1 ]]; then
    warn "You were added to new groups (render/video)."
    warn "Log out and back in (or reboot) before running the container, or run:"
    warn "    newgrp render   # then newgrp video   (per-shell workaround)"
fi
