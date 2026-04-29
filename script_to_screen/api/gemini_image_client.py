"""REST client for Google's Gemini and Imagen image generation APIs.

Both endpoint families use the same Google AI Studio API key
(``?key=<api_key>`` query param), so this client dispatches between
them based on the model id prefix:

  - ``gemini-*-image*``   → POST .../models/{model}:generateContent
  - ``imagen-*``          → POST .../models/{model}:predict

The endpoints are SYNCHRONOUS — they return the final image (base64
inlineData / bytesBase64Encoded) in the initial response. To fit
ScriptToScreen's async ``ImageProvider`` interface, results are cached
in memory keyed by a generated task_id (same pattern as the OpenAI and
Grok clients).
"""

from __future__ import annotations

import base64
import logging
import mimetypes
import os
import uuid
from typing import Optional

import requests

logger = logging.getLogger("ScriptToScreen")

BASE_URL = "https://generativelanguage.googleapis.com/v1beta"

# Default points at the cheapest, fastest, broadly-available variant.
# Users can pick any of SUPPORTED_MODELS via the wizard dropdown.
DEFAULT_MODEL = "gemini-2.5-flash-image"

# Models exposed in the wizard's Step 4 "Model (Gemini)" dropdown.
# Order = recommended-first for the UI.
SUPPORTED_MODELS = [
    "gemini-2.5-flash-image",            # "Nano Banana" — fast/cheap default
    "gemini-3.1-flash-image-preview",    # newer general-purpose flash
    "gemini-3-pro-image-preview",        # professional, higher-quality
    "imagen-4.0-generate-001",           # Imagen 4 standard
    "imagen-4.0-ultra-generate-001",     # Imagen 4 ultra (highest quality)
    "imagen-4.0-fast-generate-001",      # Imagen 4 fast
]

# ScriptToScreen aspect-ratio slugs → Google API ratio strings.
# Both Gemini's imageConfig and Imagen's parameters expect "W:H" form.
ASPECT_TO_RATIO = {
    "widescreen_16_9":  "16:9",
    "classic_4_3":      "4:3",
    "square_1_1":       "1:1",
    "traditional_3_4":  "3:4",
    "social_story_9_16": "9:16",
    # Pass-through for already-formatted ratios.
    "1:1": "1:1",
    "16:9": "16:9",
    "9:16": "9:16",
    "4:3": "4:3",
    "3:4": "3:4",
}


def _is_imagen(model: str) -> bool:
    return model.startswith("imagen-")


