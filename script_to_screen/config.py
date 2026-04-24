"""Configuration management for ScriptToScreen."""

import json
import os
from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import Optional, Any


CONFIG_DIR = Path.home() / ".config" / "script_to_screen"
CONFIG_FILE = CONFIG_DIR / "config.json"


@dataclass
class ProviderConfig:
    """Settings for a single provider instance."""
    provider_id: str = ""
    api_key: str = ""
    server_url: str = ""
    extra: dict = field(default_factory=dict)


@dataclass
class APIConfig:
    # Legacy fields (kept for backward compat with existing config files)
    freepik_api_key: str = ""
    elevenlabs_api_key: str = ""

    # Provider selection per category
    image_provider: ProviderConfig = field(
        default_factory=lambda: ProviderConfig(provider_id="freepik")
    )
    video_provider: ProviderConfig = field(
        default_factory=lambda: ProviderConfig(provider_id="freepik")
    )
    voice_provider: ProviderConfig = field(
        default_factory=lambda: ProviderConfig(provider_id="elevenlabs")
    )

    def migrate_legacy(self):
        """One-time migration: copy old flat keys into provider configs."""
        if self.freepik_api_key and not self.image_provider.api_key:
            self.image_provider.api_key = self.freepik_api_key
        if self.freepik_api_key and not self.video_provider.api_key:
            self.video_provider.api_key = self.freepik_api_key
        if self.elevenlabs_api_key and not self.voice_provider.api_key:
            self.voice_provider.api_key = self.elevenlabs_api_key


@dataclass
class GenerationDefaults:
    freepik_model: str = "realism"  # realism, fluid, zen, flexible, super_real, editorial_portraits
    aspect_ratio: str = "widescreen_16_9"
    creative_detailing: int = 33
    # Freepik Mystic per-model options
    freepik_engine: str = "automatic"              # automatic | magnific_sparkle | magnific_illusio | magnific_sharpy
    freepik_resolution: str = "2k"                 # 1k | 2k | 4k
    freepik_structure_strength: int = 50           # 0-100 (only when structure reference is set)
    # OpenAI gpt-image-2 per-model options
    openai_quality: str = "auto"                   # low | medium | high | auto
    openai_size: str = "auto"                      # 1024x1024 | 1536x1024 | 1024x1536 | auto
    openai_output_format: str = "png"              # png | jpeg | webp
    openai_background: str = "auto"                # transparent | opaque | auto
    # Video generation
    video_model: str = "kling-v3-omni"             # see VIDEO_ENDPOINTS in freepik_client
    video_cfg_scale: float = 0.5                   # 0.0-1.0
    video_negative_prompt: str = ""
    video_duration_dialogue: int = 5
    video_duration_action: int = 3
    video_duration_establishing: int = 8
    voice_stability: float = 0.5
    voice_similarity_boost: float = 0.75
    voice_model: str = "eleven_multilingual_v2"
    # ComfyUI-specific defaults
    comfyui_server_url: str = "http://127.0.0.1:8188"
    flux_steps: int = 28
    ltx_steps: int = 30


@dataclass
class AppConfig:
    api: APIConfig = field(default_factory=APIConfig)
    defaults: GenerationDefaults = field(default_factory=GenerationDefaults)
    last_script_dir: str = ""
    last_output_dir: str = ""
    saved_voice_ids: dict[str, str] = field(default_factory=dict)  # character_name -> voice_id

    def save(self):
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        data = asdict(self)
        with open(CONFIG_FILE, "w") as f:
            json.dump(data, f, indent=2)

    @classmethod
    def load(cls) -> "AppConfig":
        if not CONFIG_FILE.exists():
            return cls()
        try:
            with open(CONFIG_FILE, "r") as f:
                data = json.load(f)
            config = cls()

            if "api" in data:
                api_data = data["api"]
                # Handle legacy format (flat keys only)
                config.api.freepik_api_key = api_data.get("freepik_api_key", "")
                config.api.elevenlabs_api_key = api_data.get("elevenlabs_api_key", "")
                # Load provider configs if present
                if "image_provider" in api_data and isinstance(api_data["image_provider"], dict):
                    config.api.image_provider = ProviderConfig(**api_data["image_provider"])
                if "video_provider" in api_data and isinstance(api_data["video_provider"], dict):
                    config.api.video_provider = ProviderConfig(**api_data["video_provider"])
                if "voice_provider" in api_data and isinstance(api_data["voice_provider"], dict):
                    config.api.voice_provider = ProviderConfig(**api_data["voice_provider"])
                # Auto-migrate legacy keys into provider configs
                config.api.migrate_legacy()

            if "defaults" in data:
                defaults_data = data["defaults"]
                # Only apply known fields to handle old configs missing new fields
                for field_name in GenerationDefaults.__dataclass_fields__:
                    if field_name in defaults_data:
                        setattr(config.defaults, field_name, defaults_data[field_name])

            config.last_script_dir = data.get("last_script_dir", "")
            config.last_output_dir = data.get("last_output_dir", "")
            config.saved_voice_ids = data.get("saved_voice_ids", {})
            return config
        except (json.JSONDecodeError, TypeError, KeyError):
            return cls()


def get_output_dir(project_name: str = "default") -> Path:
    output = CONFIG_DIR / "projects" / project_name
    output.mkdir(parents=True, exist_ok=True)
    return output


def get_temp_dir() -> Path:
    tmp = CONFIG_DIR / "tmp"
    tmp.mkdir(parents=True, exist_ok=True)
    return tmp
