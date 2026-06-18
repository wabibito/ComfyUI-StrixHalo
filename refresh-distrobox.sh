#!/usr/bin/env bash
#
# refresh-distrobox.sh
#
# (Re)creates the ComfyUI-StrixHalo distrobox container from the image you built
# locally with ./build-image.sh. Recreating the container never deletes your
# ~/comfy-models or ~/comfy-outputs — those live in your home directory.
#
# Usage:
#   ./refresh-distrobox.sh             # use :latest
#   ./refresh-distrobox.sh dev         # use :dev

set -euo pipefail

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }

DISTROBOX_NAME="comfyui-strixhalo"

# Image repo. Mirrors build-image.sh: defaults to the local build, but honours
# REGISTRY / IMAGE_NAMESPACE (or a full IMAGE_NAME) if you built to your own
# registry.
REGISTRY="${REGISTRY:-localhost}"
IMAGE_NAMESPACE="${IMAGE_NAMESPACE:-}"
if [[ -n "${IMAGE_NAME:-}" ]]; then
    REPO="$IMAGE_NAME"
elif [[ -n "$IMAGE_NAMESPACE" ]]; then
    REPO="${REGISTRY}/${IMAGE_NAMESPACE}/comfyui-strixhalo"
else
    REPO="${REGISTRY}/comfyui-strixhalo"
fi

# --- Args: channel (latest|dev) ---
CHANNEL="latest"
for arg in "$@"; do
    case "$arg" in
        latest|dev) CHANNEL="$arg" ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) err "Unknown argument: $arg"; exit 1 ;;
    esac
done

IMAGE="${REPO}:${CHANNEL}"

# GPU passthrough flags (AMD ROCm devices + render/video groups).
OPTIONS="--device /dev/dri --device /dev/kfd --group-add video --group-add render --security-opt seccomp=unconfined"

# --- Require distrobox + podman ---
if ! command -v distrobox &>/dev/null; then
    err "distrobox not found. Run ./host-setup-ubuntu.sh first."
    exit 1
fi
if ! command -v podman &>/dev/null; then
    err "podman not found. Run ./host-setup-ubuntu.sh first."
    exit 1
fi

# --- Ensure the image is available ---
if podman image exists "$IMAGE"; then
    log "Using image: $IMAGE"
elif [[ "$REGISTRY" != "localhost" ]]; then
    # Image lives in a real registry but isn't pulled yet — fetch it.
    log "Pulling image from registry: $IMAGE"
    podman pull "$IMAGE"
else
    err "Local image '$IMAGE' not found."
    err "Build it first:  ./build-image.sh ${CHANNEL}"
    exit 1
fi

# --- Remove existing container if present ---
if distrobox list 2>/dev/null | grep -q "$DISTROBOX_NAME"; then
    warn "Removing existing distrobox: $DISTROBOX_NAME"
    distrobox rm -f "$DISTROBOX_NAME"
fi

# --- Create ---
log "Creating distrobox: $DISTROBOX_NAME"
log "   image:   $IMAGE"
log "   options: $OPTIONS"
distrobox create -n "$DISTROBOX_NAME" --image "$IMAGE" --additional-flags "$OPTIONS"

echo
log "✅ $DISTROBOX_NAME ready (channel: $CHANNEL)."
echo "Enter it with:        distrobox enter $DISTROBOX_NAME"
echo "Then inside, run:     start_comfy_ui      # http://localhost:8000"
echo "First-time setup:     /opt/set_extra_paths.sh && model_manager"
