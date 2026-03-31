"""Standalone entry points for individual ScriptToScreen tools.

Each function is called from a Lua script via runPython() and returns
JSON to stdout.  The Lua script parses the JSON to update its UI.
"""

import json
import logging
import os
import re
import traceback
import uuid
from typing import Optional

from .api.registry import (
    create_image_provider,
    create_video_provider,
    create_voice_provider,
    create_lipsync_provider,
)
from .api.polling import poll_until_complete
from .manifest import (
    load_manifest,
    record_generated_image,
    record_generated_video,
    record_generated_audio,
    record_generated_lipsync,
    update_character,
    get_project_voices,
    lookup_by_filename,
)
from .utils import ensure_dir, sanitize_filename

logger = logging.getLogger("ScriptToScreen")


def _shot_key_from_filename(filename: str) -> str:
    """Extract shot key (s0_sh0) from a hashed filename (s0_sh0_abc123.png)."""
    m = re.match(r"(s\d+_sh\d+)", filename)
    return m.group(1) if m else os.path.splitext(filename)[0]


# ------------------------------------------------------------------
# Reprompt Image
# ------------------------------------------------------------------

def reprompt_image(
    prompt: str,
    provider_id: str,
    api_key: str,
    output_dir: str,
    project_slug: str,
    style_reference_path: str = "",
    character_ref_paths: Optional[dict] = None,
    model: str = "realism",
    aspect_ratio: str = "widescreen_16_9",
    creative_detailing: int = 33,
    server_url: str = "",
    shot_key: str = "",
) -> dict:
    """Generate a new image from an edited prompt. Returns {status, file_path}."""
    try:
        provider = create_image_provider(
            provider_id, api_key=api_key, server_url=server_url, model=model
        )

        # Build prompt with character refs
        char_refs = character_ref_paths or {}
        final_prompt = provider.build_prompt(prompt, char_refs)

        images_dir = ensure_dir(os.path.join(output_dir, "images"))

        task_id = provider.generate_image(
            prompt=final_prompt,
            style_reference_path=style_reference_path or None,
            style_adherence=creative_detailing,
            aspect_ratio=aspect_ratio,
            model=model,
            creative_detailing=creative_detailing,
        )

        result = poll_until_complete(
            task_id, provider.check_image_status, timeout=600, interval=10
        )

        images = result.get("images", [])
        if not images:
            return {"status": "error", "error": "No image returned by provider"}

        uid = uuid.uuid4().hex[:8]
        if not shot_key:
            shot_key = f"reprompt_{uid}"
        filename = f"{shot_key}_{uid}.png"
        save_path = os.path.join(images_dir, filename)
        # download_image may correct the extension (e.g. .png → .jpg)
        actual_path = provider.download_image(images[0], save_path)
        save_path = actual_path
        filename = os.path.basename(actual_path)

        # Record in manifest
        record_generated_image(
            project_slug=project_slug,
            filename=filename,
            file_path=save_path,
            shot_key=shot_key,
            prompt=prompt,
            provider=provider_id,
            provider_settings={"model": model, "aspect_ratio": aspect_ratio},
            style_reference_path=style_reference_path,
            character_refs=char_refs,
        )

        return {"status": "ok", "file_path": save_path, "filename": filename}

    except Exception as e:
        return {"status": "error", "error": str(e), "trace": traceback.format_exc()}


# ------------------------------------------------------------------
# Reprompt Video
# ------------------------------------------------------------------

def reprompt_video(
    prompt: str,
    provider_id: str,
    api_key: str,
    output_dir: str,
    project_slug: str,
    start_image_path: str = "",
    duration: int = 5,
    server_url: str = "",
    shot_key: str = "",
    aspect_ratio: str = "16:9",
) -> dict:
    """Generate a new video from an edited prompt. Returns {status, file_path}."""
    try:
        provider = create_video_provider(
            provider_id, api_key=api_key, server_url=server_url
        )

        videos_dir = ensure_dir(os.path.join(output_dir, "videos"))

        task_id = provider.generate_video(
            prompt=prompt,
            start_image_path=start_image_path or None,
            duration=duration,
            aspect_ratio=aspect_ratio,
        )

        result = poll_until_complete(
            task_id, provider.check_video_status, timeout=600, interval=10
        )

        videos = result.get("videos", [])
        if not videos:
            return {"status": "error", "error": "No video returned by provider"}

        uid = uuid.uuid4().hex[:8]
        if not shot_key:
            shot_key = f"reprompt_{uid}"
        filename = f"{shot_key}_{uid}.mp4"
        save_path = os.path.join(videos_dir, filename)
        provider.download_video(videos[0], save_path)

        record_generated_video(
            project_slug=project_slug,
            filename=filename,
            file_path=save_path,
            shot_key=shot_key,
            prompt=prompt,
            provider=provider_id,
            provider_settings={"duration": duration, "aspect_ratio": aspect_ratio},
            start_image_path=start_image_path,
        )

        return {"status": "ok", "file_path": save_path, "filename": filename}

    except Exception as e:
        return {"status": "error", "error": str(e), "trace": traceback.format_exc()}


