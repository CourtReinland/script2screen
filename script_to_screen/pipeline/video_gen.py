"""Video generation pipeline — provider-agnostic."""

import logging
import os
import uuid
from typing import Optional, Callable

from ..api.providers import VideoProvider
from ..api.polling import poll_until_complete, GenerationError
from ..config import GenerationDefaults
from ..parsing.screenplay_model import Screenplay, Scene, Shot
from ..utils import ensure_dir, ProgressTracker

logger = logging.getLogger("ScriptToScreen")


def _estimate_duration(shot: Shot, scene: Scene, defaults: GenerationDefaults) -> int:
    """Estimate video duration based on shot content."""
    has_dialogue = any(
        True for dl in scene.dialogue if dl.shot_index == scene.shots.index(shot)
    )
    if has_dialogue:
        dialogue_text = " ".join(
            dl.text for dl in scene.dialogue
            if dl.shot_index == scene.shots.index(shot)
        )
        word_count = len(dialogue_text.split())
        estimated_seconds = max(defaults.video_duration_dialogue, int(word_count / 3))
        return min(estimated_seconds, 15)

    if shot.shot_type in ("WS", "LS") and scene.shots.index(shot) == 0:
        return defaults.video_duration_establishing

    return defaults.video_duration_action


def build_motion_prompt(shot: Shot, scene: Scene) -> str:
    """Build a motion description prompt for video generation."""
    parts = []

    if shot.description:
        parts.append(shot.description)

    shot_idx = scene.shots.index(shot) if shot in scene.shots else -1
    dialogue_lines = [dl for dl in scene.dialogue if dl.shot_index == shot_idx]
    if dialogue_lines:
        chars_speaking = set(dl.character for dl in dialogue_lines)
        parts.append(f"{', '.join(chars_speaking)} speaking")

    if scene.location_type == "EXT":
        parts.append("outdoor environment with natural movement")
    else:
        parts.append("indoor scene with subtle movement")

    prompt = ". ".join(parts)
    if len(prompt) > 500:
        prompt = prompt[:497] + "..."
    return prompt


def build_all_motion_prompts(screenplay: Screenplay) -> dict[str, str]:
    """Build the auto motion-prompt for every shot in the screenplay.

    Returns a dict keyed by shot_key ("s{scene}_sh{shot}") → prompt string.
    Used by the Step 7 "Review Video Prompts" wizard page to populate its
    tree in a single Python call.
    """
    out: dict[str, str] = {}
    for scene in screenplay.scenes:
        for si, shot in enumerate(scene.shots):
            shot_key = f"s{scene.index}_sh{si}"
            out[shot_key] = build_motion_prompt(shot, scene)
    return out


