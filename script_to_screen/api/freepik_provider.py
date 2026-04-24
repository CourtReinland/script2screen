"""Freepik as ImageProvider, VideoProvider, and LipsyncProvider."""

from typing import Optional

from .providers import ImageProvider, VideoProvider, LipsyncProvider
from .freepik_client import FreepikClient
from ..utils import sanitize_filename


class FreepikImageProvider(ImageProvider):
    """Wraps FreepikClient for the ImageProvider interface."""

    def __init__(self, api_key: str, model: str = "realism", **kwargs):
        self._client = FreepikClient(api_key)
        self.model = model

    def test_connection(self) -> bool:
        return self._client.test_connection()

    def test_connection_details(self) -> tuple[bool, str]:
        return self._client.test_connection_details()

    def generate_image(self, prompt, style_reference_path=None,
                       style_adherence=50, aspect_ratio="widescreen_16_9",
                       **kwargs) -> str:
        return self._client.generate_image(
            prompt=prompt,
            style_reference_path=style_reference_path,
            style_adherence=style_adherence,
            model=kwargs.get("model", self.model),
            aspect_ratio=aspect_ratio,
            creative_detailing=kwargs.get("creative_detailing", 33),
            # Per-model Mystic options (safe defaults match legacy behavior)
            engine=kwargs.get("freepik_engine", "automatic"),
            resolution=kwargs.get("freepik_resolution", "2k"),
            structure_strength=kwargs.get("freepik_structure_strength", 50),
            structure_reference_path=kwargs.get("structure_reference_path"),
            webhook_url=kwargs.get("webhook_url"),
        )

    def check_image_status(self, task_id: str) -> dict:
        return self._client.check_image_status(task_id)

    def download_image(self, ref, save_path: str) -> str:
        # Freepik returns URL strings or dicts with "url" key
        if isinstance(ref, dict):
            url = ref.get("url", "")
        else:
            url = ref
        return self._client.download_image(url, save_path)

    def build_prompt(self, base_prompt, character_refs):
        """Inject Freepik @mention syntax for character references."""
        mentions = []
        for char_name, ref_path in character_refs.items():
            if ref_path:
                mentions.append(f"@{sanitize_filename(char_name)}::150")
        if mentions:
            return base_prompt + " " + " ".join(mentions)
        return base_prompt


class FreepikVideoProvider(VideoProvider):
    """Wraps FreepikClient for the VideoProvider interface."""

    def __init__(self, api_key: str, **kwargs):
        self._client = FreepikClient(api_key)

    def test_connection(self) -> bool:
        return self._client.test_connection()

    def test_connection_details(self) -> tuple[bool, str]:
        return self._client.test_connection_details()

    def generate_video(self, prompt, start_image_path=None,
                       duration=5, **kwargs) -> str:
        return self._client.generate_video(
            prompt=prompt,
            start_image_path=start_image_path,
            start_image_url=kwargs.get("start_image_url"),
            duration=duration,
            negative_prompt=kwargs.get("negative_prompt", ""),
            cfg_scale=kwargs.get("cfg_scale", 0.5),
            model=kwargs.get("video_model", kwargs.get("model", "kling-v3-omni")),
            webhook_url=kwargs.get("webhook_url"),
        )

    def check_video_status(self, task_id: str) -> dict:
        return self._client.check_video_status(task_id)

    def download_video(self, ref, save_path: str) -> str:
        if isinstance(ref, dict):
            url = ref.get("url", "")
        else:
            url = ref
        return self._client.download_video(url, save_path)


class FreepikLipsyncProvider(LipsyncProvider):
    """Wraps FreepikClient for the LipsyncProvider interface."""

    def __init__(self, api_key: str, **kwargs):
        self._client = FreepikClient(api_key)

    def test_connection(self) -> bool:
        return self._client.test_connection()

    def test_connection_details(self) -> tuple[bool, str]:
        return self._client.test_connection_details()

    def generate_lipsync(self, video_url, audio_url=None, **kwargs) -> str:
        return self._client.generate_lipsync(
            video_url=video_url,
            audio_url=audio_url,
            tts_text=kwargs.get("tts_text"),
            tts_timbre=kwargs.get("tts_timbre"),
        )

    def check_lipsync_status(self, task_id: str) -> dict:
        return self._client.check_lipsync_status(task_id)
