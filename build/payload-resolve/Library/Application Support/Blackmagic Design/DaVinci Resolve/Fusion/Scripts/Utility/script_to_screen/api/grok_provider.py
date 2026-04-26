"""Grok Imagine providers for image and video generation via xAI API."""

import logging
import os
from typing import Optional

from .providers import ImageProvider, VideoProvider
from .grok_client import GrokClient

logger = logging.getLogger("ScriptToScreen")


class GrokImageProvider(ImageProvider):
    """Image generation via xAI Grok Imagine API.

    When style reference or character reference images are provided,
    uses the /images/edits endpoint with base64-encoded images so that
    Grok can match the visual style and character appearances.
    """

    VALID_MODELS = ("grok-imagine-image", "grok-imagine-image-pro")

    def __init__(self, api_key: str = "", model: str = "grok-imagine-image", **kwargs):
        self._client = GrokClient(api_key)
        # Only accept valid Grok model names; ignore Freepik/other model names
        self._model = model if model in self.VALID_MODELS else "grok-imagine-image"
        # Temporary storage for character refs between build_prompt → generate_image
        self._pending_char_refs: dict[str, str] = {}

    def test_connection(self) -> bool:
        ok, _ = self._client.test_connection_details()
        return ok

    def test_connection_details(self) -> tuple[bool, str]:
        return self._client.test_connection_details()

    def build_prompt(self, base_prompt: str, character_refs: dict) -> str:
        """Enhance the prompt with character context and stash refs for generate_image.

        Args:
            base_prompt: The scene/shot description.
            character_refs: Dict of character_name -> reference_image_path.
        """
        # Store refs so generate_image() can pass them to the API
        self._pending_char_refs = {}
        for name, path in character_refs.items():
            if path and os.path.isfile(path):
                self._pending_char_refs[name] = path

        # Enhance prompt to tell Grok about the reference images
        if self._pending_char_refs:
            char_names = list(self._pending_char_refs.keys())
            if len(char_names) == 1:
                ref_hint = (
                    f"The character {char_names[0]} should match the appearance "
                    f"shown in the reference image provided."
                )
            else:
                names_str = ", ".join(char_names[:-1]) + f" and {char_names[-1]}"
                ref_hint = (
                    f"The characters {names_str} should match the appearances "
                    f"shown in the reference images provided."
                )
            return f"{base_prompt} {ref_hint}"

        return base_prompt

    def generate_image(
        self,
        prompt: str,
        style_reference_path: Optional[str] = None,
        style_adherence: int = 50,
        aspect_ratio: str = "widescreen_16_9",
        model: Optional[str] = None,
        **kwargs,
    ) -> str:
        """Generate an image, optionally with style/character reference images.

        Collects reference images from:
          1. style_reference_path (the style image from Step 3)
          2. character reference images (stashed by build_prompt)

        When any references are present, uses the /images/edits endpoint
        so Grok can visually match the style and character appearances.
        """
        use_model = model if model in self.VALID_MODELS else self._model

        # Collect reference images (max 3 for the edits endpoint)
        ref_images: list[str] = []

        # Style reference first (highest priority)
        if style_reference_path and os.path.isfile(style_reference_path):
            ref_images.append(style_reference_path)
            # Enhance prompt with style instruction if not already mentioned
            if "style" not in prompt.lower():
                prompt = (
                    f"Generate this scene in the visual style of the first reference image. "
                    f"{prompt}"
                )

        # Character references (up to remaining slots)
        for char_name, char_path in self._pending_char_refs.items():
            if len(ref_images) >= 3:
                break
            ref_images.append(char_path)

        # Clear pending refs
        self._pending_char_refs = {}

        # Try with reference images first; fall back to plain generation
        # if the edits endpoint fails for any reason (the xAI edits endpoint
        # intermittently rejects valid base64 payloads).
        if ref_images:
            try:
                return self._client.generate_image(
                    prompt=prompt,
                    model=use_model,
                    aspect_ratio=aspect_ratio,
                    resolution="1k",
                    reference_images=ref_images,
                )
            except Exception as e:
                logger.warning(
                    f"[Grok] Reference image generation failed ({e}), "
                    f"falling back to text-only generation"
                )

        # Plain generation (no references)
        return self._client.generate_image(
            prompt=prompt,
            model=use_model,
            aspect_ratio=aspect_ratio,
            resolution="1k",
            reference_images=None,
        )

    def check_image_status(self, task_id: str) -> dict:
        """Images are synchronous, so this returns the cached result."""
        return self._client.check_image_status(task_id)

    def download_image(self, ref, save_path: str) -> str:
        """Download from the temporary URL."""
        url = ref if isinstance(ref, str) else ref.get("url", ref)
        return self._client.download_image(url, save_path)


class GrokVideoProvider(VideoProvider):
    """Video generation via xAI Grok Imagine Video API."""

    def __init__(self, api_key: str = "", **kwargs):
        self._client = GrokClient(api_key)

    def test_connection(self) -> bool:
        ok, _ = self._client.test_connection_details()
        return ok

    def test_connection_details(self) -> tuple[bool, str]:
        return self._client.test_connection_details()

    def generate_video(
        self,
        prompt: str,
        start_image_path: Optional[str] = None,
        duration: int = 5,
        **kwargs,
    ) -> str:
        """Submit a video generation request. Returns request_id for polling.

        If a start_image_path is a local file, converts it to a base64
        data URI so Grok can use it as the first frame.
        """
        aspect = kwargs.get("aspect_ratio", "16:9")

        image_url = None
        if start_image_path:
            if start_image_path.startswith("http"):
                image_url = start_image_path
            elif os.path.isfile(start_image_path):
                # Convert local image to base64 data URI
                image_url = GrokClient._file_to_data_uri(start_image_path)
                logger.info(f"[Grok Video] Encoded start image: {os.path.basename(start_image_path)}")

        return self._client.generate_video(
            prompt=prompt,
            duration=duration,
            aspect_ratio=aspect,
            image_url=image_url,
        )

    def check_video_status(self, task_id: str) -> dict:
        return self._client.check_video_status(task_id)

    def download_video(self, ref, save_path: str) -> str:
        url = ref if isinstance(ref, str) else ref.get("url", ref)
        return self._client.download_video(url, save_path)
