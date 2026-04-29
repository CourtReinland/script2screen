"""Gemini/Imagen image provider — adapts GeminiImageClient to ImageProvider.

Same pattern as the OpenAI provider: the underlying API is synchronous,
so ``generate_image()`` blocks until the image is produced, caches the
result locally, and returns a cache_id that ``check_image_status()``
returns immediately.
"""

from __future__ import annotations

import logging
from typing import Optional

from .providers import ImageProvider
from .gemini_image_client import GeminiImageClient, DEFAULT_MODEL, SUPPORTED_MODELS

logger = logging.getLogger("ScriptToScreen")


class GeminiImageProvider(ImageProvider):
    """Google AI Studio image generation provider.

    Supports both Gemini multimodal models (``gemini-*-image*``) and
    Imagen (``imagen-*``) via the same API key. The model id determines
    which endpoint the underlying client hits.
    """

    def __init__(self, api_key: str = "", server_url: str = "", **kwargs):
        model = kwargs.get("model", DEFAULT_MODEL)
        self._client = GeminiImageClient(api_key, model=model)
        self.model = model

    def test_connection(self) -> bool:
        ok, _ = self._client.test_connection_details()
        return ok

    def test_connection_details(self) -> tuple[bool, str]:
        return self._client.test_connection_details()

    def generate_image(
        self,
        prompt: str,
        style_reference_path: Optional[str] = None,
        style_adherence: int = 50,                   # unsupported, ignored
        aspect_ratio: str = "widescreen_16_9",
        **kwargs,
    ) -> str:
        # Prefer the Gemini-specific override; tolerate the generic ``model``
        # kwarg (which sometimes carries a Freepik Mystic style name like
        # "realism" — that would 400 here, so guard with SUPPORTED_MODELS).
        chosen = kwargs.get("gemini_model") or kwargs.get("model") or self.model
        if chosen not in SUPPORTED_MODELS:
            logger.info(
                f"[Gemini] {chosen!r} is not a recognized Gemini/Imagen model "
                f"— falling back to {DEFAULT_MODEL!r}. Set gemini_model on "
                f"GenerationDefaults to choose explicitly."
            )
            chosen = DEFAULT_MODEL

        # Collect reference images for multimodal conditioning. Gemini's
        # image-gen models ("Nano Banana" / "Nano Banana Pro") use these
        # to lock style and character likeness — without them, output
        # diverges visibly from the reference. Order matters: style first
        # (sets the visual treatment), then per-character images (lock
        # likeness). Imagen models discard these inside the client.
        refs: list[str] = []
        if style_reference_path:
            refs.append(style_reference_path)
        char_refs = kwargs.get("character_refs") or {}
        if isinstance(char_refs, dict):
            for name, path in char_refs.items():
                if path:
                    refs.append(path)

        return self._client.generate_image(
            prompt=prompt,
            aspect_ratio=aspect_ratio,
            model=chosen,
            n=kwargs.get("n", 1),
            output_format=kwargs.get("output_format", "png"),
            reference_images=refs or None,
        )

    def check_image_status(self, task_id: str) -> dict:
        return self._client.check_image_status(task_id)

    def download_image(self, ref, save_path: str) -> str:
        return self._client.download_image(ref, save_path)

    def build_prompt(self, base_prompt: str, character_refs: dict[str, str]) -> str:
        """Gemini has no Freepik-style @mentions; pass the base prompt
        through. If we know which characters appear, append them as a
        light context hint so the model has the cast in mind.
        """
        if character_refs:
            names = ", ".join(character_refs.keys())
            return f"{base_prompt}\n\nFeatured characters: {names}"
        return base_prompt
