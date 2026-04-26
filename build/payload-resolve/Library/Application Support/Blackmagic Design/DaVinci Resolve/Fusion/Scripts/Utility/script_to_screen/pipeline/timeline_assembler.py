"""DaVinci Resolve timeline assembly."""

import logging
import os
from typing import Optional, Callable

from ..parsing.screenplay_model import Screenplay
from ..utils import ProgressTracker

logger = logging.getLogger("ScriptToScreen")


def get_resolve():
    """Get the DaVinci Resolve scripting interface."""
    try:
        import DaVinciResolveScript as dvr_script
    except ImportError:
        # Fallback: try the environment-based import
        import sys
        script_module = os.environ.get(
            "RESOLVE_SCRIPT_API",
            "/Library/Application Support/Blackmagic Design/"
            "DaVinci Resolve/Developer/Scripting/Modules",
        )
        if script_module not in sys.path:
            sys.path.append(script_module)
        try:
            import DaVinciResolveScript as dvr_script
        except ImportError:
            raise RuntimeError(
                "Cannot import DaVinciResolveScript. "
                "Ensure DaVinci Resolve Studio is running and scripting is enabled."
            )
    resolve = dvr_script.scriptapp("Resolve")
    if not resolve:
        raise RuntimeError("Cannot connect to DaVinci Resolve. Is it running?")
    return resolve


def create_timeline(
    resolve,
    timeline_name: str,
    width: int = 1920,
    height: int = 1080,
    fps: float = 24.0,
) -> object:
    """Create a new timeline in the current project."""
    project = resolve.GetProjectManager().GetCurrentProject()
    if not project:
        raise RuntimeError("No project is open in DaVinci Resolve")

    media_pool = project.GetMediaPool()

    # Create timeline with settings
    timeline = media_pool.CreateEmptyTimeline(timeline_name)
    if not timeline:
        raise RuntimeError(f"Failed to create timeline '{timeline_name}'")

    # Set timeline properties
    timeline.SetSetting("useCustomSettings", "1")
    timeline.SetSetting("timelineResolutionWidth", str(width))
    timeline.SetSetting("timelineResolutionHeight", str(height))
    timeline.SetSetting("timelineFrameRate", str(fps))

    project.SetCurrentTimeline(timeline)
    logger.info(f"Created timeline: {timeline_name} ({width}x{height} @ {fps}fps)")
    return timeline


def import_to_media_pool(
    resolve,
    file_paths: list[str],
    bin_name: str = "ScriptToScreen",
) -> dict[str, object]:
    """
    Import media files into a dedicated Media Pool bin.

    Returns:
        Dict mapping file path to MediaPoolItem.
    """
    project = resolve.GetProjectManager().GetCurrentProject()
    media_pool = project.GetMediaPool()
    root_folder = media_pool.GetRootFolder()

    # Create or find the ScriptToScreen bin
    target_folder = None
    for subfolder in root_folder.GetSubFolderList():
        if subfolder.GetName() == bin_name:
            target_folder = subfolder
            break

    if not target_folder:
        target_folder = media_pool.AddSubFolder(root_folder, bin_name)

    media_pool.SetCurrentFolder(target_folder)

    # Import files
    items = media_pool.ImportMedia(file_paths)
    if not items:
        logger.warning(f"No items imported from {len(file_paths)} files")
        return {}

    # Map file paths to MediaPoolItems
    result = {}
    for item in items:
        clip_path = item.GetClipProperty("File Path")
        result[clip_path] = item

    # Also map by filename for fuzzy matching
    for path in file_paths:
        basename = os.path.basename(path)
        for item in items:
            item_name = item.GetName()
            if basename in item_name or item_name in basename:
                result[path] = item
                break

    logger.info(f"Imported {len(items)} items to '{bin_name}' bin")
    return result


