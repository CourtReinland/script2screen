"""Freepik API client for image generation, video generation, and lip-sync."""

import logging
import time
from typing import Optional

import requests

from ..utils import RateLimiter, image_to_base64

logger = logging.getLogger("ScriptToScreen")

BASE_URL = "https://api.freepik.com/v1"

# Map internal video model id → (submit path, status path prefix).
# Status path prefix is joined with "/{task_id}" when polling.
# Ref: https://docs.freepik.com/llms.txt
VIDEO_ENDPOINTS: dict[str, tuple[str, str]] = {
    "kling-v3-omni":      ("/video/kling-v3-omni/generate-pro",        "/video/kling-v3-omni"),
    "kling-v2-5-pro":     ("/ai/image-to-video/kling-v2.5-pro",        "/ai/image-to-video/kling-v2.5-pro"),
    "kling-v2-6-pro":     ("/ai/image-to-video/kling-v2-6-pro",        "/ai/image-to-video/kling-v2-6-pro"),
    "kling-o1-pro":       ("/ai/image-to-video/kling-o1-pro",          "/ai/image-to-video/kling-o1-pro"),
    "seedance-pro-1080p": ("/ai/image-to-video/seedance-pro-1080p",    "/ai/image-to-video/seedance-pro-1080p"),
    "minimax-hailuo-2-3": ("/ai/image-to-video/minimax-hailuo-2-3-1080p", "/ai/image-to-video/minimax-hailuo-2-3-1080p"),
    "wan-v2-6-1080p":     ("/ai/image-to-video/wan-v2-6-1080p",        "/ai/image-to-video/wan-v2-6-1080p"),
}

# Mystic engine options
MYSTIC_ENGINES = {"automatic", "magnific_sparkle", "magnific_illusio", "magnific_sharpy"}
MYSTIC_RESOLUTIONS = {"1k", "2k", "4k"}

