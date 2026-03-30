"""Kling AI provider for lip sync via direct API (JWT auth with AK/SK)."""

import logging
import os
from typing import Optional

from .providers import LipsyncProvider
from .kling_client import KlingClient

logger = logging.getLogger("ScriptToScreen")


class KlingLipsyncProvider(LipsyncProvider):
    """Lip sync via Kling AI direct API.

    Requires access_key and secret_key from https://klingai.com.
    Uses JWT (HS256) authentication — NOT the same as Freepik's API key.
    """

    def __init__(self, api_key: str = "", server_url: str = "", **kwargs):
        # api_key format: "access_key:secret_key" (colon-separated)
        # or passed separately via kwargs
        access_key = kwargs.get("access_key", "")
        secret_key = kwargs.get("secret_key", "")

        if not access_key and ":" in api_key:
            # Parse "access_key:secret_key" format
            parts = api_key.split(":", 1)
            access_key = parts[0]
            secret_key = parts[1]
        elif not access_key:
            access_key = api_key

        base_url = server_url if server_url else "https://api.klingai.com"
        self._client = KlingClient(access_key, secret_key, base_url=base_url)

    def test_connection(self) -> bool:
        ok, _ = self._client.test_connection_details()
        return ok

    def test_connection_details(self) -> tuple[bool, str]:
        return self._client.test_connection_details()

    def generate_lipsync(
        self,
        video_path_or_url: str,
        audio_path_or_url: str,
        **kwargs,
    ) -> str:
        """Submit a lip sync task. Returns task_id for polling.

        Both video and audio can be local file paths or URLs.
        Local files are converted to base64 (audio) or need to be
        accessible via URL (video — Kling requires a URL for video).
        """
        # Handle video source
        video_url = None
        if video_path_or_url.startswith("http"):
            video_url = video_path_or_url
        elif os.path.isfile(video_path_or_url):
            # Kling requires a video URL, not base64
            # For local files, we'd need to upload somewhere first
            # For now, raise an error — the user should provide a URL
            raise ValueError(
                f"Kling lip sync requires a video URL, not a local file. "
                f"Please upload {os.path.basename(video_path_or_url)} to a public URL first."
            )
        else:
            raise FileNotFoundError(f"Video not found: {video_path_or_url}")

        # Handle audio source
        audio_url = None
        audio_b64 = None
        if audio_path_or_url.startswith("http"):
            audio_url = audio_path_or_url
        elif os.path.isfile(audio_path_or_url):
            # Kling accepts base64-encoded audio files (max 5MB)
            file_size = os.path.getsize(audio_path_or_url)
            if file_size > 5 * 1024 * 1024:
                raise ValueError(
                    f"Audio file too large ({file_size / 1024 / 1024:.1f}MB). "
                    f"Kling accepts max 5MB for base64 audio."
                )
            audio_b64 = KlingClient.audio_to_base64(audio_path_or_url)
            logger.info(f"[Kling] Encoded audio: {os.path.basename(audio_path_or_url)} ({file_size} bytes)")
        else:
            raise FileNotFoundError(f"Audio not found: {audio_path_or_url}")

        return self._client.create_lipsync_task(
            video_url=video_url,
            audio_url=audio_url,
            audio_file_b64=audio_b64,
            mode="audio2video",
        )

    def check_lipsync_status(self, task_id: str) -> dict:
        return self._client.query_lipsync_task(task_id)

    def download_video(self, ref, save_path: str) -> str:
        url = ref if isinstance(ref, str) else ref.get("url", ref)
        return self._client.download_video(url, save_path)
