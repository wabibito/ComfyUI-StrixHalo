FROM ubuntu:26.04

# Non-interactive apt + UTF-8 locale (some ComfyUI nodes/CLIs assume UTF-8)
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# Base packages (keep compilers/headers for Triton JIT at runtime).
#
# NOTE on Python: TheRock's gfx1151 ROCm/PyTorch wheels target the CPython 3.13
# ABI (verified against the gfx1151 nightly index: torch 2.10.0 cp313 wheels are
# published). Ubuntu 26.04's *default* python3 is 3.14, which has no matching
# torch wheel — and ComfyUI itself recommends 3.13 ("very well supported"). So we
# install 3.13 from the deadsnakes PPA and build the venv from it. Do NOT switch
# this to the system python3 or the torch install below will fail to resolve.
RUN apt-get update && apt-get install -y --no-install-recommends \
        software-properties-common ca-certificates gnupg curl \
    && add-apt-repository -y ppa:deadsnakes/ppa \
    && apt-get update && apt-get install -y --no-install-recommends \
        python3.13 python3.13-venv python3.13-dev \
        libdrm-dev git git-lfs rsync libatomic1 bash \
        build-essential binutils make ffmpeg vim dialog \
        libgl1 libglib2.0-0 libegl1 libgles2 libglx-mesa0 \
    && git lfs install --system \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Python venv (built from deadsnakes python3.13 to match the torch wheel ABI).
# --copies avoids dangling symlinks if the host python3.13 path ever shifts.
RUN /usr/bin/python3.13 -m venv --copies /opt/venv
ENV VIRTUAL_ENV=/opt/venv
ENV PATH=/opt/venv/bin:$PATH
ENV PIP_NO_CACHE_DIR=1
RUN printf 'source /opt/venv/bin/activate\n' > /etc/profile.d/venv.sh
RUN python -m pip install --upgrade pip setuptools wheel

# NOTE: helper scripts + user-facing commands are COPY'd LAST (just before the
# permissions step), so editing a script does not invalidate the expensive
# ROCm/PyTorch/ComfyUI/studio layers — script tweaks then rebuild in seconds.

# ROCm + PyTorch (TheRock, include torchaudio for resolver; remove later).
# Use the v2 (stable nightly) index, NOT v2-staging: on this hardware the
# v2-staging ROCm 7.14 build segfaults in ROCr agent enumeration
# (torch.cuda.is_available() / rocminfo crash), while the v2 ROCm 7.13 builds
# run correctly on the gfx1151 iGPU (verified: torch 2.11.0+rocm7.13 runs Evo 2
# on this exact machine). If a future v2 build regresses, pin a known-good
# rocm7.13 wheel here.
RUN python -m pip install \
    --index-url https://rocm.nightlies.amd.com/v2/gfx1151 \
    --pre torch torchaudio torchvision

WORKDIR /opt

# Pin specific transformers version
RUN python -m pip install gguf transformers==4.56.2

# ComfyUI — copied from our vendored source (see vendor.sh / vendor/), not cloned
# at build time, so the image is built entirely from sources we own.
COPY vendor/ComfyUI /opt/ComfyUI
WORKDIR /opt/ComfyUI
RUN python -m pip install -r requirements.txt && \
    python -m pip install --prefer-binary \
    pillow opencv-python-headless imageio imageio-ffmpeg scipy "huggingface_hub[hf_transfer]" pyyaml websocket-client

COPY workflows/input/ai-server.jpg /opt/ComfyUI/input/
COPY workflows/input/ai-server-2.png /opt/ComfyUI/input/
COPY workflows/input/example2.jpg /opt/ComfyUI/input/

