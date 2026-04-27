"""Provider registry — maps IDs to factory functions."""

import logging
from typing import Callable, Any

from .providers import (
    ImageProvider, VideoProvider, VoiceProvider, LipsyncProvider, TextProvider, ProviderInfo
)

logger = logging.getLogger("ScriptToScreen")

# Registry: category -> {id -> (ProviderInfo, factory_fn)}
_IMAGE_PROVIDERS: dict[str, tuple[ProviderInfo, Callable[..., ImageProvider]]] = {}
_VIDEO_PROVIDERS: dict[str, tuple[ProviderInfo, Callable[..., VideoProvider]]] = {}
_VOICE_PROVIDERS: dict[str, tuple[ProviderInfo, Callable[..., VoiceProvider]]] = {}
_LIPSYNC_PROVIDERS: dict[str, tuple[ProviderInfo, Callable[..., LipsyncProvider]]] = {}
_TEXT_PROVIDERS: dict[str, tuple[ProviderInfo, Callable[..., TextProvider]]] = {}


# ── Registration functions ───────────────────────────────────────

def register_image_provider(info: ProviderInfo, factory: Callable[..., ImageProvider]):
    _IMAGE_PROVIDERS[info.id] = (info, factory)

def register_video_provider(info: ProviderInfo, factory: Callable[..., VideoProvider]):
    _VIDEO_PROVIDERS[info.id] = (info, factory)

def register_voice_provider(info: ProviderInfo, factory: Callable[..., VoiceProvider]):
    _VOICE_PROVIDERS[info.id] = (info, factory)

def register_lipsync_provider(info: ProviderInfo, factory: Callable[..., LipsyncProvider]):
    _LIPSYNC_PROVIDERS[info.id] = (info, factory)

def register_text_provider(info: ProviderInfo, factory: Callable[..., TextProvider]):
    _TEXT_PROVIDERS[info.id] = (info, factory)


# ── Query functions ──────────────────────────────────────────────

def get_image_providers() -> list[ProviderInfo]:
    return [info for info, _ in _IMAGE_PROVIDERS.values()]

def get_video_providers() -> list[ProviderInfo]:
    return [info for info, _ in _VIDEO_PROVIDERS.values()]

def get_voice_providers() -> list[ProviderInfo]:
    return [info for info, _ in _VOICE_PROVIDERS.values()]

def get_lipsync_providers() -> list[ProviderInfo]:
    return [info for info, _ in _LIPSYNC_PROVIDERS.values()]

def get_text_providers() -> list[ProviderInfo]:
    return [info for info, _ in _TEXT_PROVIDERS.values()]


# ── Factory functions ────────────────────────────────────────────

def create_image_provider(provider_id: str, **kwargs) -> ImageProvider:
    if provider_id not in _IMAGE_PROVIDERS:
        raise ValueError(
            f"Unknown image provider '{provider_id}'. "
            f"Available: {list(_IMAGE_PROVIDERS.keys())}"
        )
    info, factory = _IMAGE_PROVIDERS[provider_id]
    return factory(**kwargs)

def create_video_provider(provider_id: str, **kwargs) -> VideoProvider:
    if provider_id not in _VIDEO_PROVIDERS:
        raise ValueError(
            f"Unknown video provider '{provider_id}'. "
            f"Available: {list(_VIDEO_PROVIDERS.keys())}"
        )
    info, factory = _VIDEO_PROVIDERS[provider_id]
    return factory(**kwargs)

def create_voice_provider(provider_id: str, **kwargs) -> VoiceProvider:
    if provider_id not in _VOICE_PROVIDERS:
        raise ValueError(
            f"Unknown voice provider '{provider_id}'. "
            f"Available: {list(_VOICE_PROVIDERS.keys())}"
        )
    info, factory = _VOICE_PROVIDERS[provider_id]
    return factory(**kwargs)

def create_lipsync_provider(provider_id: str, **kwargs) -> LipsyncProvider:
    if provider_id not in _LIPSYNC_PROVIDERS:
        raise ValueError(
            f"Unknown lipsync provider '{provider_id}'. "
            f"Available: {list(_LIPSYNC_PROVIDERS.keys())}"
        )
    info, factory = _LIPSYNC_PROVIDERS[provider_id]
    return factory(**kwargs)

