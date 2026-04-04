"""Voice cloning and dialogue audio generation pipeline — provider-agnostic."""

import logging
import os
import uuid
from typing import Optional, Callable

from ..api.providers import VoiceProvider
from ..config import GenerationDefaults
from ..parsing.screenplay_model import Screenplay, DialogueLine
from ..utils import sanitize_filename, ensure_dir, ProgressTracker

logger = logging.getLogger("ScriptToScreen")


def clone_character_voices(
    screenplay: Screenplay,
    provider: VoiceProvider,
    voice_samples: dict[str, list[str]],
    progress_callback: Optional[Callable[[int, int, str], None]] = None,
) -> dict[str, str]:
    """
    Clone voices for each character that has voice samples.

    Args:
        screenplay: Parsed screenplay.
        provider: Voice generation provider.
        voice_samples: Dict of character_name -> list of audio file paths.
        progress_callback: callback(current, total, message).

    Returns:
        Dict mapping character_name -> voice_id.
    """
    tracker = ProgressTracker(len(voice_samples), progress_callback)
    voice_ids: dict[str, str] = {}

    for char_name, sample_paths in voice_samples.items():
        if not sample_paths:
            logger.warning(f"No samples for {char_name}, skipping")
            tracker.advance(f"Skipped {char_name}")
            continue

        logger.info(f"Cloning voice for {char_name} from {len(sample_paths)} samples...")

        try:
            voice_id = provider.clone_voice(
                name=f"STS_{sanitize_filename(char_name)}",
                audio_paths=sample_paths,
                description=f"AI voice clone for character {char_name}",
            )
            voice_ids[char_name] = voice_id

            if char_name in screenplay.characters:
                screenplay.characters[char_name].voice_id = voice_id

            logger.info(f"Voice cloned for {char_name}: {voice_id}")

        except Exception as e:
            logger.error(f"Voice cloning failed for {char_name}: {e}")
            tracker.error(f"{char_name}: {e}")

        tracker.advance(f"Cloned voice for {char_name}")

    return voice_ids


def generate_dialogue_audio(
    screenplay: Screenplay,
    provider: VoiceProvider,
    output_dir: str,
    defaults: Optional[GenerationDefaults] = None,
    progress_callback: Optional[Callable[[int, int, str], None]] = None,
) -> dict[str, str]:
    """
    Generate audio for all dialogue lines in the screenplay.

    Args:
        screenplay: Parsed screenplay (characters must have voice_ids set).
        provider: Voice generation provider.
        output_dir: Directory to save audio files.
        defaults: Voice generation settings.
        progress_callback: callback(current, total, message).

    Returns:
        Dict mapping dialogue_key (f"s{scene}_d{idx}") to audio file path.
    """
    if defaults is None:
        defaults = GenerationDefaults()

    audio_dir = ensure_dir(os.path.join(output_dir, "dialogue_audio"))

    all_dialogue: list[tuple[str, DialogueLine, int]] = []
    for scene in screenplay.scenes:
        for d_idx, dl in enumerate(scene.dialogue):
            dialogue_key = f"s{scene.index}_d{d_idx}"
            all_dialogue.append((dialogue_key, dl, scene.index))

    tracker = ProgressTracker(len(all_dialogue), progress_callback)
    results: dict[str, str] = {}

    for dialogue_key, dl, scene_index in all_dialogue:
        char = screenplay.characters.get(dl.character)
        if not char or not char.voice_id:
            logger.warning(f"No voice for {dl.character}, skipping {dialogue_key}")
            tracker.advance(f"Skipped {dialogue_key}")
            continue

        logger.info(f"Generating audio {dialogue_key}: {dl.character} says '{dl.text[:40]}...'")

        try:
            uid = uuid.uuid4().hex[:8]
            shot_idx = getattr(dl, 'shot_index', 0)
            save_path = os.path.join(audio_dir, f"s{scene_index}_sh{shot_idx}_{uid}.mp3")

            actual_path = provider.generate_speech(
                voice_id=char.voice_id,
                text=dl.text,
                save_path=save_path,
                model_id=defaults.voice_model,
                stability=defaults.voice_stability,
                similarity_boost=defaults.voice_similarity_boost,
            )

            # Use the actual path returned by the provider (may differ in extension)
            results[dialogue_key] = actual_path or save_path
            logger.info(f"Dialogue audio saved: {actual_path or save_path}")

        except Exception as e:
            logger.error(f"Dialogue generation failed for {dialogue_key}: {e}")
            tracker.error(f"{dialogue_key}: {e}")

        tracker.advance(f"Generated audio {dialogue_key}")

    return results


def generate_shot_audio(
    screenplay: Screenplay,
    dialogue_audio_paths: dict[str, str],
    output_dir: str,
) -> dict[str, str]:
    """
    Combine dialogue audio files per shot for lip-sync.

    For shots with multiple dialogue lines, this creates a combined audio file.
    For shots with a single dialogue line, it just returns that file.

    Args:
        screenplay: Parsed screenplay.
        dialogue_audio_paths: Dict of dialogue_key -> audio path.
        output_dir: Directory for combined audio files.

    Returns:
        Dict mapping shot_key -> audio file path.
    """
    shot_audio_dir = ensure_dir(os.path.join(output_dir, "shot_audio"))
    results: dict[str, str] = {}

    for scene in screenplay.scenes:
        for shot_idx, shot in enumerate(scene.shots):
            shot_key = f"s{scene.index}_sh{shot_idx}"

            shot_dialogue_keys = []
            for d_idx, dl in enumerate(scene.dialogue):
                if dl.shot_index == shot_idx:
                    dialogue_key = f"s{scene.index}_d{d_idx}"
                    if dialogue_key in dialogue_audio_paths:
                        shot_dialogue_keys.append(dialogue_key)

            if not shot_dialogue_keys:
                continue

            if len(shot_dialogue_keys) == 1:
                results[shot_key] = dialogue_audio_paths[shot_dialogue_keys[0]]
            else:
                # TODO: Implement proper audio concatenation
                results[shot_key] = dialogue_audio_paths[shot_dialogue_keys[0]]
                logger.warning(
                    f"Shot {shot_key} has {len(shot_dialogue_keys)} dialogue lines; "
                    f"using first only (audio concat not yet implemented)"
                )

    return results