class GeminiImageClient:
    """Low-level HTTP wrapper for Google AI Studio image generation."""

    def __init__(self, api_key: str, model: str = DEFAULT_MODEL):
        self.api_key = api_key
        self.model = model
        self._session = requests.Session()
        # Auth via header (cleaner than ?key= in URL — keeps key out of logs).
        self._session.headers.update({
            "Content-Type": "application/json",
            "x-goog-api-key": api_key,
        })
        # Cache: cache_id → {"status", "images": [{"type":"b64","value":...,"format":"png"}], "error"}
        self._image_cache: dict[str, dict] = {}

    # ------------------------------------------------------------------
    # Connection test
    # ------------------------------------------------------------------

    def test_connection_details(self) -> tuple[bool, str]:
        """Verify credentials by listing available models."""
        try:
            r = self._session.get(f"{BASE_URL}/models", timeout=15)
            if r.status_code == 200:
                return True, f"Connected to Google AI Studio ({self.model})"
            elif r.status_code in (401, 403):
                return False, "Invalid Gemini API key or insufficient permissions"
            elif r.status_code == 429:
                return True, "Reachable (rate limited currently)"
            return False, f"HTTP {r.status_code}: {r.text[:120]}"
        except requests.RequestException as e:
            return False, f"Connection error: {e}"

    # ------------------------------------------------------------------
    # Image generation (synchronous; cached for ImageProvider polling)
    # ------------------------------------------------------------------

    def generate_image(
        self,
        prompt: str,
        *,
        aspect_ratio: str = "widescreen_16_9",
        model: Optional[str] = None,
        n: int = 1,
        output_format: str = "png",
        reference_images: Optional[list[str]] = None,
    ) -> str:
        """Generate an image synchronously. Returns a local cache_id the
        caller can poll via ``check_image_status()``.

        Args:
            prompt: Text description.
            aspect_ratio: ScriptToScreen slug (e.g. ``widescreen_16_9``).
            model: Model id (overrides the instance default).
            n: Number of images requested. Imagen honors this via
               ``sampleCount``; Gemini ignores it (always 1).
            output_format: Used only for the cached metadata; the actual
               wire format is whatever the API returns (typically PNG).
            reference_images: Optional list of local image paths to send
               as inline reference images. Gemini's image-gen models
               ("Nano Banana" et al.) use these for style + character
               consistency. Ignored by Imagen models (their ``:predict``
               endpoint doesn't accept image inputs).
        """
        chosen = model or self.model
        ratio = ASPECT_TO_RATIO.get(aspect_ratio, aspect_ratio)
        if ratio not in {"1:1", "16:9", "9:16", "4:3", "3:4"}:
            ratio = "16:9"

        if _is_imagen(chosen):
            if reference_images:
                logger.info(
                    f"[Imagen] {len(reference_images)} reference image(s) "
                    f"provided but Imagen's :predict endpoint doesn't "
                    f"accept image inputs — ignoring."
                )
            data = self._call_imagen(chosen, prompt, ratio, n)
            return self._cache_imagen_result(data, output_format)
        else:
            data = self._call_gemini(chosen, prompt, ratio, reference_images)
            return self._cache_gemini_result(data, output_format)

    # ------------------------------------------------------------------
    # Endpoint-specific dispatch
    # ------------------------------------------------------------------

    @staticmethod
    def _encode_image_part(path: str) -> Optional[dict]:
        """Read an image file and produce a Gemini ``inlineData`` part.

        Returns None if the file is missing or unreadable; we'd rather
        skip a stale reference than fail the whole shot.
        """
        try:
            if not path or not os.path.isfile(path):
                logger.warning(f"[Gemini] reference image not found: {path}")
                return None
            mime, _ = mimetypes.guess_type(path)
            if not mime or not mime.startswith("image/"):
                # Default to PNG; Google accepts the common image types.
                mime = "image/png"
            with open(path, "rb") as f:
                b64 = base64.b64encode(f.read()).decode("ascii")
            return {"inlineData": {"mimeType": mime, "data": b64}}
        except OSError as e:
            logger.warning(f"[Gemini] could not read reference image {path}: {e}")
            return None

    def _call_gemini(
        self,
        model: str,
        prompt: str,
        ratio: str,
        reference_images: Optional[list[str]] = None,
    ) -> dict:
        # Order: reference images FIRST, then text prompt. Google's docs
        # for image-edit / multi-reference flows put image parts before
        # the text instruction so the model conditions the generation on
        # them. Without this the request is text-only and the output
        # ignores any character/style references the user provided.
        parts: list[dict] = []
        ref_count = 0
        for ref_path in reference_images or []:
            part = self._encode_image_part(ref_path)
            if part is not None:
                parts.append(part)
                ref_count += 1
        parts.append({"text": prompt})

        body = {
            "contents": [{"parts": parts}],
            "generationConfig": {
                "responseModalities": ["IMAGE"],
                "imageConfig": {"aspectRatio": ratio},
            },
        }
        url = f"{BASE_URL}/models/{model}:generateContent"
        logger.info(
            f"[Gemini] POST {model}:generateContent  "
            f"ratio={ratio}  refs={ref_count}"
        )
        r = self._session.post(url, json=body, timeout=300)
        if r.status_code != 200:
            self._raise_with_message(r, model)
        return r.json()

    def _call_imagen(self, model: str, prompt: str, ratio: str, n: int) -> dict:
        body = {
            "instances": [{"prompt": prompt}],
            "parameters": {
                "sampleCount": max(1, min(int(n), 4)),
                "aspectRatio": ratio,
            },
        }
        url = f"{BASE_URL}/models/{model}:predict"
        logger.info(f"[Imagen] POST {model}:predict  ratio={ratio}  n={n}")
        r = self._session.post(url, json=body, timeout=300)
        if r.status_code != 200:
            self._raise_with_message(r, model)
        return r.json()

    @staticmethod
    def _raise_with_message(resp: requests.Response, model: str) -> None:
        """Surface the API's actual error.message instead of the bare HTTPError.

        Google's error envelope is ``{"error": {"code": N, "message": "...",
        "status": "..."}}``. Without this, the user just sees
        ``400 Client Error: Bad Request for url: ...`` which buries the
        actionable detail (quota exhausted, model not enabled, etc.).
        """
        err_msg = f"HTTP {resp.status_code}"
        try:
            payload = resp.json()
            err_obj = payload.get("error") if isinstance(payload, dict) else None
            if isinstance(err_obj, dict) and err_obj.get("message"):
                err_msg = err_obj["message"]
            elif isinstance(payload, dict) and payload.get("message"):
                err_msg = payload["message"]
        except Exception:
            err_msg = f"HTTP {resp.status_code}: {resp.text[:300]}"
        logger.error(f"[Gemini] {model} failed: {resp.status_code} — {err_msg}")
        raise RuntimeError(f"Gemini image API error ({model}): {err_msg}")

    # ------------------------------------------------------------------
    # Response parsing & caching
    # ------------------------------------------------------------------

    def _cache_gemini_result(self, data: dict, output_format: str) -> str:
        """Extract base64 image data from Gemini /generateContent response."""
        images: list = []
        for cand in data.get("candidates", []):
            content = cand.get("content") or {}
            for part in content.get("parts", []):
                inline = part.get("inlineData") or part.get("inline_data")
                if not inline:
                    continue
                b64 = inline.get("data") or inline.get("bytesBase64Encoded")
                mime = inline.get("mimeType") or inline.get("mime_type") or "image/png"
                if b64:
                    fmt = "jpeg" if "jpeg" in mime else ("webp" if "webp" in mime else "png")
                    images.append({"type": "b64", "value": b64, "format": fmt})

        if not images:
            err = "No image data in Gemini response"
            # Surface any text response (the model might have refused / returned a safety block)
            for cand in data.get("candidates", []):
                for part in (cand.get("content") or {}).get("parts", []):
                    if part.get("text"):
                        err = f"Gemini returned text instead of image: {part['text'][:200]}"
                        break
            return self._stash({"status": "FAILED", "images": [], "error": err})

        return self._stash({"status": "COMPLETED", "images": images, "error": None})

    def _cache_imagen_result(self, data: dict, output_format: str) -> str:
        """Extract base64 image data from Imagen /predict response."""
        images: list = []
        for pred in data.get("predictions", []):
            b64 = pred.get("bytesBase64Encoded") or pred.get("imageBytes")
            mime = pred.get("mimeType") or "image/png"
            if b64:
                fmt = "jpeg" if "jpeg" in mime else ("webp" if "webp" in mime else "png")
                images.append({"type": "b64", "value": b64, "format": fmt})

        if not images:
            return self._stash({
                "status": "FAILED", "images": [],
                "error": "No predictions in Imagen response",
            })
        return self._stash({"status": "COMPLETED", "images": images, "error": None})

    def _stash(self, result: dict) -> str:
        cache_id = uuid.uuid4().hex
        self._image_cache[cache_id] = result
        return cache_id

    # ------------------------------------------------------------------
    # ImageProvider polling shim
    # ------------------------------------------------------------------

    def check_image_status(self, task_id: str) -> dict:
        """Synchronous: result was cached at submission time, just return it."""
        return self._image_cache.get(task_id, {
            "status": "FAILED",
            "images": [],
            "error": f"Unknown task_id {task_id!r}",
        })

    def download_image(self, ref, save_path: str) -> str:
        """Decode the base64 inline image and write it to save_path.

        ``ref`` is one of the ``images`` entries we cached: a dict with
        ``type``, ``value``, ``format``. We honor the format in the
        saved filename (rewriting the extension if needed).
        """
        if isinstance(ref, dict) and ref.get("type") == "b64":
            data = base64.b64decode(ref["value"])
            fmt = ref.get("format", "png").lower()
            # Correct the extension if necessary so Resolve identifies it.
            base, _ = save_path.rsplit(".", 1) if "." in save_path else (save_path, "")
            corrected = f"{base}.{fmt}"
            with open(corrected, "wb") as f:
                f.write(data)
            return corrected
        # Fallback: caller passed a plain URL string (we don't normally
        # produce these for Gemini, but be tolerant).
        if isinstance(ref, str) and ref.startswith("http"):
            r = requests.get(ref, timeout=120)
            r.raise_for_status()
            with open(save_path, "wb") as f:
                f.write(r.content)
            return save_path
        raise ValueError(f"Unrecognized image ref: {type(ref).__name__}")
