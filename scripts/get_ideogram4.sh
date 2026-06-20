#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# get_ideogram4.sh — fetch Ideogram 4.0 (open weights) for ComfyUI.
#
# Ideogram 4.0 is a 9.3B open-weight text-to-image model, natively supported in
# ComfyUI core (>=0.24.0; this image ships newer). It runs locally on the gfx1151
# iGPU. Source repo: https://huggingface.co/Comfy-Org/Ideogram-4
#
# Usage:
#   get_ideogram4.sh            # fp8 (default): cond + uncond model, TE, VAE
#   get_ideogram4.sh nvfp4      # smaller nvfp4 variant (cond + uncond, TE, VAE)
#   get_ideogram4.sh fp8 nouncond   # skip the unconditional model (no true CFG)
#
# Notes:
# - gfx1151 has no FP8/FP4 tensor hardware, so these ops are *emulated* (correct
#   but slower) — same trade-off as the other FP8 models here. nvfp4 is smaller
#   on disk/VRAM; fp8 is the most-tested path.
# - The unconditional model enables real classifier-free guidance (negative
#   prompt). The official ComfyUI t2i template uses it; skip with 'nouncond' to
#   save ~5-9 GB if you only need cfg=1.
set -euo pipefail

export HF_HUB_ENABLE_HF_TRANSFER=1
export HF_HOME="${HF_HOME:-$HOME/.cache/huggingface}"
HF="/opt/venv/bin/hf"

MODEL_HOME="$HOME/comfy-models"
STAGE="$MODEL_HOME/.hf_stage_ideogram4"
REPO="Comfy-Org/Ideogram-4"

mkdir -p "$MODEL_HOME"/{text_encoders,vae,diffusion_models} "$STAGE"

PRECISION="fp8"
[[ "${1:-}" == "nvfp4" ]] && PRECISION="nvfp4"
WANT_UNCOND=1
[[ "${1:-}" == "nouncond" || "${2:-}" == "nouncond" ]] && WANT_UNCOND=0

dl() {
  local remote="$1"; local subdir="$2"
  local dest="$MODEL_HOME/$subdir/$(basename "$remote")"
  local staged="$STAGE/$remote"
  if [[ -f "$dest" ]]; then echo "✓ Already present: $dest"; return; fi
  echo "↓ Downloading $(basename "$remote") → $dest"
  mkdir -p "$(dirname "$staged")"
  "$HF" download "$REPO" "$remote" --repo-type model --cache-dir "$HF_HOME" --local-dir "$STAGE"
  mv -f "$staged" "$dest"
}

echo "==> Ideogram 4.0 ($PRECISION)$([[ $WANT_UNCOND == 1 ]] && echo ' + unconditional')"

if [[ "$PRECISION" == "nvfp4" ]]; then
  dl "diffusion_models/ideogram4_nvfp4_mixed.safetensors" "diffusion_models"
  [[ $WANT_UNCOND == 1 ]] && dl "diffusion_models/ideogram4_unconditional_nvfp4_mixed.safetensors" "diffusion_models"
  dl "text_encoders/qwen3vl_8b_nvfp4.safetensors" "text_encoders"
else
  dl "diffusion_models/ideogram4_fp8_scaled.safetensors" "diffusion_models"
  [[ $WANT_UNCOND == 1 ]] && dl "diffusion_models/ideogram4_unconditional_fp8_scaled.safetensors" "diffusion_models"
  dl "text_encoders/qwen3vl_8b_fp8_scaled.safetensors" "text_encoders"
fi
dl "vae/flux2-vae.safetensors" "vae"

echo "✅ Ideogram 4.0 ready. Load 'Ideogram4-T2I' in ComfyUI (Templates) and run."
