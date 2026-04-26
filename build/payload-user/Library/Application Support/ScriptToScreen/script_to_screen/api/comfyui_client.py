"""ComfyUI REST API client — shared by Flux and LTX providers."""

import json
import logging
import time
import uuid
from pathlib import Path
from typing import Optional

import requests

logger = logging.getLogger("ScriptToScreen")


class ComfyUIClient:
    """Low-level ComfyUI server API client."""

    def __init__(self, server_url: str = "http://127.0.0.1:8188"):
        self.server_url = server_url.rstrip("/")
        self.client_id = str(uuid.uuid4())
        self.session = requests.Session()

    def test_connection(self) -> bool:
        ok, _ = self.test_connection_details()
        return ok

    def test_connection_details(self) -> tuple[bool, str]:
        """Test connection to ComfyUI server."""
        try:
            resp = self.session.get(
                f"{self.server_url}/system_stats", timeout=5
            )
            if resp.status_code == 200:
                data = resp.json()
                devices = data.get("devices", [])
                if devices:
                    dev = devices[0]
                    vram = dev.get("vram_total", 0)
                    name = dev.get("name", "unknown")
                    vram_gb = vram / (1024 ** 3) if vram else 0
                    return True, f"Connected — {name} ({vram_gb:.1f} GB)"
                return True, "Connected to ComfyUI"
            return False, f"HTTP {resp.status_code}"
        except requests.ConnectionError:
            return False, (
                "Cannot connect to ComfyUI. "
                "Start it with: python main.py --listen"
            )
        except Exception as e:
            return False, str(e)

    def queue_prompt(self, workflow: dict) -> str:
        """Submit a workflow for execution. Returns prompt_id."""
        payload = {
            "prompt": workflow,
            "client_id": self.client_id,
        }
        resp = self.session.post(
            f"{self.server_url}/prompt",
            json=payload,
            timeout=30,
        )
        resp.raise_for_status()
        data = resp.json()
        if "error" in data:
            raise RuntimeError(f"ComfyUI workflow error: {data['error']}")
        return data["prompt_id"]

    def get_history(self, prompt_id: str) -> Optional[dict]:
        """Get execution result for a prompt. Returns None if not found."""
        resp = self.session.get(
            f"{self.server_url}/history/{prompt_id}",
            timeout=10,
        )
        resp.raise_for_status()
        data = resp.json()
        return data.get(prompt_id)

    def poll_result(
        self,
        prompt_id: str,
        timeout: int = 600,
        interval: int = 3,
    ) -> dict:
        """Poll until a workflow completes. Returns history entry."""
        start = time.time()
        while time.time() - start < timeout:
            history = self.get_history(prompt_id)
            if history:
                status = history.get("status", {})
                if status.get("completed", False):
                    return history
                status_str = status.get("status_str", "")
                if status_str == "error":
                    msgs = status.get("messages", [])
                    raise RuntimeError(f"ComfyUI workflow failed: {msgs}")
            time.sleep(interval)
        raise TimeoutError(
            f"ComfyUI prompt {prompt_id} timed out after {timeout}s"
        )

    def download_output(
        self,
        filename: str,
        subfolder: str,
        save_path: str,
        folder_type: str = "output",
    ) -> str:
        """Download an output file from ComfyUI."""
        resp = self.session.get(
            f"{self.server_url}/view",
            params={
                "filename": filename,
                "subfolder": subfolder,
                "type": folder_type,
            },
            timeout=60,
        )
        resp.raise_for_status()
        with open(save_path, "wb") as f:
            f.write(resp.content)
        return save_path

    def upload_image(
        self,
        image_path: str,
        overwrite: bool = True,
    ) -> dict:
        """Upload an image to ComfyUI's input folder.

        Returns dict with 'name', 'subfolder', 'type' keys.
        """
        with open(image_path, "rb") as f:
            resp = self.session.post(
                f"{self.server_url}/upload/image",
                files={
                    "image": (Path(image_path).name, f, "image/png"),
                },
                data={
                    "overwrite": "true" if overwrite else "false",
                },
                timeout=30,
            )
        resp.raise_for_status()
        return resp.json()

    def get_available_models(self, folder: str = "diffusion_models") -> list[str]:
        """List available models in a ComfyUI model folder."""
        try:
            resp = self.session.get(
                f"{self.server_url}/models/{folder}",
                timeout=10,
            )
            resp.raise_for_status()
            return resp.json()
        except Exception:
            return []
