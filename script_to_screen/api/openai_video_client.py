"""REST client for OpenAI's Sora video generation API.

Targets ``sora-2`` and ``sora-2-pro``. Unlike the Images API, the Videos
API is **async** — POST /videos returns a job id that must be polled at
GET /videos/{id}, and the rendered video bytes are downloaded from
GET /videos/{id}/content.

Status enum: ``queued`` | ``in_progress`` | ``completed`` | ``failed``.
"""

from __future__ import annotations

import logging
from typing import Optional

import requests

logger = logging.getLogger("ScriptToScreen")

BASE_URL = "https://api.openai.com/v1"
DEFAULT_MODEL = "sora-2"

# Map ScriptToScreen aspect-ratio slugs → Sora's explicit size strings.
# Sora only supports a fixed set of resolutions, so anything unrecognized
# falls back to widescreen 1280x720.
ASPECT_TO_SIZE = {
    "widescreen_16_9":   "1280x720",
    "social_story_9_16": "720x1280",
    "traditional_3_4":   "1024x1792",  # tall portrait
    "wide_landscape":    "1792x1024",
    # Pass-through pixel forms
    "1280x720":  "1280x720",
    "720x1280":  "720x1280",
    "1024x1792": "1024x1792",
    "1792x1024": "1792x1024",
}


def _map_aspect(aspect: str) -> str:
    return ASPECT_TO_SIZE.get(aspect, "1280x720")


def _map_seconds(duration_seconds: int) -> int:
    """Sora only accepts 4, 8, or 12. Snap to the nearest allowed value."""
    allowed = (4, 8, 12)
    return min(allowed, key=lambda v: abs(v - int(duration_seconds)))


class OpenAIVideoClient:
    """Low-level HTTP wrapper for OpenAI's Videos (Sora) API."""

    def __init__(self, api_key: str, model: str = DEFAULT_MODEL):
        self.api_key = api_key
        self.model = model
        self._session = requests.Session()
        self._session.headers.update({
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        })

    # ------------------------------------------------------------------
    # Connection test
    # ------------------------------------------------------------------

    def test_connection_details(self) -> tuple[bool, str]:
        """Verify credentials by listing models. Sora is gated; a 200
        response means the key works for the OpenAI API in general, but
        not necessarily that this account has Sora access yet — that
        will surface on the first generate_video call instead.
        """
        try:
            r = self._session.get(f"{BASE_URL}/models", timeout=15)
            if r.status_code == 200:
                return True, f"Connected to OpenAI API (Sora target: {self.model})"
            if r.status_code == 401:
                return False, "Invalid OpenAI API key"
            if r.status_code == 429:
                return True, "Reachable (rate limited currently)"
            return False, f"HTTP {r.status_code}: {r.text[:120]}"
        except requests.RequestException as e:
            return False, f"Connection error: {e}"

    # ------------------------------------------------------------------
    # Generate video
    # ------------------------------------------------------------------

    def generate_video(
        self,
        prompt: str,
        aspect_ratio: str = "widescreen_16_9",
        duration: int = 8,
        model: Optional[str] = None,
        **_unused,
    ) -> str:
        """Submit a Sora video generation job. Returns the job id (string)
        suitable for `check_video_status()` and `download_video()`.
        """
        size = _map_aspect(aspect_ratio)
        seconds = _map_seconds(duration)
        used_model = model or self.model

        body = {
            "model": used_model,
            "prompt": prompt,
            "size": size,
            "seconds": str(seconds),  # API accepts string per docs
        }

        logger.info(
            f"[OpenAI] POST /v1/videos  model={used_model}  size={size}  seconds={seconds}"
        )
        r = self._session.post(f"{BASE_URL}/videos", json=body, timeout=60)
        if r.status_code != 200:
            raise RuntimeError(
                f"OpenAI video create failed (HTTP {r.status_code}): "
                f"{r.text[:300]}"
            )
        data = r.json()
        job_id = data.get("id") or ""
        if not job_id:
            raise RuntimeError(f"OpenAI returned no video id: {data}")
        logger.info(f"[OpenAI] Sora job created: {job_id}")
        return job_id

    # ------------------------------------------------------------------
    # Poll status
    # ------------------------------------------------------------------

    def check_video_status(self, job_id: str) -> dict:
        """Poll a Sora job. Returns a normalized dict matching the
        VideoProvider contract: {status, videos, error}.
        """
        r = self._session.get(f"{BASE_URL}/videos/{job_id}", timeout=30)
        if r.status_code != 200:
            return {
                "status": "FAILED",
                "videos": [],
                "error": f"HTTP {r.status_code}: {r.text[:200]}",
            }
        data = r.json() or {}
        raw_status = (data.get("status") or "").lower()

        # Map Sora's lowercase enum → poller's normalized values.
        status_map = {
            "queued":      "IN_PROGRESS",
            "in_progress": "IN_PROGRESS",
            "completed":   "COMPLETED",
            "failed":      "FAILED",
        }
        status = status_map.get(raw_status, raw_status.upper() or "UNKNOWN")

        videos = []
        if status == "COMPLETED":
            # The video itself is at /v1/videos/{id}/content — surface that
            # path here so download_video() can fetch it.
            videos = [f"openai-video://{job_id}"]

        error = None
        if status == "FAILED":
            err = data.get("error") or {}
            if isinstance(err, dict):
                error = err.get("message") or err.get("code") or "Unknown error"
            else:
                error = str(err)

        return {
            "status": status,
            "videos": videos,
            "error": error,
        }

    # ------------------------------------------------------------------
    # Download
    # ------------------------------------------------------------------

    def download_video(self, video_ref, save_path: str) -> str:
        """Download the rendered video bytes to ``save_path``.

        ``video_ref`` is either:
          - the sentinel "openai-video://{job_id}" produced by
            check_video_status() (preferred), or
          - a raw job_id string (we'll synthesize the URL).
        """
        if isinstance(video_ref, dict):
            video_ref = video_ref.get("url") or video_ref.get("id") or ""
        ref = str(video_ref)
        if ref.startswith("openai-video://"):
            job_id = ref[len("openai-video://"):]
        else:
            job_id = ref

        url = f"{BASE_URL}/videos/{job_id}/content"
        # Don't send Content-Type: application/json on this GET — the
        # response is a binary stream.
        headers = {"Authorization": f"Bearer {self.api_key}"}
        r = requests.get(url, headers=headers, timeout=300, stream=True)
        if r.status_code != 200:
            raise RuntimeError(
                f"OpenAI video download failed (HTTP {r.status_code}): "
                f"{r.text[:200]}"
            )
        with open(save_path, "wb") as f:
            for chunk in r.iter_content(chunk_size=1024 * 256):
                if chunk:
                    f.write(chunk)
        logger.info(f"[OpenAI] Downloaded video to {save_path}")
        return save_path
