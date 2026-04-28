"""REST client for OpenAI's image generation API.

Targets `gpt-image-2` (released Apr 21, 2026) but supports any
`/v1/images/generations`-compatible model.

The endpoint is SYNCHRONOUS — it returns the final image (URL or base64)
in the initial response. To fit ScriptToScreen's async `ImageProvider`
interface, we cache the result in memory keyed by a generated task_id
(same pattern as `grok_client.py`).
"""

from __future__ import annotations

import base64
import logging
import os
import uuid
from typing import Optional

import requests

logger = logging.getLogger("ScriptToScreen")

BASE_URL = "https://api.openai.com/v1"
# Default to gpt-image-1: works for unverified OpenAI orgs. gpt-image-2
# requires organization verification (https://platform.openai.com/settings/organization/general)
# and returns 400 "Your organization must be verified..." otherwise.
DEFAULT_MODEL = "gpt-image-1"

# Models supported by /v1/images/generations as of Apr 2026. Used by the
# wizard's Step 4 model dropdown. Order = recommended-first for UI.
SUPPORTED_MODELS = [
    "gpt-image-1",         # default — no org verification required
    "gpt-image-1-mini",    # cheaper/faster variant
    "gpt-image-1.5",       # newer; may need verification
    "gpt-image-2",         # newest; REQUIRES org verification
    "dall-e-3",            # legacy
    "dall-e-2",            # legacy
]

# Map ScriptToScreen aspect-ratio slugs → OpenAI explicit size strings.
# Anything not in this map falls back to "auto" (model picks).
ASPECT_TO_SIZE = {
    "widescreen_16_9": "1536x1024",
    "classic_4_3": "1024x1024",   # no direct 4:3; square is closest safe bet
    "square_1_1": "1024x1024",
    "social_story_9_16": "1024x1536",
    "traditional_3_4": "1024x1536",
    # Pass-through if already in pixel form
    "1024x1024": "1024x1024",
    "1536x1024": "1536x1024",
    "1024x1536": "1024x1536",
    "auto": "auto",
}