def generate_videos_for_screenplay(
    screenplay: Screenplay,
    provider: VideoProvider,
    image_paths: dict[str, str],
    output_dir: str,
    defaults: Optional[GenerationDefaults] = None,
    progress_callback: Optional[Callable[[int, int, str], None]] = None,
    custom_durations: Optional[dict[str, int]] = None,
    custom_prompts: Optional[dict[str, str]] = None,
    project_slug: Optional[str] = None,
) -> dict[str, str]:
    """
    Generate videos for all shots using their generated images as start frames.

    Args:
        screenplay: Parsed screenplay.
        provider: Video generation provider.
        image_paths: Dict of shot_key -> image file path (from image_gen).
        output_dir: Directory to save generated videos.
        defaults: Generation settings.
        progress_callback: callback(current, total, message).
        custom_durations: Optional dict of shot_key -> duration in seconds.
        custom_prompts: Optional dict of shot_key -> motion prompt.

    Returns:
        Dict mapping shot_key to video file path.
    """
    if defaults is None:
        defaults = GenerationDefaults()

    videos_dir = ensure_dir(os.path.join(output_dir, "videos"))

    all_shots = []
    for scene in screenplay.scenes:
        for shot_idx, shot in enumerate(scene.shots):
            shot_key = f"s{scene.index}_sh{shot_idx}"
            if shot_key in image_paths:
                all_shots.append((shot_key, shot, scene))

    if not all_shots:
        logger.warning("No matching images found for any shots")
        return {"_errors": ["No matching images found for any shots"]}

    logger.info(f"Generating videos for {len(all_shots)} shots...")
    tracker = ProgressTracker(len(all_shots), progress_callback)
    results: dict[str, str] = {}
    errors: list[str] = []

    for shot_key, shot, scene in all_shots:
        image_path = image_paths[shot_key]

        # Duration
        if custom_durations and shot_key in custom_durations:
            duration = custom_durations[shot_key]
        else:
            duration = _estimate_duration(shot, scene, defaults)

        # Motion prompt
        if custom_prompts and shot_key in custom_prompts:
            motion_prompt = custom_prompts[shot_key]
        else:
            motion_prompt = build_motion_prompt(shot, scene)

        logger.info(f"Generating video for {shot_key} ({duration}s): {motion_prompt[:60]}...")

        try:
            task_id = provider.generate_video(
                prompt=motion_prompt,
                start_image_path=image_path,
                duration=duration,
                # Pass through model selection and shared params
                video_model=getattr(defaults, "video_model", "kling-v3-omni"),
                cfg_scale=getattr(defaults, "video_cfg_scale", 0.5),
                negative_prompt=getattr(defaults, "video_negative_prompt", ""),
            )

            result = poll_until_complete(
                task_id,
                provider.check_video_status,
                timeout=600,
                interval=10,
            )

            videos = result.get("videos", [])
            if videos:
                uid = uuid.uuid4().hex[:8]
                save_path = os.path.join(videos_dir, f"{shot_key}_{uid}.mp4")
                provider.download_video(videos[0], save_path)
                results[shot_key] = save_path
                logger.info(f"Video saved: {save_path}")

                # Record prompt in manifest
                if project_slug:
                    try:
                        from ..manifest import record_generated_video
                        record_generated_video(
                            project_slug=project_slug,
                            filename=os.path.basename(save_path),
                            file_path=save_path,
                            shot_key=shot_key,
                            prompt=motion_prompt,
                            provider=type(provider).__name__,
                            provider_settings={"duration": duration},
                            start_image_path=image_path,
                        )
                    except Exception as e:
                        logger.warning(f"[{shot_key}] Manifest write failed: {e}")
            else:
                err = f"{shot_key}: No video returned by provider"
                logger.warning(err)
                errors.append(err)

        except (GenerationError, Exception) as e:
            err = f"{shot_key}: {e}"
            logger.error(f"Video generation failed — {err}")
            errors.append(err)

        tracker.advance(f"Generated video {shot_key}")

    results["_errors"] = errors
    return results


def regenerate_single_video(
    shot_key: str,
    motion_prompt: str,
    image_path: str,
    provider: VideoProvider,
    output_dir: str,
    duration: int = 5,
    video_model: str = "kling-v3-omni",
    cfg_scale: float = 0.5,
    negative_prompt: str = "",
) -> Optional[str]:
    """Regenerate a single video by shot key."""
    videos_dir = ensure_dir(os.path.join(output_dir, "videos"))

    try:
        task_id = provider.generate_video(
            prompt=motion_prompt,
            start_image_path=image_path,
            duration=duration,
            video_model=video_model,
            cfg_scale=cfg_scale,
            negative_prompt=negative_prompt,
        )

        result = poll_until_complete(
            task_id, provider.check_video_status, timeout=600, interval=10,
        )

        videos = result.get("videos", [])
        if videos:
            uid = uuid.uuid4().hex[:8]
            save_path = os.path.join(videos_dir, f"{shot_key}_{uid}.mp4")
            provider.download_video(videos[0], save_path)
            return save_path

    except Exception as e:
        logger.error(f"Video regeneration failed for {shot_key}: {e}")

    return None
