"""Project manifest — persistent metadata for generated media.

Each ScriptToScreen project stores a manifest.json that records every
generation's prompt, provider settings, character/style refs, and file path.
This enables the standalone reprompt tools to pre-fill the original prompt
and settings when re-generating individual clips.
"""

import json
import logging
import os
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

logger = logging.getLogger("ScriptToScreen")

# Manifest lives alongside generated media in the project directory
# ~/Library/Application Support/ScriptToScreen/projects/{slug}/manifest.json
_APP_DIR = Path.home() / "Library" / "Application Support" / "ScriptToScreen"


def _sanitize_slug(name: str) -> str:
    """Turn a Resolve project name into a filesystem-safe slug."""
    slug = re.sub(r"[^\w\-]", "_", name).strip("_").lower()
    return slug or "default"


def get_project_dir(project_slug: str) -> Path:
    d = _APP_DIR / "projects" / project_slug
    d.mkdir(parents=True, exist_ok=True)
    return d


def get_manifest_path(project_slug: str) -> Path:
    return get_project_dir(project_slug) / "manifest.json"


# ------------------------------------------------------------------
# Load / save
# ------------------------------------------------------------------

_EMPTY_MANIFEST = {
    "version": 1,
    "resolve_project_name": "",
    "characters": {},
    "locations": {},
    "generated_media": {},
}


def load_manifest(project_slug: str) -> dict:
    """Load the manifest for a project, creating an empty one if needed."""
    path = get_manifest_path(project_slug)
    if path.exists():
        try:
            with open(path) as f:
                data = json.load(f)
            # Ensure all top-level keys exist (forward compat)
            for key, default in _EMPTY_MANIFEST.items():
                data.setdefault(key, default if not isinstance(default, dict) else {})
            return data
        except (json.JSONDecodeError, OSError) as e:
            logger.warning(f"Manifest load failed ({path}): {e} — starting fresh")
    return dict(_EMPTY_MANIFEST)


def save_manifest(project_slug: str, manifest: dict) -> None:
    """Atomically write the manifest to disk."""
    path = get_manifest_path(project_slug)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    with open(tmp, "w") as f:
        json.dump(manifest, f, indent=2)
    tmp.replace(path)
    logger.debug(f"Manifest saved: {path}")


# ------------------------------------------------------------------
# Record generated media
# ------------------------------------------------------------------

def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def record_generated_image(
    project_slug: str,
    filename: str,
    file_path: str,
    shot_key: str,
    prompt: str,
    provider: str,
    provider_settings: Optional[dict] = None,
    style_reference_path: Optional[str] = None,
    character_refs: Optional[dict] = None,
) -> None:
    """Record an image generation in the manifest."""
    m = load_manifest(project_slug)
    m["generated_media"][filename] = {
        "type": "image",
        "shot_key": shot_key,
        "prompt": prompt,
        "provider": provider,
        "provider_settings": provider_settings or {},
        "style_reference_path": style_reference_path or "",
        "character_refs": character_refs or {},
        "file_path": file_path,
        "generated_at": _now_iso(),
    }
    save_manifest(project_slug, m)


def record_generated_video(
    project_slug: str,
    filename: str,
    file_path: str,
    shot_key: str,
    prompt: str,
    provider: str,
    provider_settings: Optional[dict] = None,
    start_image_path: Optional[str] = None,
) -> None:
    """Record a video generation in the manifest."""
    m = load_manifest(project_slug)
    m["generated_media"][filename] = {
        "type": "video",
        "shot_key": shot_key,
        "prompt": prompt,
        "provider": provider,
        "provider_settings": provider_settings or {},
        "start_image_path": start_image_path or "",
        "file_path": file_path,
        "generated_at": _now_iso(),
    }
    save_manifest(project_slug, m)