class OpenAIImageClient:
    """Low-level HTTP wrapper for OpenAI's Images API."""

    def __init__(self, api_key: str, model: str = DEFAULT_MODEL):
        self.api_key = api_key
        self.model = model
        self._session = requests.Session()
        self._session.headers.update({
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        })
        # Cache: task_id (local uuid) → {"status": str, "images": [url|b64_data], "error": str|None}
        self._image_cache: dict[str, dict] = {}

    # ------------------------------------------------------------------
    # Connection test
    # ------------------------------------------------------------------

    def test_connection_details(self) -> tuple[bool, str]:
        """Verify credentials by listing models."""
        try:
            r = self._session.get(f"{BASE_URL}/models", timeout=15)
            if r.status_code == 200:
                return True, f"Connected to OpenAI Images API ({self.model})"
            elif r.status_code == 401:
                return False, "Invalid OpenAI API key"
            elif r.status_code == 429:
                return True, "Reachable (rate limited currently)"
            return False, f"HTTP {r.status_code}: {r.text[:120]}"
        except requests.RequestException as e:
            return False, f"Connection error: {e}"

    # ------------------------------------------------------------------
    # Image generation (synchronous)
    # ------------------------------------------------------------------

    def generate_image(
        self,
        prompt: str,
        *,
        aspect_ratio: str = "widescreen_16_9",
        size: Optional[str] = None,
        quality: str = "auto",
        output_format: str = "png",
        background: str = "auto",
        n: int = 1,
        model: Optional[str] = None,
    ) -> str:
        """Generate an image synchronously. Returns a local cache_id the
        caller can poll via `check_image_status()`.

        Args:
            prompt: Text description.
            aspect_ratio: ScriptToScreen slug (e.g. 'widescreen_16_9').
                Ignored if an explicit `size` is provided.
            size: Explicit size override (e.g. '1536x1024' or 'auto').
            quality: 'low' | 'medium' | 'high' | 'auto'.
            output_format: 'png' | 'jpeg' | 'webp'.
            background: 'transparent' | 'opaque' | 'auto'.
            n: Number of images (we only use the first).
            model: Override the default model for this call.
        """
        # Resolve size: explicit > aspect-ratio mapping > auto
        if size and size in ASPECT_TO_SIZE.values():
            final_size = size
        elif size == "auto":
            final_size = "auto"
        else:
            final_size = ASPECT_TO_SIZE.get(aspect_ratio, "auto")

        body: dict = {
            "model": model or self.model,
            "prompt": prompt,
            "n": max(1, int(n)),
            "size": final_size,
            "quality": quality if quality in ("low", "medium", "high", "auto") else "auto",
            "output_format": output_format if output_format in ("png", "jpeg", "webp") else "png",
            "background": background if background in ("transparent", "opaque", "auto") else "auto",
        }

        logger.info(
            f"[OpenAI] POST images/generations  model={body['model']} "
            f"size={body['size']}  quality={body['quality']}  fmt={body['output_format']}"
        )

        # Images generation can take 30-120s for high quality — generous timeout.
        r = self._session.post(
            f"{BASE_URL}/images/generations",
            json=body,
            timeout=300,
        )

        if r.status_code != 200:
            # Try to surface OpenAI's actual error.message instead of the
            # bare HTTPError, so the user sees e.g.
            #   "Your organization must be verified to use the model
            #    gpt-image-2. Please go to: ..."
            # rather than just "400 Client Error: Bad Request for url: ...".
            err_msg = f"HTTP {r.status_code}"
            try:
                err_json = r.json()
                err_obj = err_json.get("error") if isinstance(err_json, dict) else None
                if isinstance(err_obj, dict) and err_obj.get("message"):
                    err_msg = err_obj["message"]
                elif isinstance(err_json, dict) and err_json.get("message"):
                    err_msg = err_json["message"]
            except Exception:
                err_msg = f"HTTP {r.status_code}: {r.text[:300]}"
            logger.error(f"[OpenAI] images/generations failed: {r.status_code} — {err_msg}")
            raise RuntimeError(f"OpenAI image API error: {err_msg}")

        data = r.json()
        return self._cache_result(data, body["output_format"])

    def _cache_result(self, data: dict, output_format: str) -> str:
        """Extract images from response, cache, return cache_id."""
        # Response shape: {"data": [{"url": "..."} | {"b64_json": "..."}]}
        images: list = []
        for item in data.get("data", []):
            if "url" in item and item["url"]:
                images.append({"type": "url", "value": item["url"], "format": output_format})
            elif "b64_json" in item and item["b64_json"]:
                images.append({"type": "b64", "value": item["b64_json"], "format": output_format})

        cache_id = str(uuid.uuid4())
        if not images:
            self._image_cache[cache_id] = {
                "status": "FAILED",
                "images": [],
                "error": "No image data in response",
            }
            logger.error(f"[OpenAI] No image data returned: {data}")
        else:
            self._image_cache[cache_id] = {
                "status": "COMPLETED",
                "images": images,
                "error": None,
            }
            logger.info(f"[OpenAI] Result: {len(images)} image(s) → cache_id={cache_id}")
        return cache_id

    def check_image_status(self, cache_id: str) -> dict:
        """Look up a cached synchronous result."""
        cached = self._image_cache.get(cache_id)
        if cached:
            return cached
        return {"status": "FAILED", "images": [], "error": "Unknown cache ID"}

    def download_image(self, image_ref, save_path: str) -> str:
        """Save the cached image (from URL or base64) to disk.

        The `image_ref` is whatever was cached in `images[0]` by
        `_cache_result`. For compatibility with `provider.download_image()`
        callers that may pass a raw string, we handle that too.
        """
        # Normalize to our dict format
        if isinstance(image_ref, str):
            # Assume URL
            ref = {"type": "url", "value": image_ref, "format": "png"}
        elif isinstance(image_ref, dict):
            ref = image_ref
        else:
            raise ValueError(f"Unsupported image_ref type: {type(image_ref)}")

        fmt = ref.get("format", "png").lower()
        ext = ".png" if fmt == "png" else (".jpg" if fmt == "jpeg" else f".{fmt}")

        # Fix extension to match output_format
        base, old_ext = os.path.splitext(save_path)
        if old_ext.lower() != ext:
            save_path = base + ext

        if ref["type"] == "url":
            r = requests.get(ref["value"], timeout=180)
            r.raise_for_status()
            with open(save_path, "wb") as f:
                f.write(r.content)
        elif ref["type"] == "b64":
            data = base64.b64decode(ref["value"])
            with open(save_path, "wb") as f:
                f.write(data)
        else:
            raise ValueError(f"Unsupported cached image ref type: {ref['type']}")

        logger.info(f"[OpenAI] Image saved: {save_path}")
        return save_path
