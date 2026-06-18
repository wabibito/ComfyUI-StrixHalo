#!/usr/bin/env bash
#
# build-image.sh
# Build the ComfyUI container image locally with rootless Podman on Ubuntu.
#
# The Dockerfile uses an Ubuntu 26.04 base. Python 3.13 is pulled from the
# deadsnakes PPA (not the system 3.14) because TheRock's gfx1151 ROCm/PyTorch
# wheels target the 3.13 ABI. The ROCm/PyTorch install line is otherwise
# unchanged from upstream.
#
# Produces:  localhost/comfyui-strixhalo:latest
#
# Usage:
#   ./build-image.sh                # build :latest
#   ./build-image.sh dev            # build :dev (same Dockerfile, different tag)
#   IMAGE_NAME=foo ./build-image.sh # override image name
#   ./build-image.sh --no-cache     # force a clean rebuild

set -euo pipefail

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="${IMAGE_NAME:-localhost/comfyui-strixhalo}"

TAG="latest"
EXTRA_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --no-cache) EXTRA_ARGS+=("--no-cache") ;;
        latest|dev) TAG="$arg" ;;
        *) EXTRA_ARGS+=("$arg") ;;   # pass through any other podman build flags
    esac
done

IMAGE="${IMAGE_NAME}:${TAG}"

if ! command -v podman &>/dev/null; then
    err "podman not found. Run ./host-setup-ubuntu.sh first."
    exit 1
fi

[[ -f "${SCRIPT_DIR}/Dockerfile" ]] || { err "Dockerfile not found in ${SCRIPT_DIR}"; exit 1; }

log "Building ${IMAGE} with rootless podman."
log "This downloads ROCm nightlies + PyTorch + ComfyUI — expect a long first build and several GB."

podman build \
    "${EXTRA_ARGS[@]}" \
    -t "${IMAGE}" \
    -f "${SCRIPT_DIR}/Dockerfile" \
    "${SCRIPT_DIR}"

echo
log "Built ${IMAGE}"
podman image inspect --format '   id:     {{.Id}}' "${IMAGE}" 2>/dev/null || true
podman image inspect --format '   size:   {{.Size}} bytes' "${IMAGE}" 2>/dev/null || true
echo
log "Next: create + enter the distrobox:  ./refresh-toolbox.sh ${TAG}"
