"""ComfyUI-based providers for Flux Kontext (image) and LTX (video)."""

import logging
from typing import Optional

import requests

from .providers import ImageProvider, VideoProvider
from .comfyui_client import ComfyUIClient
from . import comfyui_workflows as workflows

logger = logging.getLogger("ScriptToScreen")


# ── Aspect ratio to pixel dimensions ────────────────────────────

ASPECT_DIMS = {
    "widescreen_16_9": (1024, 576),
    "classic_4_3": (1024, 768),
    "square_1_1": (1024, 1024),
    "traditional_3_4": (768, 1024),
    "social_story_9_16": (576, 1024),
}


class ComfyUIFluxImageProvider(ImageProvider):
    """Flux Kontext image generation via local ComfyUI."""

    def __init__(self, server_url: str = "http://127.0.0.1:8188"):
        self._client = ComfyUIClient(server_url)

    def test_connection(self) -> bool:
        return self._client.test_connection()

    def test_connection_details(self) -> tuple[bool, str]:
        return self._client.test_connection_details()

    def generate_image(
        self,
        prompt,
        style_reference_path=None,
        style_adherence=50,
        aspect_ratio="widescreen_16_9",
        **kwargs,
    ) -> str:
        w, h = ASPECT_DIMS.get(aspect_ratio, (1024, 576))
        steps = kwargs.get("flux_steps", 28)

        if style_reference_path:
            # Upload reference image and use img_ref workflow
            upload = self._client.upload_image(style_reference_path)
            wf = workflows.flux_kontext_img_ref(
                prompt=prompt,
                input_image_name=upload["name"],
                width=w,
                height=h,
                steps=steps,
                denoise=style_adherence / 100.0,
            )
        else:
            wf = workflows.flux_kontext_txt2img(
                prompt=prompt,
                width=w,
                height=h,
                steps=steps,
            )

        prompt_id = self._client.queue_prompt(wf)
        return prompt_id

    def check_image_status(self, task_id: str) -> dict:
        history = self._client.get_history(task_id)
        if not history:
            return {"status": "PROCESSING", "images": [], "error": None}

        status_info = history.get("status", {})
        if status_info.get("completed"):
            outputs = history.get("outputs", {})
            images = []
            for node_id, out in outputs.items():
                for img in out.get("images", []):
                    images.append({
                        "filename": img["filename"],
                        "subfolder": img.get("subfolder", ""),
                    })
            return {"status": "COMPLETED", "images": images, "error": None}

        status_str = status_info.get("status_str", "")
        if status_str == "error":
            msgs = status_info.get("messages", [])
            return {"status": "FAILED", "images": [], "error": str(msgs)}

        return {"status": "PROCESSING", "images": [], "error": None}

    def download_image(self, ref, save_path: str) -> str:
        if isinstance(ref, dict):
            return self._client.download_output(
                ref["filename"],
                ref.get("subfolder", ""),
                save_path,
            )
        # Fallback: treat as URL
        resp = requests.get(ref, timeout=60)
        resp.raise_for_status()
        with open(save_path, "wb") as f:
            f.write(resp.content)
        return save_path

    def build_prompt(self, base_prompt, character_refs):
        # Flux Kontext uses plain text prompts — no special syntax
        return base_prompt


class ComfyUILTXVideoProvider(VideoProvider):
    """LTX 2.3 video generation via local ComfyUI."""

    def __init__(self, server_url: str = "http://127.0.0.1:8188"):
        self._client = ComfyUIClient(server_url)

    def test_connection(self) -> bool:
        return self._client.test_connection()

    def test_connection_details(self) -> tuple[bool, str]:
        return self._client.test_connection_details()

    def generate_video(
        self,
        prompt,
        start_image_path=None,
        duration=5,
        **kwargs,
    ) -> str:
        fps = kwargs.get("fps", 24)
        num_frames = duration * fps + 1
        steps = kwargs.get("ltx_steps", 30)

        if start_image_path:
            upload = self._client.upload_image(start_image_path)
            wf = workflows.ltx_video_img2vid(
                prompt=prompt,
                input_image_name=upload["name"],
                num_frames=num_frames,
                steps=steps,
            )
        else:
            wf = workflows.ltx_video_txt2vid(
                prompt=prompt,
                num_frames=num_frames,
                steps=steps,
            )

        return self._client.queue_prompt(wf)

    def check_video_status(self, task_id: str) -> dict:
        history = self._client.get_history(task_id)
        if not history:
            return {"status": "PROCESSING", "videos": [], "error": None}

        status_info = history.get("status", {})
        if status_info.get("completed"):
            outputs = history.get("outputs", {})
            videos = []
            for node_id, out in outputs.items():
                # ComfyUI video outputs may be under 'gifs', 'videos', or 'images'
                for key in ("gifs", "videos", "images"):
                    for item in out.get(key, []):
                        videos.append({
                            "filename": item["filename"],
                            "subfolder": item.get("subfolder", ""),
                        })
            return {"status": "COMPLETED", "videos": videos, "error": None}

        status_str = status_info.get("status_str", "")
        if status_str == "error":
            msgs = status_info.get("messages", [])
            return {"status": "FAILED", "videos": [], "error": str(msgs)}

        return {"status": "PROCESSING", "videos": [], "error": None}

    def download_video(self, ref, save_path: str) -> str:
        if isinstance(ref, dict):
            return self._client.download_output(
                ref["filename"],
                ref.get("subfolder", ""),
                save_path,
            )
        resp = requests.get(ref, timeout=120, stream=True)
        resp.raise_for_status()
        with open(save_path, "wb") as f:
            for chunk in resp.iter_content(8192):
                f.write(chunk)
        return save_path
