"""Lip-sync pipeline — provider-agnostic."""

import logging
import os
from typing import Optional, Callable

from ..api.providers import LipsyncProvider
from ..api.polling import poll_until_complete, GenerationError
from ..parsing.screenplay_model import Screenplay
from ..utils import ensure_dir, ProgressTracker

logger = logging.getLogger("ScriptToScreen")


def _upload_for_url(file_path: str) -> str:
    """
    For lip-sync, some providers need publicly accessible URLs.
    In production this would upload to a temporary hosting service.
    For local development, this returns the local path.

    Note: Users may need to use a file hosting service or ngrok
    to make local files accessible. The plugin UI should handle this.
    """
    # TODO: Implement temporary file hosting (e.g., file.io, transfer.sh)
    return file_path


def generate_lipsync_for_shots(
    screenplay: Screenplay,
    provider: LipsyncProvider,
    video_paths: dict[str, str],
    audio_paths: dict[str, str],
    output_dir: str,
    progress_callback: Optional[Callable[[int, int, str], None]] = None,
    video_urls: Optional[dict[str, str]] = None,
    audio_urls: Optional[dict[str, str]] = None,
) -> dict[str, str]:
    """
    Generate lip-synced videos for shots that have both video and audio.

    Args:
        screenplay: Parsed screenplay.
        provider: Lip-sync provider.
        video_paths: Dict of shot_key -> video file path.
        audio_paths: Dict of shot_key -> audio file path.
        output_dir: Directory to save lip-synced videos.
        progress_callback: callback(current, total, message).
        video_urls: Optional dict of shot_key -> publicly accessible video URL.
        audio_urls: Optional dict of shot_key -> publicly accessible audio URL.

    Returns:
        Dict mapping shot_key to lip-synced video file path.
    """
    lipsync_dir = ensure_dir(os.path.join(output_dir, "lipsync"))

    shots_to_sync = []
    for shot_key in video_paths:
        if shot_key in audio_paths:
            shots_to_sync.append(shot_key)

    if not shots_to_sync:
        logger.warning("No shots have both video and audio for lip-sync")
        return {}

    tracker = ProgressTracker(len(shots_to_sync), progress_callback)
    results: dict[str, str] = {}

    for shot_key in shots_to_sync:
        if video_urls and shot_key in video_urls:
            v_url = video_urls[shot_key]
        else:
            v_url = _upload_for_url(video_paths[shot_key])

        if audio_urls and shot_key in audio_urls:
            a_url = audio_urls[shot_key]
        else:
            a_url = _upload_for_url(audio_paths[shot_key])

        logger.info(f"Lip-syncing {shot_key}...")

        try:
            task_id = provider.generate_lipsync(
                video_url=v_url,
                audio_url=a_url,
            )

            result = poll_until_complete(
                task_id,
                provider.check_lipsync_status,
                timeout=600,
                interval=10,
                label=shot_key,
            )

            videos = result.get("videos", [])
            if videos:
                save_path = os.path.join(lipsync_dir, f"{shot_key}_synced.mp4")
                # Lipsync provider uses the video provider's download method
                # For now, handle URL-based download inline
                if isinstance(videos[0], str):
                    import requests
                    resp = requests.get(videos[0], timeout=120, stream=True)
                    resp.raise_for_status()
                    with open(save_path, "wb") as f:
                        for chunk in resp.iter_content(8192):
                            f.write(chunk)
                elif isinstance(videos[0], dict):
                    url = videos[0].get("url", "")
                    import requests
                    resp = requests.get(url, timeout=120, stream=True)
                    resp.raise_for_status()
                    with open(save_path, "wb") as f:
                        for chunk in resp.iter_content(8192):
                            f.write(chunk)
                results[shot_key] = save_path
                logger.info(f"Lip-synced video saved: {save_path}")
            else:
                tracker.error(f"No lip-synced video returned for {shot_key}")

        except (GenerationError, Exception) as e:
            logger.error(f"Lip-sync failed for {shot_key}: {e}")
            tracker.error(f"{shot_key}: {e}")

        tracker.advance(f"Lip-synced {shot_key}")

    return results


def get_final_video_paths(
    video_paths: dict[str, str],
    lipsync_paths: dict[str, str],
) -> dict[str, str]:
    """
    Merge original videos with lip-synced versions.
    Lip-synced versions take priority where available.

    Returns:
        Dict of shot_key -> final video path (lip-synced if available, otherwise original).
    """
    final = dict(video_paths)
    final.update(lipsync_paths)
    return final
