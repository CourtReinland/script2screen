"""OpenAI video provider — adapts OpenAIVideoClient to VideoProvider.

OpenAI's Sora API is async (POST returns a job id, polled at GET).
This adapter implements the same VideoProvider interface as
FreepikVideoProvider / GrokVideoProvider so the rest of the pipeline
doesn't have to know who's behind the curtain.
"""

from __future__ import annotations

import logging
from typing import Optional

from .providers import VideoProvider
from .openai_video_client import OpenAIVideoClient, DEFAULT_MODEL

logger = logging.getLogger("ScriptToScreen")


class OpenAIVideoProvider(VideoProvider):
    """OpenAI Sora video generation provider."""

    def __init__(self, api_key: str = "", server_url: str = "", **kwargs):
        # Allow caller to pass `model="sora-2-pro"` via kwargs; fall back to
        # the default sora-2.
        model = kwargs.get("model") or kwargs.get("video_model") or DEFAULT_MODEL
        self._client = OpenAIVideoClient(api_key, model=model)
        self.model = model

    def test_connection(self) -> bool:
        ok, _ = self._client.test_connection_details()
        return ok

    def test_connection_details(self) -> tuple[bool, str]:
        return self._client.test_connection_details()

    def generate_video(
        self,
        prompt: str,
        start_image_path: Optional[str] = None,
        duration: int = 8,
        **kwargs,
    ) -> str:
        """Submit a Sora video generation job. Returns the OpenAI job id.

        Sora 2 doesn't currently support image-to-video via the public API
        endpoint we know of, so ``start_image_path`` is ignored with a
        debug log if provided.
        """
        if start_image_path:
            logger.debug(
                "[OpenAI] start_image_path ignored — Sora 2 public API is "
                "text-to-video only"
            )
        # The wizard's Step 8 video model selector lets users pick e.g.
        # "sora-2" or "sora-2-pro" — that flows in via kwargs["video_model"]
        # or kwargs["model"].
        chosen_model = (
            kwargs.get("video_model")
            or kwargs.get("model")
            or self.model
        )
        return self._client.generate_video(
            prompt=prompt,
            aspect_ratio=kwargs.get("aspect_ratio", "widescreen_16_9"),
            duration=duration,
            model=chosen_model,
        )

    def check_video_status(self, task_id: str) -> dict:
        return self._client.check_video_status(task_id)

    def download_video(self, ref, save_path: str) -> str:
        return self._client.download_video(ref, save_path)