def create_text_provider(provider_id: str, **kwargs) -> TextProvider:
    if provider_id not in _TEXT_PROVIDERS:
        raise ValueError(
            f"Unknown text provider '{provider_id}'. "
            f"Available: {list(_TEXT_PROVIDERS.keys())}"
        )
    info, factory = _TEXT_PROVIDERS[provider_id]
    return factory(**kwargs)


# ── Register built-in providers ──────────────────────────────────

def _register_builtins():
    from .freepik_provider import (
        FreepikImageProvider, FreepikVideoProvider, FreepikLipsyncProvider
    )
    from .elevenlabs_provider import ElevenLabsVoiceProvider

    register_image_provider(
        ProviderInfo(
            id="freepik",
            name="Freepik Mystic (Cloud)",
            category="image",
            requires_api_key=True,
            requires_server_url=False,
            description="Cloud image generation via Freepik API",
        ),
        lambda api_key="", **kw: FreepikImageProvider(api_key, **kw),
    )

    register_video_provider(
        ProviderInfo(
            id="freepik",
            name="Freepik (Cloud)",
            category="video",
            requires_api_key=True,
            requires_server_url=False,
            description=(
                "Cloud video generation via Freepik. Supports multiple "
                "models (Kling v3 Omni, Kling v2.5/v2.6 Pro, Kling O1 Pro, "
                "Seedance Pro, MiniMax Hailuo, Wan v2.6) — choose the "
                "model in Step 8."
            ),
        ),
        lambda api_key="", **kw: FreepikVideoProvider(api_key, **kw),
    )

    register_voice_provider(
        ProviderInfo(
            id="elevenlabs",
            name="ElevenLabs (Cloud)",
            category="voice",
            requires_api_key=True,
            requires_server_url=False,
            description="Cloud voice cloning and TTS via ElevenLabs",
        ),
        lambda api_key="", **kw: ElevenLabsVoiceProvider(api_key, **kw),
    )

    register_lipsync_provider(
        ProviderInfo(
            id="freepik",
            name="Kling Lip-Sync (Cloud via Freepik)",
            category="lipsync",
            requires_api_key=True,
            requires_server_url=False,
            description="Cloud lip-sync via Freepik/Kling API",
        ),
        lambda api_key="", **kw: FreepikLipsyncProvider(api_key, **kw),
    )

    # ComfyUI-based local providers
    try:
        from .comfyui_provider import ComfyUIFluxImageProvider, ComfyUILTXVideoProvider

        register_image_provider(
            ProviderInfo(
                id="comfyui_flux",
                name="Flux Kontext (Local ComfyUI)",
                category="image",
                requires_api_key=False,
                requires_server_url=True,
                default_server_url="http://127.0.0.1:8188",
                description="Local Flux Kontext image generation via ComfyUI",
            ),
            lambda server_url="http://127.0.0.1:8188", **kw: ComfyUIFluxImageProvider(server_url),
        )

        register_video_provider(
            ProviderInfo(
                id="comfyui_ltx",
                name="LTX 2.3 (Local ComfyUI)",
                category="video",
                requires_api_key=False,
                requires_server_url=True,
                default_server_url="http://127.0.0.1:8188",
                description="Local LTX 2.3 video generation via ComfyUI",
            ),
            lambda server_url="http://127.0.0.1:8188", **kw: ComfyUILTXVideoProvider(server_url),
        )
    except ImportError:
        logger.debug("ComfyUI providers not available (missing comfyui_provider module)")

    # Voicebox local voice provider
    try:
        from .voicebox_provider import VoiceboxVoiceProvider

        register_voice_provider(
            ProviderInfo(
                id="voicebox",
                name="Voicebox (Local)",
                category="voice",
                requires_api_key=False,
                requires_server_url=True,
                default_server_url="http://127.0.0.1:17493",
                description="Local voice cloning and TTS via Voicebox",
            ),
            lambda server_url="http://127.0.0.1:17493", **kw: VoiceboxVoiceProvider(server_url, **kw),
        )
    except ImportError:
        logger.debug("Voicebox provider not available (missing voicebox_provider module)")

    # OpenAI gpt-image-2 (cloud image generation)
    try:
        from .openai_image_provider import OpenAIImageProvider

        register_image_provider(
            ProviderInfo(
                id="openai",
                name="GPT Image 2 (OpenAI)",
                category="image",
                requires_api_key=True,
                requires_server_url=False,
                description="Cloud image generation via OpenAI gpt-image-2",
            ),
            lambda api_key="", **kw: OpenAIImageProvider(api_key, **kw),
        )
    except ImportError:
        logger.debug("OpenAI image provider not available")

    # OpenAI Sora (cloud video generation)
    try:
        from .openai_video_provider import OpenAIVideoProvider

        register_video_provider(
            ProviderInfo(
                id="openai",
                name="OpenAI Sora 2",
                category="video",
                requires_api_key=True,
                requires_server_url=False,
                description=(
                    "Cloud video generation via OpenAI Sora 2 / Sora 2 Pro. "
                    "Text-to-video only (no start-image input). "
                    "Resolutions: 1280x720, 720x1280, 1024x1792, 1792x1024. "
                    "Durations: 4 / 8 / 12 seconds. Choose model in Step 8."
                ),
            ),
            lambda api_key="", **kw: OpenAIVideoProvider(api_key, **kw),
        )
    except ImportError:
        logger.debug("OpenAI video provider not available")

    # Grok Imagine (xAI cloud) providers
    try:
        from .grok_provider import GrokImageProvider, GrokVideoProvider

        register_image_provider(
            ProviderInfo(
                id="grok",
                name="Grok Imagine (Cloud)",
                category="image",
                requires_api_key=True,
                requires_server_url=False,
                description="Cloud image generation via xAI Grok Imagine API",
            ),
            lambda api_key="", **kw: GrokImageProvider(api_key, **kw),
        )

        register_video_provider(
            ProviderInfo(
                id="grok",
                name="Grok Imagine Video (Cloud)",
                category="video",
                requires_api_key=True,
                requires_server_url=False,
                description="Cloud video generation via xAI Grok Imagine API",
            ),
            lambda api_key="", **kw: GrokVideoProvider(api_key, **kw),
        )
    except ImportError:
        logger.debug("Grok providers not available (missing grok_provider module)")

    # MLX-Audio (fast local TTS on Apple Silicon)
    try:
        from .mlx_audio_provider import MLXAudioVoiceProvider

        register_voice_provider(
            ProviderInfo(
                id="mlx_audio",
                name="MLX-Audio Kokoro (Local, Fast)",
                category="voice",
                requires_api_key=False,
                requires_server_url=False,
                description="Fast local TTS via MLX on Apple Silicon (~12x faster than Voicebox CPU)",
            ),
            lambda **kw: MLXAudioVoiceProvider(**kw),
        )
    except ImportError:
        logger.debug("MLX-Audio provider not available (missing mlx_audio_provider module)")

    # Grok text/chat LLM (for shot expansion)
    try:
        from .grok_text_provider import GrokTextProvider

        register_text_provider(
            ProviderInfo(
                id="grok",
                name="Grok (xAI)",
                category="text",
                requires_api_key=True,
                requires_server_url=False,
                description="Grok chat LLM for shot expansion and other text generation",
            ),
            lambda api_key="", **kw: GrokTextProvider(api_key, **kw),
        )
    except ImportError:
        logger.debug("Grok text provider not available")

    # Kling AI direct API (lip sync with JWT auth)
    try:
        from .kling_provider import KlingLipsyncProvider

        register_lipsync_provider(
            ProviderInfo(
                id="kling",
                name="Kling AI (Direct API)",
                category="lipsync",
                requires_api_key=True,
                requires_server_url=False,
                description="Lip sync via Kling AI direct API (requires access_key:secret_key)",
            ),
            lambda api_key="", **kw: KlingLipsyncProvider(api_key, **kw),
        )
    except ImportError:
        logger.debug("Kling provider not available (missing kling_provider module)")


_register_builtins()