# ------------------------------------------------------------------
# Standalone Audio
# ------------------------------------------------------------------

def generate_audio_standalone(
    text: str,
    voice_id: str,
    provider_id: str,
    api_key: str,
    output_dir: str,
    project_slug: str,
    character_name: str = "Unknown",
    server_url: str = "",
    shot_key: str = "",
) -> dict:
    """Generate TTS audio. Returns {status, file_path}."""
    try:
        provider = create_voice_provider(
            provider_id, api_key=api_key, server_url=server_url
        )

        audio_dir = ensure_dir(os.path.join(output_dir, "audio"))
        uid = uuid.uuid4().hex[:8]
        if shot_key:
            filename = f"{shot_key}_{uid}.wav"
        else:
            safe_char = sanitize_filename(character_name)
            filename = f"tts_{safe_char}_{uid}.wav"
        save_path = os.path.join(audio_dir, filename)

        actual_path = provider.generate_speech(voice_id, text, save_path)

        record_generated_audio(
            project_slug=project_slug,
            filename=os.path.basename(actual_path),
            file_path=actual_path,
            dialogue_key=f"standalone_{uid}",
            text=text,
            character=character_name,
            voice_id=voice_id,
            provider=provider_id,
        )

        return {"status": "ok", "file_path": actual_path, "filename": os.path.basename(actual_path)}

    except Exception as e:
        return {"status": "error", "error": str(e), "trace": traceback.format_exc()}


def clone_voice_standalone(
    name: str,
    audio_paths: list[str],
    provider_id: str,
    api_key: str,
    project_slug: str,
    server_url: str = "",
) -> dict:
    """Clone a voice and store in the manifest. Returns {status, voice_id}."""
    try:
        provider = create_voice_provider(
            provider_id, api_key=api_key, server_url=server_url
        )

        voice_id = provider.clone_voice(name, audio_paths)

        update_character(
            project_slug=project_slug,
            name=name,
            voice_id=voice_id,
            voice_provider=provider_id,
            voice_samples=audio_paths,
        )

        return {"status": "ok", "voice_id": voice_id, "name": name}

    except Exception as e:
        return {"status": "error", "error": str(e), "trace": traceback.format_exc()}


# ------------------------------------------------------------------
# Standalone Lip Sync
# ------------------------------------------------------------------

def generate_lipsync_standalone(
    video_path: str,
    audio_path: str,
    provider_id: str,
    api_key: str,
    output_dir: str,
    project_slug: str,
    server_url: str = "",
    shot_key: str = "",
) -> dict:
    """Generate lip-synced video. Returns {status, file_path}."""
    try:
        provider = create_lipsync_provider(
            provider_id, api_key=api_key, server_url=server_url
        )

        lipsync_dir = ensure_dir(os.path.join(output_dir, "lipsync"))

        task_id = provider.generate_lipsync(video_path, audio_path)

        result = poll_until_complete(
            task_id, provider.check_lipsync_status, timeout=600, interval=10
        )

        videos = result.get("videos", [])
        if not videos:
            return {"status": "error", "error": "No lip-sync result returned"}

        uid = uuid.uuid4().hex[:8]
        if not shot_key:
            shot_key = f"lipsync_{uid}"
        filename = f"{shot_key}_ls_{uid}.mp4"
        save_path = os.path.join(lipsync_dir, filename)
        provider.download_video(videos[0], save_path)

        record_generated_lipsync(
            project_slug=project_slug,
            filename=filename,
            file_path=save_path,
            shot_key=shot_key,
            video_path=video_path,
            audio_path=audio_path,
            provider=provider_id,
        )

        return {"status": "ok", "file_path": save_path, "filename": filename}

    except Exception as e:
        return {"status": "error", "error": str(e), "trace": traceback.format_exc()}


# ------------------------------------------------------------------
# Metadata lookup (called from Lua to pre-fill UI)
# ------------------------------------------------------------------

def get_clip_metadata(project_slug: str, filename: str) -> dict:
    """Look up generation metadata for a clip filename."""
    entry = lookup_by_filename(project_slug, filename)
    if entry:
        return {"status": "ok", "metadata": entry}
    return {"status": "not_found"}


def list_project_voices(project_slug: str) -> dict:
    """List all voice clones for a project."""
    voices = get_project_voices(project_slug)
    return {"status": "ok", "voices": voices}
