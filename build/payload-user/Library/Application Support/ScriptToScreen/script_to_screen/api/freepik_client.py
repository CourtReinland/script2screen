"""Freepik API client for image generation, video generation, and lip-sync."""

import logging
import time
from typing import Optional

import requests

from ..utils import RateLimiter, image_to_base64

logger = logging.getLogger("ScriptToScreen")

BASE_URL = "https://api.freepik.com/v1"


class FreepikClient:
    """Client for Freepik AI generation APIs."""

    def __init__(self, api_key: str):
        self.api_key = api_key
        self.session = requests.Session()
        self.session.headers.update({
            "x-freepik-api-key": api_key,
            "Content-Type": "application/json",
            "Accept": "application/json",
        })
        self.image_limiter = RateLimiter(calls_per_minute=10)
        self.video_limiter = RateLimiter(calls_per_minute=5)

    def test_connection(self) -> bool:
        """Test if the API key is valid."""
        ok, _ = self.test_connection_details()
        return ok

    def test_connection_details(self) -> tuple[bool, str]:
        """Test API key and return a user-facing diagnostic message."""
        try:
            # /resources is a lightweight authenticated endpoint.
            resp = self.session.get(f"{BASE_URL}/resources", timeout=10)
        except requests.RequestException as exc:
            return False, f"Network error: {exc}"

        if resp.status_code == 200:
            return True, "Connected"
        if resp.status_code == 401:
            return False, "Unauthorized (401): invalid API key"
        if resp.status_code == 402:
            return False, "Payment required (402): account credits or billing issue"
        if resp.status_code == 403:
            return False, "Forbidden (403): account/key permissions issue"
        if resp.status_code == 429:
            return False, "Rate limited (429): try again shortly"

        body = (resp.text or "").strip().replace("\n", " ")
        return False, f"HTTP {resp.status_code}: {body[:120]}"

    # ── Image Generation (Mystic) ──────────────────────────────────────

    def generate_image(
        self,
        prompt: str,
        style_reference_path: Optional[str] = None,
        style_adherence: int = 50,
        model: str = "realism",
        aspect_ratio: str = "widescreen_16_9",
        creative_detailing: int = 33,
    ) -> str:
        """
        Generate an image using Freepik Mystic API.

        Returns:
            task_id for polling.
        """
        self.image_limiter.wait()

        payload = {
            "prompt": prompt,
            "model": model,
            "aspect_ratio": aspect_ratio,
            "creative_detailing": creative_detailing,
            "filter_nsfw": False,
        }

        if style_reference_path:
            payload["style_reference"] = image_to_base64(style_reference_path)
            payload["adherence"] = style_adherence

        resp = self._post(f"{BASE_URL}/ai/mystic", payload)
        data = resp.get("data", resp)
        task_id = data.get("task_id", data.get("id", ""))
        logger.info(f"Image generation started: {task_id}")
        return task_id

    def check_image_status(self, task_id: str) -> dict:
        """Check status of an image generation task."""
        resp = self._get(f"{BASE_URL}/ai/mystic/{task_id}")
        data = resp.get("data", resp)
        return {
            "status": data.get("status", "UNKNOWN"),
            "images": data.get("generated", []),
            "error": data.get("error", None),
        }

    def download_image(self, url: str, save_path: str) -> str:
        """Download a generated image to local path."""
        resp = requests.get(url, timeout=60)
        resp.raise_for_status()
        with open(save_path, "wb") as f:
            f.write(resp.content)
        return save_path

    # ── Video Generation (Kling 3 Omni) ──────────────────────────────

    def generate_video(
        self,
        prompt: str,
        start_image_path: Optional[str] = None,
        start_image_url: Optional[str] = None,
        duration: int = 5,
        negative_prompt: str = "",
        cfg_scale: float = 0.5,
    ) -> str:
        """
        Generate a video using Kling 3 Omni via Freepik.

        Provide either start_image_path (local file) or start_image_url.

        Returns:
            task_id for polling.
        """
        self.video_limiter.wait()

        payload = {
            "prompt": prompt,
            "duration": duration,
            "cfg_scale": cfg_scale,
        }

        if start_image_path:
            # Kling v3 Omni API expects "image_url" with a data URI for local files
            b64 = image_to_base64(start_image_path)
            ext = start_image_path.rsplit(".", 1)[-1].lower()
            mime = {"png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg"}.get(ext, "image/png")
            payload["image_url"] = f"data:{mime};base64,{b64}"
            logger.info(f"Video generation: using start frame from {start_image_path}")
        elif start_image_url:
            payload["image_url"] = start_image_url
        else:
            logger.info("Video generation: no start image, using text-to-video mode")

        if negative_prompt:
            payload["negative_prompt"] = negative_prompt

        resp = self._post(
            f"{BASE_URL}/video/kling-v3-omni/generate-pro", payload
        )
        data = resp.get("data", resp)
        task_id = data.get("task_id", data.get("id", ""))
        logger.info(f"Video generation started: {task_id}")
        return task_id

    def check_video_status(self, task_id: str) -> dict:
        """Check status of a video generation task."""
        resp = self._get(f"{BASE_URL}/video/kling-v3-omni/{task_id}")
        data = resp.get("data", resp)
        return {
            "status": data.get("status", "UNKNOWN"),
            "videos": data.get("generated", data.get("videos", [])),
            "error": data.get("error", None),
        }

    def download_video(self, url: str, save_path: str) -> str:
        """Download a generated video to local path."""
        resp = requests.get(url, timeout=120, stream=True)
        resp.raise_for_status()
        with open(save_path, "wb") as f:
            for chunk in resp.iter_content(chunk_size=8192):
                f.write(chunk)
        return save_path

    # ── Lip Sync (Kling via Freepik) ─────────────────────────────────

    def generate_lipsync(
        self,
        video_url: str,
        audio_url: Optional[str] = None,
        tts_text: Optional[str] = None,
        tts_timbre: Optional[str] = None,
    ) -> str:
        """
        Generate lip-synced video using Kling lip-sync.

        Provide either audio_url (pre-generated audio) or tts_text for built-in TTS.

        Returns:
            task_id for polling.
        """
        self.video_limiter.wait()

        payload = {
            "video_url": video_url,
        }

        if audio_url:
            payload["local_dubbing_url"] = audio_url
        elif tts_text:
            payload["tts_text"] = tts_text
            if tts_timbre:
                payload["tts_timbre"] = tts_timbre

        resp = self._post(f"{BASE_URL}/video/kling-lipsync/generate", payload)
        data = resp.get("data", resp)
        task_id = data.get("task_id", data.get("id", ""))
        logger.info(f"Lip-sync started: {task_id}")
        return task_id

    def check_lipsync_status(self, task_id: str) -> dict:
        """Check status of a lip-sync task."""
        resp = self._get(f"{BASE_URL}/video/kling-lipsync/{task_id}")
        data = resp.get("data", resp)
        return {
            "status": data.get("status", "UNKNOWN"),
            "videos": data.get("generated", data.get("videos", [])),
            "error": data.get("error", None),
        }

    # ── Internal Helpers ─────────────────────────────────────────────

    def _post(self, url: str, payload: dict) -> dict:
        """POST with retry on rate limit."""
        for attempt in range(3):
            resp = self.session.post(url, json=payload, timeout=60)
            if resp.status_code == 429:
                wait = 2 ** (attempt + 1)
                logger.warning(f"Rate limited, waiting {wait}s...")
                time.sleep(wait)
                continue
            resp.raise_for_status()
            return resp.json()
        resp.raise_for_status()
        return resp.json()

    def _get(self, url: str) -> dict:
        """GET with retry on rate limit."""
        for attempt in range(3):
            resp = self.session.get(url, timeout=30)
            if resp.status_code == 429:
                wait = 2 ** (attempt + 1)
                logger.warning(f"Rate limited, waiting {wait}s...")
                time.sleep(wait)
                continue
            resp.raise_for_status()
            return resp.json()
        resp.raise_for_status()
        return resp.json()
