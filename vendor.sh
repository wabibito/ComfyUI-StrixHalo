#!/usr/bin/env bash
#
# vendor.sh
# Clone every build-time source dependency into ./vendor/ so the image builds
# from copies WE own — no reaching out to third-party GitHub accounts at
# `podman build` time. Run this once (and again when you want to update a dep);
# commit the result so the build is self-contained and reproducible.
#
# Each vendored dir has its .git/ stripped (we snapshot the source, we don't
# track upstream history). The Dockerfile COPYs from vendor/ instead of cloning.
#
# Usage:
#   ./vendor.sh                 # vendor/refresh everything in the manifest
#   ./vendor.sh --keep-git      # keep .git/ dirs (if you want to pull updates later)
#   ./vendor.sh comfyui essentials   # only (re)vendor matching entries

set -euo pipefail

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENDOR_DIR="${SCRIPT_DIR}/vendor"

# ---------------------------------------------------------------------------
# Manifest: "key|dest-dir|git-url|ref"
#   key      : short name for selective vendoring on the command line
#   dest-dir : directory created under vendor/
#   git-url  : source to clone
#   ref      : branch/tag/commit to check out ("" = default branch HEAD)
#
# These are the upstream sources the image is assembled from. Repoint any url
# to your own fork to fully own a component.
# ---------------------------------------------------------------------------
MANIFEST=(
  "comfyui|ComfyUI|https://github.com/comfyanonymous/ComfyUI.git|"
  "essentials|custom_nodes/ComfyUI_essentials|https://github.com/cubiq/ComfyUI_essentials.git|"
  "amdgpumonitor|custom_nodes/ComfyUI-AMDGPUMonitor|https://github.com/kyuz0/ComfyUI-AMDGPUMonitor.git|"
  "gguf|custom_nodes/ComfyUI-GGUF|https://github.com/city96/ComfyUI-GGUF.git|"
  "qwen-studio|qwen-image-studio|https://github.com/kyuz0/qwen-image-studio.git|"
  "wan-studio|wan-video-studio|https://github.com/kyuz0/wan-video-studio.git|"
)

KEEP_GIT=0
SELECTORS=()
for arg in "$@"; do
  case "$arg" in
    --keep-git) KEEP_GIT=1 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) SELECTORS+=("$arg") ;;
  esac
done

command -v git >/dev/null || { err "git is required."; exit 1; }
mkdir -p "$VENDOR_DIR"

selected() {
  [[ ${#SELECTORS[@]} -eq 0 ]] && return 0
  local key="$1"
  for s in "${SELECTORS[@]}"; do [[ "$key" == *"$s"* ]] && return 0; done
  return 1
}

vendor_one() {
  local key="$1" dest="$2" url="$3" ref="$4"
  local path="${VENDOR_DIR}/${dest}"

  log "Vendoring ${key} -> vendor/${dest}"
  rm -rf "$path"
  mkdir -p "$(dirname "$path")"

  if [[ -n "$ref" ]]; then
    git clone -q "$url" "$path"
    git -C "$path" checkout -q "$ref"
  else
    git clone --depth=1 -q "$url" "$path"
  fi

  # Record provenance before we (optionally) strip .git
  local sha
  sha="$(git -C "$path" rev-parse HEAD 2>/dev/null || echo unknown)"
  printf '%s\n' "$url @ ${ref:-HEAD} ($sha)" > "${path}/.vendor-source"

  if [[ $KEEP_GIT -eq 0 ]]; then
    rm -rf "${path}/.git"
  fi

  # Strip nested .gitignore files. vendor/ is OUR snapshot — upstream's ignore
  # rules (e.g. ComfyUI ignoring /custom_nodes, /web/extensions, /input) would
  # otherwise stop git from committing files the image build needs to COPY in.
  find "$path" -name .gitignore -type f -delete

  echo "    pinned: ${sha}"
}

count=0
for entry in "${MANIFEST[@]}"; do
  IFS='|' read -r key dest url ref <<< "$entry"
  selected "$key" || continue
  vendor_one "$key" "$dest" "$url" "$ref"
  count=$((count + 1))
done

echo
if [[ $count -eq 0 ]]; then
  warn "No manifest entries matched: ${SELECTORS[*]:-<all>}"
else
  log "Vendored ${count} component(s) into vendor/"
  log "Commit vendor/ so the build is self-contained:  git add vendor && git commit"
fi