def record_generated_audio(
    project_slug: str,
    filename: str,
    file_path: str,
    dialogue_key: str,
    text: str,
    character: str,
    voice_id: str,
    provider: str,
) -> None:
    """Record a TTS audio generation in the manifest."""
    m = load_manifest(project_slug)
    m["generated_media"][filename] = {
        "type": "audio",
        "dialogue_key": dialogue_key,
        "text": text,
        "character": character,
        "voice_id": voice_id,
        "provider": provider,
        "file_path": file_path,
        "generated_at": _now_iso(),
    }
    save_manifest(project_slug, m)


def record_generated_lipsync(
    project_slug: str,
    filename: str,
    file_path: str,
    shot_key: str,
    video_path: str,
    audio_path: str,
    provider: str,
) -> None:
    """Record a lip-sync generation in the manifest."""
    m = load_manifest(project_slug)
    m["generated_media"][filename] = {
        "type": "lipsync",
        "shot_key": shot_key,
        "video_path": video_path,
        "audio_path": audio_path,
        "provider": provider,
        "file_path": file_path,
        "generated_at": _now_iso(),
    }
    save_manifest(project_slug, m)


# ------------------------------------------------------------------
# Lookup
# ------------------------------------------------------------------

def lookup_by_filename(project_slug: str, filename: str) -> Optional[dict]:
    """Find metadata for a generated file by its filename."""
    m = load_manifest(project_slug)
    return m["generated_media"].get(filename)


def lookup_by_file_path(project_slug: str, file_path: str) -> Optional[dict]:
    """Find metadata for a generated file by its full path."""
    m = load_manifest(project_slug)
    for entry in m["generated_media"].values():
        if entry.get("file_path") == file_path:
            return entry
    return None


def lookup_by_shot_key(
    project_slug: str, shot_key: str, media_type: str = "image"
) -> Optional[dict]:
    """Find the most recent generation for a shot key and type."""
    m = load_manifest(project_slug)
    best = None
    for entry in m["generated_media"].values():
        if entry.get("shot_key") == shot_key and entry.get("type") == media_type:
            if best is None or entry.get("generated_at", "") > best.get("generated_at", ""):
                best = entry
    return best


# ------------------------------------------------------------------
# Characters & locations
# ------------------------------------------------------------------

def update_character(
    project_slug: str,
    name: str,
    reference_image_path: Optional[str] = None,
    voice_id: Optional[str] = None,
    voice_provider: Optional[str] = None,
    voice_samples: Optional[list[str]] = None,
) -> None:
    """Add or update a character entry in the manifest."""
    m = load_manifest(project_slug)
    char = m["characters"].get(name, {})
    if reference_image_path is not None:
        char["reference_image_path"] = reference_image_path
    if voice_id is not None:
        char["voice_id"] = voice_id
    if voice_provider is not None:
        char["voice_provider"] = voice_provider
    if voice_samples is not None:
        char["voice_samples"] = voice_samples
    m["characters"][name] = char
    save_manifest(project_slug, m)


def update_location(
    project_slug: str,
    name: str,
    reference_image_paths: Optional[list[str]] = None,
    description: Optional[str] = None,
) -> None:
    """Add or update a location entry in the manifest."""
    m = load_manifest(project_slug)
    loc = m["locations"].get(name, {})
    if reference_image_paths is not None:
        loc["reference_image_paths"] = reference_image_paths
    if description is not None:
        loc["description"] = description
    m["locations"][name] = loc
    save_manifest(project_slug, m)


def set_project_name(project_slug: str, resolve_project_name: str) -> None:
    """Store the Resolve project name in the manifest."""
    m = load_manifest(project_slug)
    m["resolve_project_name"] = resolve_project_name
    save_manifest(project_slug, m)


def get_project_voices(project_slug: str) -> dict:
    """Get all voice clones stored in the manifest. Returns {name: {voice_id, provider, ...}}."""
    m = load_manifest(project_slug)
    voices = {}
    for name, char in m["characters"].items():
        if char.get("voice_id"):
            voices[name] = {
                "voice_id": char["voice_id"],
                "voice_provider": char.get("voice_provider", ""),
                "voice_samples": char.get("voice_samples", []),
            }
    return voices