# Multi-model image generation dispatch.
# Each entry maps an internal API id → its REST submission path (relative to
# BASE_URL). The status-check path is always "<submit_path>/{task_id}".
# Mystic is special-cased above this layer because it accepts a richer
# parameter set (engine, resolution, structure reference, etc.).
IMAGE_ENDPOINTS = {
    "mystic":           "/ai/mystic",
    "flux-dev":         "/ai/text-to-image/flux-dev",
    "flux-pro-v1-1":    "/ai/text-to-image/flux-pro-v1-1",
    "flux-2-pro":       "/ai/text-to-image/flux-2-pro",
    "flux-2-turbo":     "/ai/text-to-image/flux-2-turbo",
    "flux-2-klein":     "/ai/text-to-image/flux-2-klein",
    "flux-kontext-pro": "/ai/text-to-image/flux-kontext-pro",
    "hyperflux":        "/ai/text-to-image/hyperflux",
    "seedream-4":       "/ai/text-to-image/seedream-4",
    "seedream-v4-5":    "/ai/text-to-image/seedream-v4-5",
    "z-image-turbo":    "/ai/text-to-image/z-image-turbo",
    "runway":           "/ai/text-to-image/runway",
}


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
        engine: str = "automatic",
        resolution: str = "2k",
        structure_strength: int = 50,
        structure_reference_path: Optional[str] = None,
        webhook_url: Optional[str] = None,
        image_api: str = "mystic",
        seed: Optional[int] = None,
    ) -> str:
        """
        Generate an image via one of Freepik's image-generation APIs.

        Dispatches to /ai/mystic or /ai/text-to-image/<model> based on
        ``image_api``. Mystic accepts a rich parameter set (engine,
        resolution, structure reference, style model). Other APIs accept
        only the basics (prompt, aspect_ratio, optional seed/webhook).

        Args:
            prompt: Text description.
            style_reference_path: Optional style reference image (local path).
                Only honored by Mystic.
            style_adherence: 0-100. Mystic only.
            model: Mystic style (realism / fluid / zen / flexible /
                super_real / editorial_portraits). Mystic only.
            aspect_ratio: Internal aspect ratio slug.
            creative_detailing: 0-100. Mystic only.
            engine: Mystic engine. Mystic only.
            resolution: '1k' | '2k' | '4k'. Mystic only.
            structure_strength: 0-100. Mystic only.
            structure_reference_path: Mystic only.
            webhook_url: If set, Freepik posts status updates here.
            image_api: One of IMAGE_ENDPOINTS keys. Defaults to ``"mystic"``
                for backward compat with callers that don't know about the
                multi-API dispatch.
            seed: Optional seed for non-Mystic models.

        Returns:
            task_id for polling. Non-Mystic task_ids are namespaced
            ``"<image_api>:<raw_id>"`` so check_image_status can route the
            poll back to the correct endpoint.
        """
        self.image_limiter.wait()

        api = image_api if image_api in IMAGE_ENDPOINTS else "mystic"
        submit_path = IMAGE_ENDPOINTS[api]

        if api == "mystic":
            payload: dict = {
                "prompt": prompt,
                "model": model,
                "aspect_ratio": aspect_ratio,
                "creative_detailing": creative_detailing,
                "filter_nsfw": False,
            }
            if engine and engine in MYSTIC_ENGINES and engine != "automatic":
                payload["engine"] = engine
            if resolution and resolution in MYSTIC_RESOLUTIONS:
                payload["resolution"] = resolution
            if style_reference_path:
                payload["style_reference"] = image_to_base64(style_reference_path)
                payload["adherence"] = style_adherence
            if structure_reference_path:
                payload["structure_reference"] = image_to_base64(structure_reference_path)
                payload["structure_strength"] = max(0, min(100, structure_strength))
            if webhook_url:
                payload["webhook_url"] = webhook_url

            logger.info(
                f"[Freepik] POST /ai/mystic  model={model}  engine={engine}  "
                f"resolution={resolution}  aspect={aspect_ratio}"
            )
        else:
            # All non-Mystic image endpoints share a minimal schema.
            payload = {
                "prompt": prompt,
                "aspect_ratio": aspect_ratio,
            }
            if seed is not None:
                payload["seed"] = int(seed)
            if webhook_url:
                payload["webhook_url"] = webhook_url
            logger.info(f"[Freepik] POST {submit_path}  aspect={aspect_ratio}")

        resp = self._post(f"{BASE_URL}{submit_path}", payload)
        data = resp.get("data", resp)
        raw_id = data.get("task_id", data.get("id", ""))

        # Namespace non-Mystic task_ids so check_image_status can route back
        if api == "mystic":
            task_id = raw_id
        else:
            task_id = f"{api}:{raw_id}"
        logger.info(f"Image generation started: api={api} task={task_id}")
        return task_id

    def check_image_status(self, task_id: str) -> dict:
        """Check status of an image generation task.

        Mystic task_ids are unnamespaced (legacy). Non-Mystic task_ids are
        prefixed with ``"<image_api>:"`` (set in generate_image) so we know
        which endpoint to poll.
        """
        if ":" in task_id and task_id.split(":", 1)[0] in IMAGE_ENDPOINTS:
            api, raw_id = task_id.split(":", 1)
        else:
            api, raw_id = "mystic", task_id
        path = IMAGE_ENDPOINTS.get(api, IMAGE_ENDPOINTS["mystic"])

        resp = self._get(f"{BASE_URL}{path}/{raw_id}")
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

    # ── Video Generation (multi-model dispatch) ──────────────────────

    def generate_video(
        self,
        prompt: str,
        start_image_path: Optional[str] = None,
        start_image_url: Optional[str] = None,
        duration: int = 5,
        negative_prompt: str = "",
        cfg_scale: float = 0.5,
        model: str = "kling-v3-omni",
        webhook_url: Optional[str] = None,
    ) -> str:
        """
        Generate a video via one of the Freepik video models.

        The `model` argument selects the submit endpoint (see VIDEO_ENDPOINTS).
        The body shape is roughly uniform across models (prompt + image_url +
        duration + cfg_scale + optional negative_prompt); models that need
        extras can have them added later.

        Returns:
            task_id for polling (prefixed with 'model:' so check_video_status
            knows which endpoint to query).
        """
        self.video_limiter.wait()

        submit_path, _ = VIDEO_ENDPOINTS.get(
            model, VIDEO_ENDPOINTS["kling-v3-omni"]
        )
        if model not in VIDEO_ENDPOINTS:
            logger.warning(f"Unknown video model '{model}', falling back to kling-v3-omni")
            model = "kling-v3-omni"

        payload: dict = {
            "prompt": prompt,
            "duration": duration,
            "cfg_scale": cfg_scale,
        }

        if start_image_path:
            # Most Freepik video endpoints accept "image_url" with a data URI for local files.
            b64 = image_to_base64(start_image_path)
            ext = start_image_path.rsplit(".", 1)[-1].lower()
            mime = {"png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg"}.get(ext, "image/png")
            payload["image_url"] = f"data:{mime};base64,{b64}"
            logger.info(f"[Freepik video] start frame: {start_image_path}")
        elif start_image_url:
            payload["image_url"] = start_image_url
        else:
            logger.info("[Freepik video] no start image, text-to-video mode")

        if negative_prompt:
            payload["negative_prompt"] = negative_prompt

        if webhook_url:
            payload["webhook_url"] = webhook_url

        logger.info(f"[Freepik] POST {submit_path}  model={model}  dur={duration}  cfg={cfg_scale}")
        resp = self._post(f"{BASE_URL}{submit_path}", payload)
        data = resp.get("data", resp)
        raw_task_id = data.get("task_id", data.get("id", ""))
        # Namespace the task_id so we can route the status check back to
        # the right endpoint later without needing separate providers.
        task_id = f"{model}:{raw_task_id}"
        logger.info(f"Video generation started: {task_id}")
        return task_id

    def check_video_status(self, task_id: str) -> dict:
        """Check status of a video generation task.

        The task_id is 'model:raw_id' (namespace set by generate_video).
        Legacy unprefixed ids default to kling-v3-omni for backward compat.
        """
        if ":" in task_id:
            model, raw_id = task_id.split(":", 1)
        else:
            model, raw_id = "kling-v3-omni", task_id

        _, status_prefix = VIDEO_ENDPOINTS.get(
            model, VIDEO_ENDPOINTS["kling-v3-omni"]
        )
        resp = self._get(f"{BASE_URL}{status_prefix}/{raw_id}")
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
