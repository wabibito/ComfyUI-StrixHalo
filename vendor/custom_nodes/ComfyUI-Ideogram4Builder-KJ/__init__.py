# SPDX-License-Identifier: GPL-3.0-or-later
# Ideogram 4 Prompt Builder KJ (V1) — vendored subset of kijai/ComfyUI-KJNodes.
# Visual canvas builder that emits Ideogram 4's structured JSON caption; wire its
# output into a CLIPTextEncode (CLIP type "ideogram4"). Only the Ideogram node is
# vendored (self-contained: pillow/numpy/torch/comfy_api), not the full KJNodes
# pack. See .vendor-source for origin/commit/attribution.
from .nodes.ideogram4_nodes import Ideogram4PromptBuilderKJ

NODE_CLASS_MAPPINGS = {"Ideogram4PromptBuilderKJ": Ideogram4PromptBuilderKJ}
NODE_DISPLAY_NAME_MAPPINGS = {"Ideogram4PromptBuilderKJ": "Ideogram 4 Prompt Builder KJ"}
WEB_DIRECTORY = "./web/js"
__all__ = ["NODE_CLASS_MAPPINGS", "NODE_DISPLAY_NAME_MAPPINGS", "WEB_DIRECTORY"]