def assemble_timeline(
    screenplay: Screenplay,
    final_video_paths: dict[str, str],
    shot_audio_paths: dict[str, str],
    timeline_name: str = "ScriptToScreen Assembly",
    width: int = 1920,
    height: int = 1080,
    fps: float = 24.0,
    progress_callback: Optional[Callable[[int, int, str], None]] = None,
) -> bool:
    """
    Assemble all generated media into a DaVinci Resolve timeline.

    Args:
        screenplay: Parsed screenplay for ordering.
        final_video_paths: Dict of shot_key -> video file path (lip-synced preferred).
        shot_audio_paths: Dict of shot_key -> audio file path.
        timeline_name: Name for the new timeline.
        width: Timeline resolution width.
        height: Timeline resolution height.
        fps: Timeline frame rate.
        progress_callback: callback(current, total, message).

    Returns:
        True if assembly was successful.
    """
    resolve = get_resolve()
    project = resolve.GetProjectManager().GetCurrentProject()
    media_pool = project.GetMediaPool()

    # Collect all files to import
    all_files = []
    for path in final_video_paths.values():
        if os.path.exists(path):
            all_files.append(path)
    for path in shot_audio_paths.values():
        if os.path.exists(path) and path not in all_files:
            all_files.append(path)

    if not all_files:
        logger.error("No media files to assemble")
        return False

    # Import all media
    media_items = import_to_media_pool(resolve, all_files)

    # Create timeline
    timeline = create_timeline(resolve, timeline_name, width, height, fps)

    # Build ordered clip list from screenplay
    ordered_shots = []
    for scene in screenplay.scenes:
        for shot_idx, shot in enumerate(scene.shots):
            shot_key = f"s{scene.index}_sh{shot_idx}"
            ordered_shots.append((shot_key, scene, shot))

    tracker = ProgressTracker(len(ordered_shots), progress_callback)

    for shot_key, scene, shot in ordered_shots:
        video_path = final_video_paths.get(shot_key)
        audio_path = shot_audio_paths.get(shot_key)

        if not video_path or not os.path.exists(video_path):
            logger.warning(f"No video for {shot_key}, skipping")
            tracker.advance(f"Skipped {shot_key}")
            continue

        # Find the MediaPoolItem for this video
        video_item = media_items.get(video_path)
        if not video_item:
            # Try by filename
            for key, item in media_items.items():
                if os.path.basename(video_path) in key:
                    video_item = item
                    break

        if not video_item:
            logger.warning(f"Could not find media pool item for {video_path}")
            tracker.advance(f"Skipped {shot_key}")
            continue

        # Append video to timeline
        clip_info = {
            "mediaPoolItem": video_item,
            "mediaType": 1,  # 1 = video
            "trackIndex": 1,
        }

        appended = media_pool.AppendToTimeline([clip_info])
        if not appended:
            logger.warning(f"Failed to append video {shot_key} to timeline")

        # Append audio if available (on audio track 1)
        if audio_path and os.path.exists(audio_path):
            audio_item = media_items.get(audio_path)
            if audio_item:
                audio_clip_info = {
                    "mediaPoolItem": audio_item,
                    "mediaType": 2,  # 2 = audio
                    "trackIndex": 1,
                }
                media_pool.AppendToTimeline([audio_clip_info])

        tracker.advance(f"Added {shot_key} to timeline")

    # Add markers at scene boundaries
    _add_scene_markers(timeline, screenplay, final_video_paths, fps)

    logger.info(f"Timeline assembly complete: {timeline_name}")
    return True


def _add_scene_markers(timeline, screenplay, video_paths, fps):
    """Add markers at scene boundaries in the timeline."""
    frame_position = 0
    colors = ["Blue", "Cyan", "Green", "Yellow", "Red", "Pink", "Purple", "Fuchsia"]

    for scene_idx, scene in enumerate(screenplay.scenes):
        color = colors[scene_idx % len(colors)]
        try:
            timeline.AddMarker(
                frame_position,
                color,
                scene.heading,
                f"Scene {scene.index + 1}",
                1,  # duration in frames
            )
        except Exception as e:
            logger.debug(f"Could not add marker for scene {scene_idx}: {e}")

        # Estimate frames for this scene's shots
        for shot_idx, shot in enumerate(scene.shots):
            shot_key = f"s{scene.index}_sh{shot_idx}"
            if shot_key in video_paths:
                # Rough estimate: 5 seconds per shot at given fps
                frame_position += int(5 * fps)
