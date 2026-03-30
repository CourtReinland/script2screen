"""REST client for the xAI Grok Imagine API (images + video)."""

import base64
import logging
import mimetypes
import os
import time
import uuid
from typing import Optional

import requests

logger = logging.getLogger("ScriptToScreen")

BASE_URL = "https://api.x.ai/v1"

# Map internal aspect-ratio names → Grok API values
ASPECT_MAP = {
    "widescreen_16_9": "16:9",
    "classic_4_3": "4:3",
    "square_1_1": "1:1",
    "traditional_3_4": "3:4",
    "social_story_9_16": "9:16",
    # Pass through if already in Grok format
    "16:9": "16:9",
    "4:3": "4:3",
    "1:1": "1:1",
    "3:4": "3:4",
    "9:16": "9:16",
    "3:2": "3:2",
    "2:3": "2:3",
}


class GrokClient:
    """Low-level HTTP wrapper for the xAI API."""

    def __init__(self, api_key: str):
        self.api_key = api_key
        self._session = requests.Session()
        self._session.headers.update({
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        })
        # In-memory cache for synchronous image results so the
        # poll-based pipeline can retrieve them.
        self._image_cache: dict[str, dict] = {}

    # ------------------------------------------------------------------
    # Connection test
    # ------------------------------------------------------------------

    def test_connection_details(self) -> tuple[bool, str]:
        """Verify the API key works by listing models."""
        try:
            r = self._session.get(f"{BASE_URL}/models", timeout=10)
            if r.status_code == 200:
                return True, "Connected to xAI API"
            elif r.status_code == 401:
                return False, "Invalid API key"
            else:
                return False, f"HTTP {r.status_code}: {r.text[:120]}"
        except requests.RequestException as e:
            return False, f"Connection error: {e}"

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------

    @staticmethod
    def _file_to_data_uri(file_path: str) -> str:
        """Convert a local image file to a base64 data URI."""
        mime, _ = mimetypes.guess_type(file_path)
        if not mime:
            mime = "image/png"
        with open(file_path, "rb") as f:
            b64 = base64.b64encode(f.read()).decode("ascii")
        return f"data:{mime};base64,{b64}"

    # ------------------------------------------------------------------
    # Image generation (synchronous — returns URL immediately)
    # ------------------------------------------------------------------

    def generate_image(
        self,
        prompt: str,
        model: str = "grok-imagine-image",
        n: int = 1,
        aspect_ratio: str = "16:9",
        resolution: str = "1k",
        reference_images: Optional[list[str]] = None,
    ) -> str:
        """Generate or edit image(s). Returns a local cache ID.

        Args:
            prompt: Text description of the desired image.
            model: Grok model name.
            n: Number of images to generate.
            aspect_ratio: Output aspect ratio.
            resolution: Output resolution (1k or 2k).
            reference_images: Optional list of local file paths or URLs
                to use as reference/style inputs. Up to 3 images.
                When provided, the /images/edits endpoint is used instead
                of /images/generations.
        """
        grok_aspect = ASPECT_MAP.get(aspect_ratio, "16:9")

        # If reference images provided, use the edits endpoint
        if reference_images:
            return self._generate_with_references(
                prompt, model, grok_aspect, resolution, reference_images
            )

        body = {
            "model": model,
            "prompt": prompt,
            "n": n,
            "aspect_ratio": grok_aspect,
            "resolution": resolution,
            "response_format": "url",
        }

        logger.info(f"[Grok] POST images/generations  model={model}  aspect={grok_aspect}")
        r = self._session.post(
            f"{BASE_URL}/images/generations",
            json=body,
            timeout=120,
        )
        if r.status_code != 200:
            logger.error(f"[Grok] images/generations failed: {r.status_code} {r.text[:300]}")
        r.raise_for_status()
        data = r.json()

        return self._cache_image_result(data)

    def _generate_with_references(
        self,
        prompt: str,
        model: str,
        aspect_ratio: str,
        resolution: str,
        reference_images: list[str],
    ) -> str:
        """Use the /images/edits endpoint to generate with reference images."""
        # Convert local paths to base64 data URIs; keep URLs as-is
        image_entries = []
        for img_path in reference_images[:3]:  # Max 3 images
            if img_path.startswith("http://") or img_path.startswith("https://"):
                url = img_path
            elif os.path.isfile(img_path):
                url = self._file_to_data_uri(img_path)
                logger.info(f"[Grok] Encoded reference image: {os.path.basename(img_path)}")
            else:
                logger.warning(f"[Grok] Skipping missing reference: {img_path}")
                continue
            image_entries.append({"url": url, "type": "image_url"})

        if not image_entries:
            logger.warning("[Grok] No valid reference images; falling back to generation")
            return self.generate_image(prompt, model, aspect_ratio=aspect_ratio, resolution=resolution)

        body = {
            "model": model,
            "prompt": prompt,
            "aspect_ratio": aspect_ratio,
            "response_format": "url",
        }

        # Single vs multi-image
        if len(image_entries) == 1:
            body["image"] = image_entries[0]
        else:
            body["images"] = image_entries

        ref_count = len(image_entries)
        logger.info(f"[Grok] POST images/edits  model={model}  refs={ref_count}  aspect={aspect_ratio}")

        # Retry up to 3 times — the xAI edits endpoint can return transient
        # 400 "invalid base64" errors even with valid data.
        last_err = None
        for attempt in range(3):
            r = self._session.post(
                f"{BASE_URL}/images/edits",
                json=body,
                timeout=180,
            )
            if r.status_code == 200:
                return self._cache_image_result(r.json())

            last_err = f"{r.status_code} {r.text[:200]}"
            logger.warning(f"[Grok] images/edits attempt {attempt+1} failed: {last_err}")
            if r.status_code == 400:
                time.sleep(2)  # brief pause before retry
                continue
            # Non-400 errors (auth, rate limit) — don't retry
            r.raise_for_status()

        # All retries failed — fall back to plain generation without references
        logger.warning(f"[Grok] images/edits failed after 3 attempts, falling back to generations endpoint")
        return self._generate_plain(prompt, model, aspect_ratio, resolution)

    def _generate_plain(self, prompt: str, model: str, aspect_ratio: str, resolution: str) -> str:
        """Plain generation without reference images (fallback)."""
        body = {
            "model": model,
            "prompt": prompt,
            "n": 1,
            "aspect_ratio": aspect_ratio,
            "resolution": resolution,
            "response_format": "url",
        }
        logger.info(f"[Grok] POST images/generations (fallback)  model={model}")
        r = self._session.post(f"{BASE_URL}/images/generations", json=body, timeout=120)
        if r.status_code != 200:
            logger.error(f"[Grok] images/generations fallback failed: {r.status_code} {r.text[:300]}")
        r.raise_for_status()
        return self._cache_image_result(r.json())

    def _cache_image_result(self, data: dict) -> str:
        """Extract image URLs from response and cache the result."""
        images = []
        for item in data.get("data", []):
            url = item.get("url")
            if url:
                images.append(url)

        cache_id = str(uuid.uuid4())
        self._image_cache[cache_id] = {
            "status": "COMPLETED",
            "images": images,
        }
        logger.info(f"[Grok] Result: {len(images)} image(s) → cache_id={cache_id}")
        return cache_id

    def check_image_status(self, cache_id: str) -> dict:
        """Look up a cached synchronous result."""
        cached = self._image_cache.get(cache_id)
        if cached:
            return cached
        return {"status": "FAILED", "images": [], "error": "Unknown cache ID"}

    def download_image(self, url: str, save_path: str) -> str:
        """Download an image from a temporary URL.

        Grok API returns JPEG images regardless of the requested format.
        We detect the actual format from the response bytes and fix the
        file extension so DaVinci Resolve can decode them correctly.
        """
        r = requests.get(url, timeout=120)
        r.raise_for_status()
        data = r.content

        # Detect actual format and fix extension
        actual_ext = ".png"
        if data[:3] == b"\xff\xd8\xff":
            actual_ext = ".jpg"
        elif data[:4] == b"RIFF":
            actual_ext = ".webp"

        # Replace extension if it doesn't match
        base, ext = os.path.splitext(save_path)
        if ext.lower() != actual_ext:
            save_path = base + actual_ext
            logger.info(f"[Grok] Format is {actual_ext}, corrected extension")

        with open(save_path, "wb") as f:
            f.write(data)
        logger.info(f"[Grok] Image saved: {save_path}")
        return save_path

    # ------------------------------------------------------------------
    # Video generation (asynchronous — submit + poll)
    # ------------------------------------------------------------------

    def generate_video(
        self,
        prompt: str,
        model: str = "grok-imagine-video",
        duration: int = 5,
        aspect_ratio: str = "16:9",
        resolution: str = "720p",
        image_url: Optional[str] = None,
    ) -> str:
        """Submit a video generation request. Returns request_id for polling."""
        grok_aspect = ASPECT_MAP.get(aspect_ratio, "16:9")

        body = {
            "model": model,
            "prompt": prompt,
            "duration": min(duration, 15),
            "aspect_ratio": grok_aspect,
            "resolution": resolution,
        }
        if image_url:
            # xAI API expects nested {"url": ...} object, not a flat string
            body["image"] = {"url": image_url}

        logger.info(f"[Grok] POST videos/generations  dur={duration}s  aspect={grok_aspect}")
        r = self._session.post(
            f"{BASE_URL}/videos/generations",
            json=body,
            timeout=30,
        )
        r.raise_for_status()
        data = r.json()
        request_id = data.get("request_id", "")
        logger.info(f"[Grok] Video queued → request_id={request_id}")
        return request_id

    def check_video_status(self, request_id: str) -> dict:
        """Poll video generation status."""
        r = self._session.get(
            f"{BASE_URL}/videos/{request_id}",
            timeout=30,
        )
        r.raise_for_status()
        data = r.json()

        status = data.get("status", "unknown")

        if status == "done":
            video_info = data.get("video", {})
            video_url = video_info.get("url", "")
            return {
                "status": "COMPLETED",
                "videos": [video_url] if video_url else [],
                "error": None,
            }
        elif status == "expired":
            return {
                "status": "FAILED",
                "videos": [],
                "error": "Video generation expired",
            }
        else:
            # "pending" or other in-progress states
            return {
                "status": "PROCESSING",
                "videos": [],
                "error": None,
            }

    def download_video(self, url: str, save_path: str) -> str:
        """Download a video from a temporary URL."""
        r = requests.get(url, timeout=300, stream=True)
        r.raise_for_status()
        with open(save_path, "wb") as f:
            for chunk in r.iter_content(8192):
                f.write(chunk)
        logger.info(f"[Grok] Video saved: {save_path}")
        return save_path
