#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# build-image.sh
# Build the ComfyUI-StrixHalo container image with rootless Podman on Ubuntu,
# entirely from sources WE vendor (see vendor.sh / vendor/). No third-party
# images are pulled; the only network access is apt + the ROCm/PyPI wheels.
#
# The Dockerfile uses an Ubuntu 26.04 base. Python 3.13 is pulled from the
# deadsnakes PPA (not the system 3.14) because TheRock's gfx1151 ROCm/PyTorch
# wheels target the 3.13 ABI.
#
# Image name is REGISTRY/NAMESPACE/comfyui-strixhalo:TAG.
#   - Local-only (default):   localhost/comfyui-strixhalo:latest
#   - Your own registry:      REGISTRY=docker.io IMAGE_NAMESPACE=youruser ./build-image.sh --push
#                             REGISTRY=ghcr.io   IMAGE_NAMESPACE=youruser ./build-image.sh --push
#
# Usage:
#   ./build-image.sh                 # build :latest locally
#   ./build-image.sh dev             # build :dev
#   ./build-image.sh --no-cache      # force a clean rebuild
#   ./build-image.sh --push          # build, then push to REGISTRY/NAMESPACE
#   IMAGE_NAME=foo/bar ./build-image.sh   # fully override the image name

set -euo pipefail

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Image naming -----------------------------------------------------------
# REGISTRY + IMAGE_NAMESPACE compose the repo; IMAGE_NAME overrides everything.
REGISTRY="${REGISTRY:-localhost}"
IMAGE_NAMESPACE="${IMAGE_NAMESPACE:-}"
if [[ -n "${IMAGE_NAME:-}" ]]; then
    REPO="$IMAGE_NAME"
elif [[ -n "$IMAGE_NAMESPACE" ]]; then
    REPO="${REGISTRY}/${IMAGE_NAMESPACE}/comfyui-strixhalo"
else
    REPO="${REGISTRY}/comfyui-strixhalo"
fi

TAG="latest"
PUSH=0
EXTRA_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --no-cache) EXTRA_ARGS+=("--no-cache") ;;
        --push)     PUSH=1 ;;
        latest|dev) TAG="$arg" ;;
        -h|--help)  grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) EXTRA_ARGS+=("$arg") ;;   # pass through any other podman build flags
    esac
done

IMAGE="${REPO}:${TAG}"

if ! command -v podman &>/dev/null; then
    err "podman not found. Run ./host-setup-ubuntu.sh first."
    exit 1
fi

[[ -f "${SCRIPT_DIR}/Dockerfile" ]] || { err "Dockerfile not found in ${SCRIPT_DIR}"; exit 1; }

# --- Ensure vendored sources are present ------------------------------------
if [[ ! -d "${SCRIPT_DIR}/vendor/ComfyUI" ]]; then
    warn "vendor/ not found — vendoring sources now (one-time)."
    "${SCRIPT_DIR}/vendor.sh"
fi

log "Building ${IMAGE} with rootless podman (from vendored sources)."
log "Expect a long first build and several GB (ROCm nightlies + PyTorch)."

podman build \
    "${EXTRA_ARGS[@]}" \
    -t "${IMAGE}" \
    -f "${SCRIPT_DIR}/Dockerfile" \
    "${SCRIPT_DIR}"

echo
log "Built ${IMAGE}"
podman image inspect --format '   id:     {{.Id}}' "${IMAGE}" 2>/dev/null || true
podman image inspect --format '   size:   {{.Size}} bytes' "${IMAGE}" 2>/dev/null || true

if [[ $PUSH -eq 1 ]]; then
    if [[ "$REGISTRY" == "localhost" && -z "${IMAGE_NAME:-}" ]]; then
        err "--push needs a real registry. Set REGISTRY and IMAGE_NAMESPACE, e.g.:"
        err "   REGISTRY=ghcr.io IMAGE_NAMESPACE=youruser ./build-image.sh --push"
        exit 1
    fi
    echo
    log "Pushing ${IMAGE} (run 'podman login ${REGISTRY}' first if needed)."
    podman push "${IMAGE}"
    log "Pushed ${IMAGE}"
fi

echo
log "Next: create + enter the distrobox:  ./refresh-distrobox.sh ${TAG}"
