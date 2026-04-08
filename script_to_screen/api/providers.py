"""Abstract base classes for generation providers."""

from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import Optional


@dataclass
class ProviderInfo:
    """Metadata about a provider for UI display and registry."""
    id: str               # "freepik", "comfyui_flux", "comfyui_ltx"
    name: str             # "Freepik (Cloud)", "Flux Kontext (ComfyUI)"
    category: str         # "image", "video", "voice", "lipsync"
    requires_api_key: bool
    requires_server_url: bool
    default_server_url: str = ""
    description: str = ""


class ImageProvider(ABC):
    """Interface for image generation backends."""

    @abstractmethod
    def test_connection(self) -> bool: ...

    @abstractmethod
    def test_connection_details(self) -> tuple[bool, str]: ...

    @abstractmethod
    def generate_image(
        self,
        prompt: str,
        style_reference_path: Optional[str] = None,
        style_adherence: int = 50,
        aspect_ratio: str = "widescreen_16_9",
        **kwargs,
    ) -> str:
        """Submit image generation. Returns task_id or equivalent."""
        ...

    @abstractmethod
    def check_image_status(self, task_id: str) -> dict:
        """Returns dict with 'status', 'images', 'error' keys.

        status: "PROCESSING", "COMPLETED", or "FAILED"
        images: list of image references (format is provider-specific)
        error: error message string or None
        """
        ...

    @abstractmethod
    def download_image(self, ref, save_path: str) -> str:
        """Download/copy result image to save_path. Returns save_path.

        ref: provider-specific reference (URL string for cloud, dict for ComfyUI)
        """
        ...

    def build_prompt(
        self,
        base_prompt: str,
        character_refs: dict[str, str],
    ) -> str:
        """Provider-specific prompt formatting. Default: pass through."""
        return base_prompt


class VideoProvider(ABC):
    """Interface for video generation backends."""

    @abstractmethod
    def test_connection(self) -> bool: ...

    @abstractmethod
    def test_connection_details(self) -> tuple[bool, str]: ...

    @abstractmethod
    def generate_video(
        self,
        prompt: str,
        start_image_path: Optional[str] = None,
        duration: int = 5,
        **kwargs,
    ) -> str:
        """Submit video generation. Returns task_id or equivalent."""
        ...

    @abstractmethod
    def check_video_status(self, task_id: str) -> dict:
        """Returns dict with 'status', 'videos', 'error' keys."""
        ...

    @abstractmethod
    def download_video(self, ref, save_path: str) -> str:
        """Download/copy result video to save_path. Returns save_path."""
        ...


class VoiceProvider(ABC):
    """Interface for voice cloning and TTS backends."""

    @abstractmethod
    def test_connection(self) -> bool: ...

    @abstractmethod
    def test_connection_details(self) -> tuple[bool, str]: ...

    @abstractmethod
    def clone_voice(
        self, name: str, audio_paths: list[str], **kwargs
    ) -> str:
        """Clone a voice from audio samples. Returns voice_id."""
        ...

    @abstractmethod
    def generate_speech(
        self,
        voice_id: str,
        text: str,
        save_path: str,
        **kwargs,
    ) -> str:
        """Generate speech audio. Returns save_path."""
        ...

    @abstractmethod
    def list_voices(self) -> list[dict]: ...


class LipsyncProvider(ABC):
    """Interface for lip-sync backends."""

    @abstractmethod
    def test_connection(self) -> bool: ...

    @abstractmethod
    def test_connection_details(self) -> tuple[bool, str]: ...

    @abstractmethod
    def generate_lipsync(
        self,
        video_url: str,
        audio_url: Optional[str] = None,
        **kwargs,
    ) -> str:
        """Submit lip-sync job. Returns task_id."""
        ...

    @abstractmethod
    def check_lipsync_status(self, task_id: str) -> dict:
        """Returns dict with 'status', 'videos', 'error' keys."""
        ...


class TextProvider(ABC):
    """Interface for text/chat LLM backends (used for shot expansion, etc.)."""

    @abstractmethod
    def test_connection(self) -> bool: ...

    @abstractmethod
    def test_connection_details(self) -> tuple[bool, str]: ...

    @abstractmethod
    def generate_text(
        self,
        system_prompt: str,
        user_prompt: str,
        max_tokens: int = 4096,
        temperature: float = 0.7,
        response_format: str = "text",  # "text" or "json"
        **kwargs,
    ) -> str:
        """Submit a chat completion. Returns the response text.

        If response_format is "json", the LLM is asked to return valid JSON
        and the returned string will be parseable by json.loads().
        """
        ...
