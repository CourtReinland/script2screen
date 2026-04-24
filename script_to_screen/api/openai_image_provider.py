"""OpenAI image provider — adapts OpenAIImageClient to ImageProvider."""

from __future__ import annotations

import logging
from typing import Optional

from .providers import ImageProvider
from .openai_image_client import OpenAIImageClient, DEFAULT_MODEL

logger = logging.getLogger("ScriptToScreen")


class OpenAIImageProvider(ImageProvider):
    """OpenAI gpt-image-2 image generation provider.

    Since OpenAI's API is synchronous, `generate_image()` blocks until
    the image is produced and then returns a cache_id that
    `check_image_status()` can look up (pattern mirrored from
    grok_client's in-memory cache).
    """

    def __init__(self, api_key: str = "", server_url: str = "", **kwargs):
        model = kwargs.get("model", DEFAULT_MODEL)
        self._client = OpenAIImageClient(api_key, model=model)
        self.model = model

    def test_connection(self) -> bool:
        ok, _ = self._client.test_connection_details()
        return ok

    def test_connection_details(self) -> tuple[bool, str]:
        return self._client.test_connection_details()

    def generate_image(
        self,
        prompt: str,
        style_reference_path: Optional[str] = None,  # unsupported, ignored
        style_adherence: int = 50,                   # unsupported, ignored
        aspect_ratio: str = "widescreen_16_9",
        **kwargs,
    ) -> str:
        """Submit image generation; returns cache_id for polling."""
        if style_reference_path:
            logger.info(
                "[OpenAI] style_reference_path provided but not supported "
                "by gpt-image-2 generations endpoint; ignoring."
            )
        return self._client.generate_image(
            prompt=prompt,
            aspect_ratio=aspect_ratio,
            size=kwargs.get("openai_size"),
            quality=kwargs.get("openai_quality", "auto"),
            output_format=kwargs.get("openai_output_format", "png"),
            background=kwargs.get("openai_background", "auto"),
            n=kwargs.get("n", 1),
            model=kwargs.get("model") or self.model,
        )

    def check_image_status(self, task_id: str) -> dict:
        return self._client.check_image_status(task_id)

    def download_image(self, ref, save_path: str) -> str:
        return self._client.download_image(ref, save_path)

    def build_prompt(self, base_prompt: str, character_refs: dict[str, str]) -> str:
        """gpt-image-2 has no Freepik-style @mentions; just pass through.

        If there are character reference names, we add them as context so the
        model at least knows which characters should appear.
        """
        if character_refs:
            names = ", ".join(character_refs.keys())
            return f"{base_prompt}\n\nFeatured characters: {names}"
        return base_prompt