COPY workflows/*.json /opt/ComfyUI/user/default/workflows/

# ComfyUI plugins (vendored)
COPY vendor/custom_nodes/ComfyUI_essentials      /opt/ComfyUI/custom_nodes/ComfyUI_essentials
COPY vendor/custom_nodes/ComfyUI-AMDGPUMonitor   /opt/ComfyUI/custom_nodes/ComfyUI-AMDGPUMonitor
COPY vendor/custom_nodes/ComfyUI-GGUF            /opt/ComfyUI/custom_nodes/ComfyUI-GGUF
RUN python -m pip install -r /opt/ComfyUI/custom_nodes/ComfyUI-GGUF/requirements.txt || true
# Ideogram 4 Prompt Builder KJ (V1) — vendored subset of kijai/ComfyUI-KJNodes,
# the visual JSON-caption builder. Self-contained (no extra pip deps).
COPY vendor/custom_nodes/ComfyUI-Ideogram4Builder-KJ /opt/ComfyUI/custom_nodes/ComfyUI-Ideogram4Builder-KJ

# Qwen Image Studio (vendored)
WORKDIR /opt
COPY vendor/qwen-image-studio /opt/qwen-image-studio
RUN python -m pip install -r /opt/qwen-image-studio/requirements.txt

# Wan Video Studio (vendored)
COPY vendor/wan-video-studio /opt/wan-video-studio
# shellcheck disable=SC2102  # imageio[ffmpeg] is a pip extras spec, not a glob range
RUN python -m pip install --prefer-binary \
    opencv-python-headless diffusers tokenizers accelerate \
    "imageio[ffmpeg]" easydict ftfy dashscope imageio-ffmpeg decord librosa

# Helper scripts + user-facing commands (COPY'd late so script edits don't bust
# the heavy layers above). model_manager is a thin wrapper around model_manager.py;
# start_comfy_ui is a real executable on PATH (works in non-interactive shells:
# `distrobox enter comfyui-strixhalo -- start_comfy_ui`).
COPY scripts/get_wan22.sh /opt/
COPY scripts/set_extra_paths.sh /opt/
COPY scripts/get_qwen_image.sh /opt/
COPY scripts/get_ideogram4.sh /opt/
COPY scripts/get_hunyuan15.sh /opt/
COPY scripts/get_ltx2.sh /opt/
COPY scripts/benchmark_workflows.py /opt/
COPY scripts/collect_perf_logs.py /opt/
COPY scripts/model_manager.py /opt/
COPY scripts/smoke-test.sh /opt/
COPY workflows/API /opt/comfy-workflows
COPY scripts/start_comfy_ui /opt/venv/bin/start_comfy_ui
RUN printf '#!/usr/bin/env bash\nexec python /opt/model_manager.py "$@"\n' > /opt/venv/bin/model_manager \
    && chmod 0755 /opt/venv/bin/start_comfy_ui /opt/venv/bin/model_manager

# Permissions & trims (keep compilers/headers)
RUN chmod -R a+rwX /opt && chmod +x /opt/*.sh || true && \
    find /opt/venv -type f -name "*.so" -exec strip -s {} + 2>/dev/null || true && \
    find /opt/venv -type d -name "__pycache__" -prune -exec rm -rf {} + && \
    python -m pip cache purge || true && rm -rf /root/.cache/pip || true && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Enable torch TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL
COPY scripts/01-rocm-envs.sh /etc/profile.d/01-rocm-envs.sh

# Banner script (runs on login). Use a high sort key so it runs after venv.sh and 01-rocm-env...
COPY scripts/99-distrobox-banner.sh /etc/profile.d/99-distrobox-banner.sh
RUN chmod 0644 /etc/profile.d/99-distrobox-banner.sh

# Keep /opt/venv/bin first after user dotfiles
COPY scripts/zz-venv-last.sh /etc/profile.d/zz-venv-last.sh
RUN chmod 0644 /etc/profile.d/zz-venv-last.sh

# Disable core dumps in interactive shells (helps with recovering faster from ROCm crashes)
RUN printf 'ulimit -S -c 0\n' > /etc/profile.d/90-nocoredump.sh && chmod 0644 /etc/profile.d/90-nocoredump.sh

CMD ["/bin/bash"]
