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

# Helper scripts (ComfyUI-only)
COPY scripts/get_wan22.sh /opt/
COPY scripts/set_extra_paths.sh /opt/
COPY scripts/get_qwen_image.sh /opt/
COPY scripts/get_hunyuan15.sh /opt/
COPY scripts/get_ltx2.sh /opt/
COPY scripts/benchmark_workflows.py /opt/
COPY scripts/collect_perf_logs.py /opt/
COPY scripts/model_manager.py /opt/
COPY workflows/API /opt/comfy-workflows


# ROCm + PyTorch (TheRock, include torchaudio for resolver; remove later)
RUN python -m pip install \
    --index-url https://rocm.nightlies.amd.com/v2-staging/gfx1151 \
    --pre torch torchaudio torchvision

WORKDIR /opt

# Pin specific transformers version
RUN python -m pip install gguf transformers==4.56.2

# ComfyUI
RUN git clone --depth=1 https://github.com/comfyanonymous/ComfyUI.git /opt/ComfyUI 
WORKDIR /opt/ComfyUI
RUN python -m pip install -r requirements.txt && \
    python -m pip install --prefer-binary \
    pillow opencv-python-headless imageio imageio-ffmpeg scipy "huggingface_hub[hf_transfer]" pyyaml websocket-client

COPY workflows/input/ai-server.jpg /opt/ComfyUI/input/
COPY workflows/input/ai-server-2.png /opt/ComfyUI/input/
COPY workflows/input/example2.jpg /opt/ComfyUI/input/

COPY workflows/*.json /opt/ComfyUI/user/default/workflows/

# ComfyUI plugins
WORKDIR /opt/ComfyUI/custom_nodes
RUN git clone --depth=1 https://github.com/cubiq/ComfyUI_essentials /opt/ComfyUI/custom_nodes/ComfyUI_essentials 
RUN git clone --depth=1 https://github.com/kyuz0/ComfyUI-AMDGPUMonitor /opt/ComfyUI/custom_nodes/ComfyUI-AMDGPUMonitor 
RUN git clone --depth=1 https://github.com/city96/ComfyUI-GGUF /opt/ComfyUI/custom_nodes/ComfyUI-GGUF 

# Qwen Image Studio
WORKDIR /opt
RUN git clone --depth=1 https://github.com/kyuz0/qwen-image-studio /opt/qwen-image-studio && \
    python -m pip install -r /opt/qwen-image-studio/requirements.txt

# Wan Video Studio
RUN git clone --depth=1 https://github.com/kyuz0/wan-video-studio /opt/wan-video-studio && \
    python -m pip install --prefer-binary \
    opencv-python-headless diffusers tokenizers accelerate \
    imageio[ffmpeg] easydict ftfy dashscope imageio-ffmpeg decord librosa 

# Permissions & trims (keep compilers/headers)
RUN chmod -R a+rwX /opt && chmod +x /opt/*.sh || true && \
    find /opt/venv -type f -name "*.so" -exec strip -s {} + 2>/dev/null || true && \
    find /opt/venv -type d -name "__pycache__" -prune -exec rm -rf {} + && \
    python -m pip cache purge || true && rm -rf /root/.cache/pip || true && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Enable torch TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL
COPY scripts/01-rocm-envs.sh /etc/profile.d/01-rocm-envs.sh

# Banner script (runs on login). Use a high sort key so it runs after venv.sh and 01-rocm-env...
COPY scripts/99-toolbox-banner.sh /etc/profile.d/99-toolbox-banner.sh
RUN chmod 0644 /etc/profile.d/99-toolbox-banner.sh

# Keep /opt/venv/bin first after user dotfiles
COPY scripts/zz-venv-last.sh /etc/profile.d/zz-venv-last.sh
RUN chmod 0644 /etc/profile.d/zz-venv-last.sh

# Disable core dumps in interactive shells (helps with recovering faster from ROCm crashes)
RUN printf 'ulimit -S -c 0\n' > /etc/profile.d/90-nocoredump.sh && chmod 0644 /etc/profile.d/90-nocoredump.sh

CMD ["/bin/bash"]
