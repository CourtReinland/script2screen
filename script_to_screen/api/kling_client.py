"""REST client for the Kling AI API (lip sync, video generation).

Kling uses JWT authentication with an access_key (AK) and secret_key (SK).
A short-lived JWT token is generated for each request batch.

API docs: https://app.klingai.com/global/dev/document-api
"""

import base64
import logging
import mimetypes
import os
import time
from typing import Optional

import jwt
import requests

logger = logging.getLogger("ScriptToScreen")

# Kling API base URLs
# Global endpoint (use this for non-China accounts)
BASE_URL_GLOBAL = "https://api.klingai.com"
# Beijing endpoint (for China-region accounts)
BASE_URL_BEIJING = "https://api-beijing.klingai.com"


class KlingClient:
    """Low-level HTTP wrapper for the Kling AI API with JWT auth."""

    def __init__(
        self,
        access_key: str,
        secret_key: str,
        base_url: str = BASE_URL_GLOBAL,
        token_expire_seconds: int = 1800,
    ):
        self.access_key = access_key
        self.secret_key = secret_key
        self.base_url = base_url.rstrip("/")
        self.token_expire_seconds = token_expire_seconds
        self._session = requests.Session()
        self._token: Optional[str] = None
        self._token_expires_at: float = 0

    # ------------------------------------------------------------------
    # JWT Token Management
    # ------------------------------------------------------------------

    def _generate_token(self) -> str:
        """Generate a JWT token using access_key and secret_key."""
        now = int(time.time())
        headers = {"alg": "HS256", "typ": "JWT"}
        payload = {
            "iss": self.access_key,
            "exp": now + self.token_expire_seconds,
            "nbf": now - 5,
        }
        token = jwt.encode(payload, self.secret_key, headers=headers)
        self._token = token
        self._token_expires_at = now + self.token_expire_seconds - 60  # refresh 1min early
        logger.info("[Kling] Generated new JWT token")
        return token

    def _get_token(self) -> str:
        """Get a valid token, refreshing if needed."""
        if not self._token or time.time() >= self._token_expires_at:
            return self._generate_token()
        return self._token

    def _auth_headers(self) -> dict:
        """Build headers with current auth token."""
        token = self._get_token()
        return {
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        }

    # ------------------------------------------------------------------
    # Connection test
    # ------------------------------------------------------------------

    def test_connection_details(self) -> tuple[bool, str]:
        """Verify the API credentials by making a simple request."""
        try:
            # Try listing video tasks as a connection test
            r = requests.get(
                f"{self.base_url}/v1/videos/text2video",
                headers=self._auth_headers(),
                timeout=15,
            )
            if r.status_code == 200:
                return True, "Connected to Kling AI API"
            elif r.status_code == 401:
                return False, "Invalid access key or secret key"
            elif r.status_code == 403:
                return False, "Access forbidden — check your API plan"
            else:
                return True, f"Kling API responded (HTTP {r.status_code})"
        except requests.RequestException as e:
            return False, f"Connection error: {e}"

    # ------------------------------------------------------------------
    # Lip Sync
    # ------------------------------------------------------------------

    def create_lipsync_task(
        self,
        video_url: Optional[str] = None,
        video_id: Optional[str] = None,
        audio_url: Optional[str] = None,
        audio_file_b64: Optional[str] = None,
        mode: str = "audio2video",
        text: Optional[str] = None,
        voice_id: Optional[str] = None,
        voice_language: str = "en",
        callback_url: Optional[str] = None,
    ) -> str:
        """Create a lip sync task. Returns task_id.

        For audio2video mode: provide video_url + audio_url (or audio_file_b64).
        For text2video mode: provide video_url + text + voice_id + voice_language.
        """
        body: dict = {"input": {"mode": mode}}

        # Video source (one of video_url or video_id)
        if video_url:
            body["input"]["video_url"] = video_url
        elif video_id:
            body["input"]["video_id"] = video_id
        else:
            raise ValueError("Either video_url or video_id must be provided")

        # Audio source
        if mode == "audio2video":
            if audio_url:
                body["input"]["audio_type"] = "url"
                body["input"]["audio_url"] = audio_url
            elif audio_file_b64:
                body["input"]["audio_type"] = "file"
                body["input"]["audio_file"] = audio_file_b64
            else:
                raise ValueError("audio2video mode requires audio_url or audio_file_b64")
        elif mode == "text2video":
            if not text:
                raise ValueError("text2video mode requires text")
            body["input"]["text"] = text[:120]  # max 120 chars
            body["input"]["voice_id"] = voice_id or "default"
            body["input"]["voice_language"] = voice_language

        if callback_url:
            body["callback_url"] = callback_url

        logger.info(f"[Kling] POST /v1/videos/lip-sync  mode={mode}")
        r = requests.post(
            f"{self.base_url}/v1/videos/lip-sync",
            headers=self._auth_headers(),
            json=body,
            timeout=30,
        )
        if r.status_code != 200:
            logger.error(f"[Kling] lip-sync failed: {r.status_code} {r.text[:300]}")
        r.raise_for_status()

        data = r.json()
        if data.get("code") != 0:
            raise RuntimeError(f"Kling API error: {data.get('message', 'unknown')}")

        task_id = data["data"]["task_id"]
        logger.info(f"[Kling] Lip sync task created: {task_id}")
        return task_id

    def query_lipsync_task(self, task_id: str) -> dict:
        """Poll lip sync task status. Returns normalized status dict."""
        r = requests.get(
            f"{self.base_url}/v1/videos/lip-sync/{task_id}",
            headers=self._auth_headers(),
            timeout=15,
        )
        r.raise_for_status()
        data = r.json()

        if data.get("code") != 0:
            return {
                "status": "FAILED",
                "videos": [],
                "error": data.get("message", "Unknown error"),
            }

        task_data = data.get("data", {})
        status = task_data.get("task_status", "unknown")

        if status == "succeed":
            # Extract video URL from task results
            videos = []
            for work in task_data.get("task_result", {}).get("videos", []):
                url = work.get("url", "")
                if url:
                    videos.append(url)
            return {"status": "COMPLETED", "videos": videos, "error": None}
        elif status == "failed":
            msg = task_data.get("task_status_msg", "Lip sync failed")
            return {"status": "FAILED", "videos": [], "error": msg}
        else:
            # submitted, processing
            return {"status": "PROCESSING", "videos": [], "error": None}

    def download_video(self, url: str, save_path: str) -> str:
        """Download a video from a URL."""
        r = requests.get(url, timeout=300, stream=True)
        r.raise_for_status()
        with open(save_path, "wb") as f:
            for chunk in r.iter_content(8192):
                f.write(chunk)
        logger.info(f"[Kling] Video saved: {save_path}")
        return save_path

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------

    @staticmethod
    def audio_to_base64(file_path: str) -> str:
        """Encode an audio file to base64 for the audio_file parameter."""
        with open(file_path, "rb") as f:
            return base64.b64encode(f.read()).decode("ascii")
