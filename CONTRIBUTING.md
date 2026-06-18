# Contributing

Thanks for your interest in ComfyUI-StrixHalo.

## Scope

This project is the **host glue + build tooling** that runs ComfyUI on AMD Strix
Halo (gfx1151) under Ubuntu via distrobox. Contributions that fit:

- Ubuntu / distrobox / rootless-podman setup fixes
- Dockerfile / vendoring improvements
- Kernel / unified-memory tuning for gfx1151
- Bug fixes in the helper scripts (`scripts/`, the host scripts)

Bugs in the **vendored upstreams** (ComfyUI, the custom nodes, the studios)
should go to their original projects — see [NOTICE.md](NOTICE.md) for links. We
only carry pinned snapshots in `vendor/`.

## Working with vendored sources

`vendor/` is a committed snapshot produced by `./vendor.sh`. Don't hand-edit
files under `vendor/`; instead repoint a component's URL/ref in `vendor.sh`
(e.g. to your fork) and re-run it, then commit the result.

## Before opening a PR

- Keep new shell scripts `bash -n`-clean and add the SPDX header
  (`# SPDX-License-Identifier: GPL-3.0-or-later`) after the shebang.
- Note what you tested. Most build/runtime verification requires real Strix Halo
  hardware (gfx1151) — say what you could and couldn't exercise.
- Match the style of the surrounding scripts (the `log()/warn()/err()` helpers,
  `set -euo pipefail`, etc.).

## License

By contributing you agree your contributions are licensed under **GPL-3.0**, the
license of this repository (see [LICENSE](LICENSE)).
