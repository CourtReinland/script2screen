"""Kling AI provider for lip sync via direct API (JWT auth with AK/SK)."""

import logging
import os
from typing import Optional

import requests as http_requests

from .providers import LipsyncProvider
from .kling_client import KlingClient

logger = logging.getLogger("ScriptToScreen")

# Temporary file hosting for uploading local files to get public URLs.
# Kling's API requires video as a URL — it doesn't accept base64 for video.
# tmpfiles.org provides free anonymous hosting with auto-deletion.
_TMPFILES_UPLOAD_URL = "https://tmpfiles.org/api/v1/upload"


def _upload_to_tmpfiles(file_path: str) -> str:
    """Upload a local file to tmpfiles.org and return a direct download URL.

    Files are automatically deleted after ~1 hour. No account needed.
    This is used to give Kling a public URL for local video/audio files.
    """
    file_size = os.path.getsize(file_path)
    if file_size > 100 * 1024 * 1024:  # 100MB limit
        raise ValueError(f"File too large for upload ({file_size / 1024 / 1024:.0f}MB, max 100MB)")

    logger.info(f"[Kling] Uploading {os.path.basename(file_path)} ({file_size / 1024 / 1024:.1f}MB)...")

    with open(file_path, "rb") as f:
        r = http_requests.post(
            _TMPFILES_UPLOAD_URL,
            files={"file": (os.path.basename(file_path), f)},
            timeout=120,
        )
    r.raise_for_status()
    data = r.json()

    if data.get("status") != "success":
        raise RuntimeError(f"Upload failed: {data}")

    # Convert to direct download URL (add /dl/ prefix)
    url = data["data"]["url"]
    dl_url = url.replace("tmpfiles.org/", "tmpfiles.org/dl/")
    logger.info(f"[Kling] Uploaded → {dl_url}")
    return dl_url


class KlingLipsyncProvider(LipsyncProvider):
    """Lip sync via Kling AI direct API.

    Requires access_key and secret_key from https://klingai.com.
    Uses JWT (HS256) authentication — NOT the same as Freepik's API key.

    Local video/audio files are automatically uploaded to a temporary
    file host (tmpfiles.org) to get public URLs that Kling can access.
    """

    def __init__(self, api_key: str = "", server_url: str = "", **kwargs):
        access_key = kwargs.get("access_key", "")
        secret_key = kwargs.get("secret_key", "")

        if not access_key and ":" in api_key:
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
        video_url: str,
        audio_url: Optional[str] = None,
        **kwargs,
    ) -> str:
        """Submit a lip sync task. Returns task_id for polling.

        Both video and audio can be local file paths or URLs.
        Local video files are uploaded to tmpfiles.org to get a public URL.
        Local audio files can be sent as base64 (preferred) or uploaded.
        """
        video_src = video_url
        audio_src = audio_url or ""

        # Handle video source
        resolved_video_url = None
        if video_src.startswith("http"):
            resolved_video_url = video_src
        elif os.path.isfile(video_src):
            # Upload local video to get a public URL
            resolved_video_url = _upload_to_tmpfiles(video_src)
        else:
            raise FileNotFoundError(f"Video not found: {video_src}")

        # Handle audio source
        resolved_audio_url = None
        audio_b64 = None
        if audio_src.startswith("http"):
            resolved_audio_url = audio_src
        elif os.path.isfile(audio_src):
            file_size = os.path.getsize(audio_src)
            if file_size <= 5 * 1024 * 1024:
                # Small enough for base64 (preferred — no upload needed)
                audio_b64 = KlingClient.audio_to_base64(audio_src)
                logger.info(f"[Kling] Audio as base64: {os.path.basename(audio_src)}")
            else:
                # Too large for base64 — upload instead
                resolved_audio_url = _upload_to_tmpfiles(audio_src)
        else:
            raise FileNotFoundError(f"Audio not found: {audio_src}")

        return self._client.create_lipsync_task(
            video_url=resolved_video_url,
            audio_url=resolved_audio_url,
            audio_file_b64=audio_b64,
            mode="audio2video",
        )

    def check_lipsync_status(self, task_id: str) -> dict:
        return self._client.query_lipsync_task(task_id)

    def download_video(self, ref, save_path: str) -> str:
        url = ref if isinstance(ref, str) else ref.get("url", ref)
        return self._client.download_video(url, save_path)
