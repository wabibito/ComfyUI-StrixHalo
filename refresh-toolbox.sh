#!/usr/bin/env bash
#
# refresh-toolbox.sh  (Ubuntu / distrobox / locally-built image edition)
#
# (Re)creates the ComfyUI distrobox container from a locally-built image. Unlike
# the upstream Fedora script, this does NOT pull from Docker Hub — it uses the
# image you built with ./build-image.sh. Recreating the container never deletes
# your ~/comfy-models or ~/comfy-outputs, which live in your home directory.
#
# Usage:
#   ./refresh-toolbox.sh             # use :latest
#   ./refresh-toolbox.sh dev         # use :dev
#   ./refresh-toolbox.sh --pull      # pull docker.io/kyuz0/... instead of local build

set -euo pipefail

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }

TOOLBOX_NAME="comfyui-strixhalo"
LOCAL_REPO="localhost/comfyui-strixhalo"
REMOTE_REPO="docker.io/kyuz0/amd-strix-halo-comfyui"   # upstream maintainer's image (unchanged)

# --- Args: channel (latest|dev) and optional --pull ---
CHANNEL="latest"
USE_REMOTE=0
for arg in "$@"; do
    case "$arg" in
        latest|dev) CHANNEL="$arg" ;;
        --pull)     USE_REMOTE=1 ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) err "Unknown argument: $arg"; exit 1 ;;
    esac
done

if [[ $USE_REMOTE -eq 1 ]]; then
    IMAGE="${REMOTE_REPO}:${CHANNEL}"
else
    IMAGE="${LOCAL_REPO}:${CHANNEL}"
fi

# Same GPU passthrough flags as upstream.
OPTIONS="--device /dev/dri --device /dev/kfd --group-add video --group-add render --security-opt seccomp=unconfined"

# --- Require distrobox + podman (the Ubuntu path) ---
if ! command -v distrobox &>/dev/null; then
    err "distrobox not found. Run ./host-setup-ubuntu.sh first."
    exit 1
fi
if ! command -v podman &>/dev/null; then
    err "podman not found. Run ./host-setup-ubuntu.sh first."
    exit 1
fi
RUNTIME="podman"

# --- Ensure the image exists ---
if [[ $USE_REMOTE -eq 1 ]]; then
    log "Pulling remote image: $IMAGE"
    $RUNTIME pull "$IMAGE"
else
    if ! $RUNTIME image exists "$IMAGE"; then
        err "Local image '$IMAGE' not found."
        err "Build it first:  ./build-image.sh ${CHANNEL}"
        err "(or pass --pull to fetch kyuz0's prebuilt image instead)"
        exit 1
    fi
    log "Using local image: $IMAGE"
fi

# --- Remove existing container if present ---
if distrobox list 2>/dev/null | grep -q "$TOOLBOX_NAME"; then
    warn "Removing existing distrobox: $TOOLBOX_NAME"
    distrobox rm -f "$TOOLBOX_NAME"
fi

# --- Create ---
log "Creating distrobox: $TOOLBOX_NAME"
log "   image:   $IMAGE"
log "   options: $OPTIONS"
distrobox create -n "$TOOLBOX_NAME" --image "$IMAGE" --additional-flags "$OPTIONS"

echo
log "✅ $TOOLBOX_NAME ready (channel: $CHANNEL)."
echo "Enter it with:        distrobox enter $TOOLBOX_NAME"
echo "Then inside, run:     start_comfy_ui      # http://localhost:8000"
echo "First-time setup:     /opt/set_extra_paths.sh && model_manager"
