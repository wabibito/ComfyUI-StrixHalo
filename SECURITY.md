# Security Policy

## Reporting a vulnerability

If you find a security issue in this project's **own** code (the scripts,
Dockerfile, or vendoring tooling), please report it privately:

- Open a [GitHub security advisory](https://github.com/wabibito/ComfyUI-StrixHalo/security/advisories/new), or
- Email the maintainer (see the GitHub profile).

Please don't open a public issue for an unfixed vulnerability.

## Scope

In scope:

- The host scripts (`host-setup-ubuntu.sh`, `setup-kernel-ubuntu.sh`),
  `build-image.sh`, `refresh-distrobox.sh`, `vendor.sh`, and the in-image
  helpers under `scripts/`.

Out of scope (report upstream — see [NOTICE.md](NOTICE.md)):

- Vulnerabilities in vendored components (ComfyUI, the custom nodes, the
  studios) or in ROCm/PyTorch/model weights.

## Notes on this project's threat model

- The container runs with GPU passthrough (`--device /dev/kfd /dev/dri`) and
  `--security-opt seccomp=unconfined` — this is required for ROCm and is a
  deliberate, documented trade-off. Run it on hardware you trust.
- `setup-kernel-ubuntu.sh` edits GRUB and runs `sudo`. It backs up
  `/etc/default/grub` first and supports `--dry-run`. Review before applying.
- Model-download scripts fetch weights from Hugging Face over HTTPS; verify the
  repositories you pull from.
