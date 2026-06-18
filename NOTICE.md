# Attribution & Licensing

**ComfyUI-StrixHalo** packages ComfyUI and several third-party components into a
container image for AMD Strix Halo (gfx1151) under Ubuntu. The original scripts,
Dockerfile, host-setup/kernel/vendoring tooling, and documentation in this
repository are authored by the project maintainer.

## Project license

Because this repository **bundles and redistributes the full ComfyUI source**
(licensed GPL-3.0) as an integral part of the build, the repository as a whole
is distributed under the **GNU General Public License v3.0** — see [LICENSE](LICENSE).

## Vendored components

The `vendor/` directory contains verbatim snapshots of the following upstream
projects. Each retains its own original license file inside its directory, and
each `.vendor-source` file records the exact source URL and commit pinned.

| Component | Upstream | License |
|-----------|----------|---------|
| ComfyUI | https://github.com/comfyanonymous/ComfyUI | GPL-3.0 |
| ComfyUI_essentials | https://github.com/cubiq/ComfyUI_essentials | MIT — © Matteo Spinelli |
| ComfyUI-AMDGPUMonitor | https://github.com/kyuz0/ComfyUI-AMDGPUMonitor | MIT — © iDAPPA |
| ComfyUI-GGUF | https://github.com/city96/ComfyUI-GGUF | Apache-2.0 |
| qwen-image-studio | https://github.com/kyuz0/qwen-image-studio | MIT — © Ivan Fioravanti |
| wan-video-studio | https://github.com/kyuz0/wan-video-studio | Apache-2.0 |

All trademarks (AMD, Ryzen, Radeon, Ubuntu, etc.) belong to their respective
owners. This project is not affiliated with or endorsed by AMD, Canonical,
Hugging Face, or any model provider.

## Built upon

- AMD ROCm and the [TheRock](https://github.com/ROCm/TheRock) gfx1151 PyTorch
  nightly wheels.
- The wider AMD Strix Halo community's work on unified-memory inference tuning.

Model weights downloaded by the helper scripts are subject to the licenses of
their respective Hugging Face repositories and are **not** redistributed here.
