#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# smoke-test.sh — fast, non-interactive health check to run INSIDE the
# comfyui-strixhalo distrobox after building. Automates the mechanical parts of
# docs/TESTING.md (Phases 4–6): venv, commands on PATH, ROCm device visibility,
# torch GPU access, and a short ComfyUI startup probe.
#
#   distrobox enter comfyui-strixhalo
#   /opt/smoke-test.sh
#
# Exit code 0 = all checks passed; non-zero = something needs attention.
# It does NOT download models or run a full generation (that's Phase 7, manual).

set -uo pipefail

pass=0; fail=0; warn=0
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; pass=$((pass+1)); }
no()   { printf '  \033[1;31m✗\033[0m %s\n' "$*"; fail=$((fail+1)); }
note() { printf '  \033[1;33m!\033[0m %s\n' "$*"; warn=$((warn+1)); }
hdr()  { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }

hdr "Environment"
if python --version 2>&1 | grep -q '3.13'; then ok "python is 3.13 ($(python --version 2>&1))"; else no "python is not 3.13 ($(python --version 2>&1))"; fi
[ "$(command -v python)" = "/opt/venv/bin/python" ] && ok "venv active (/opt/venv/bin/python)" || note "python is $(command -v python), expected /opt/venv/bin/python"
command -v start_comfy_ui >/dev/null && ok "start_comfy_ui on PATH" || no "start_comfy_ui NOT on PATH"
command -v model_manager  >/dev/null && ok "model_manager on PATH"  || no "model_manager NOT on PATH"
command -v dialog         >/dev/null && ok "dialog present (model_manager dep)" || no "dialog missing"

hdr "GPU devices (passthrough)"
[ -e /dev/kfd ] && ok "/dev/kfd present" || no "/dev/kfd missing — GPU passthrough failed (recreate distrobox)"
ls /dev/dri/renderD* >/dev/null 2>&1 && ok "/dev/dri render node(s) present" || no "/dev/dri/renderD* missing"

hdr "ROCm sees gfx1151"
if command -v rocminfo >/dev/null 2>&1; then
  if rocminfo 2>/dev/null | grep -qi 'gfx1151'; then ok "rocminfo lists gfx1151"; else no "rocminfo does not list gfx1151"; fi
else
  note "rocminfo not found in PATH (ROCm tools come with the torch wheel; check install)"
fi
if command -v rocm-smi >/dev/null 2>&1; then
  vram="$(rocm-smi --showmeminfo vram 2>/dev/null | grep -i 'total' | head -1)"
  [ -n "$vram" ] && ok "rocm-smi VRAM: ${vram//[[:space:]]\+/ }" || note "rocm-smi ran but no VRAM line parsed"
else
  note "rocm-smi not found"
fi

hdr "PyTorch GPU access (the make-or-break check)"
torch_out="$(python - <<'PY' 2>&1
try:
    import torch
    print("VERSION", torch.__version__)
    print("AVAIL", torch.cuda.is_available())
    if torch.cuda.is_available():
        print("DEVICE", torch.cuda.get_device_name(0))
        x = torch.randn(2048, 2048, device="cuda")
        y = (x @ x).sum().item()
        print("MATMUL_OK", isinstance(y, float))
except Exception as e:
    print("ERROR", repr(e))
PY
)"
echo "$torch_out" | grep -q "VERSION" && ok "torch imports ($(echo "$torch_out" | awk '/VERSION/{print $2}'))" || no "torch import failed: $torch_out"
if echo "$torch_out" | grep -q "AVAIL True"; then
  ok "torch.cuda.is_available() = True"
  echo "$torch_out" | grep -q "DEVICE" && ok "device: $(echo "$torch_out" | sed -n 's/^DEVICE //p')"
  echo "$torch_out" | grep -q "MATMUL_OK True" && ok "GPU matmul executed" || no "GPU matmul did not complete"
else
  no "torch.cuda.is_available() = False — ROCm/torch can't see the iGPU"
fi

hdr "ComfyUI startup probe (10s)"
# Start ComfyUI briefly and confirm it begins serving, then stop it.
( start_comfy_ui >/tmp/comfy_smoke.log 2>&1 & echo $! >/tmp/comfy_smoke.pid )
sleep 10
cpid="$(cat /tmp/comfy_smoke.pid 2>/dev/null)"
if grep -qiE 'starting server|to see the gui|uvicorn running|listening' /tmp/comfy_smoke.log 2>/dev/null; then
  ok "ComfyUI started serving (see /tmp/comfy_smoke.log)"
elif kill -0 "$cpid" 2>/dev/null; then
  note "ComfyUI process alive but no 'serving' line yet (slow first load?) — check /tmp/comfy_smoke.log"
else
  no "ComfyUI exited during startup — tail of log:"; tail -n 15 /tmp/comfy_smoke.log 2>/dev/null | sed 's/^/      /'
fi
[ -n "${cpid:-}" ] && kill "$cpid" 2>/dev/null
pkill -f "main.py --port" 2>/dev/null || true

hdr "Summary"
printf '  passed: %d   failed: %d   warnings: %d\n' "$pass" "$fail" "$warn"
if [ "$fail" -eq 0 ]; then
  printf '  \033[1;32mSmoke test passed.\033[0m Next: model_manager, then run a workflow (docs/TESTING.md Phase 7).\n'
  exit 0
else
  printf '  \033[1;31mSmoke test found %d failure(s).\033[0m See docs/TESTING.md for the matching phase.\n' "$fail"
  exit 1
fi
