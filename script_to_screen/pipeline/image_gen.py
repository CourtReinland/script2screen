"""Image generation pipeline — provider-agnostic."""

import logging
import os
import uuid
from typing import Optional, Callable

from ..api.providers import ImageProvider
from ..api.polling import poll_until_complete, GenerationError
from ..config import GenerationDefaults
from ..parsing.screenplay_model import Screenplay, Shot, Scene
from ..utils import sanitize_filename, ensure_dir, ProgressTracker

logger = logging.getLogger("ScriptToScreen")


def build_image_prompt(
    shot: Shot,
    scene: Scene,
    screenplay: Screenplay,
    shot_idx: int = -1,
) -> str:
    """Build a comprehensive image generation prompt from screenplay data.

    Each generated image needs the FULL context of the shot since the
    image generator has no knowledge of the screenplay. This includes:
    - Shot framing (WS, MS, CU, etc.)
    - Location and environment (INT/EXT, specific place, time of day)
    - What the characters are doing physically
    - What is being said (dialogue context informs expression/gesture)
    - Scene action and atmosphere
    """
    parts = []

    # 1. Shot framing
    if shot.prompt_prefix:
        parts.append(f"{shot.prompt_prefix}.")

    # 2. Location and environment
    loc_type = "Interior" if scene.location_type == "INT" else "Exterior"
    parts.append(f"{loc_type} of {scene.location}.")

    # 3. Time of day / lighting
    if scene.time_of_day:
        time_desc = {
            "DAY": "Bright natural daylight.",
            "NIGHT": "Nighttime, dark ambient lighting with artificial light sources.",
            "DAWN": "Dawn, warm golden light breaking through.",
            "DUSK": "Dusk, warm orange-purple sky.",
            "MORNING": "Soft morning light.",
            "EVENING": "Warm evening lighting.",
        }
        parts.append(time_desc.get(scene.time_of_day.upper(), ""))

    # 4. Characters present and what they're doing
    if shot_idx < 0:
        # Fallback: find by identity, not equality
        for _i, _s in enumerate(scene.shots):
            if _s is shot:
                shot_idx = _i
                break
    char_names = shot.characters_present

    # Get dialogue lines for this specific shot
    shot_dialogue = [dl for dl in scene.dialogue if dl.shot_index == shot_idx]

    if char_names:
        names_str = " and ".join(char_names)
        parts.append(f"Characters present: {names_str}.")

    # 5. Shot-specific description (from the shot label line)
    desc = shot.description or ""
    desc_has_action = len(desc.split()) > 3  # More than just "AIDEN AND ALIYAH"
    if desc_has_action:
        parts.append(desc)

    # 6. If the shot description was sparse, pull context from scene action
    if not desc_has_action and scene.action_description:
        action = scene.action_description.strip()
        if action:
            # Use a reasonable chunk of the action description
            if len(action) > 200:
                action = action[:200].rsplit(" ", 1)[0] + "..."
            parts.append(action)

    # 7. Dialogue context — describe the emotional tone and interaction
    #    Do NOT include the actual dialogue text in quotes — that causes the
    #    image generator to render the text as a speech bubble or overlay.
    #    Instead, describe what is happening emotionally and physically.
    if shot_dialogue:
        if len(shot_dialogue) >= 2:
            speakers = list({dl.character for dl in shot_dialogue})
            parts.append(
                f"{' and '.join(speakers)} are in conversation, "
                f"facing each other with expressive gestures."
            )
            # Infer tone from the dialogue content
            all_text = " ".join(dl.text for dl in shot_dialogue).lower()
            if any(w in all_text for w in ["why", "what", "how", "?"]):
                parts.append("The tone is questioning and uncertain.")
            elif any(w in all_text for w in ["no", "stop", "don't", "can't"]):
                parts.append("The tone is tense and resistant.")
            elif any(w in all_text for w in ["please", "help", "need"]):
                parts.append("The tone is earnest and pleading.")
        elif len(shot_dialogue) == 1:
            dl = shot_dialogue[0]
            text_lower = dl.text.lower()
            parts.append(f"{dl.character} is speaking with an animated expression.")
            if any(w in text_lower for w in ["!", "got to", "must", "swear"]):
                parts.append(f"{dl.character} appears determined and emphatic.")
            elif "?" in dl.text:
                parts.append(f"{dl.character} has a questioning, curious look.")
            elif any(w in text_lower for w in ["ok", "sure", "fine", "let"]):
                parts.append(f"{dl.character} appears agreeable, making a decision.")

    prompt = " ".join(p for p in parts if p)

    # Truncate if too long (Grok supports long prompts but be reasonable)
    if len(prompt) > 1500:
        prompt = prompt[:1497] + "..."

    return prompt


def build_all_image_prompts(screenplay: Screenplay) -> dict[str, str]:
    """Build the auto-prompt for every shot in the screenplay.

    Returns a dict keyed by shot_key ("s{scene}_sh{shot}") → prompt string.
    Used by the Step 5 "Review Image Prompts" wizard page to populate its
    tree in a single Python call.
    """
    out: dict[str, str] = {}
    for scene in screenplay.scenes:
        for si, shot in enumerate(scene.shots):
            shot_key = f"s{scene.index}_sh{si}"
            out[shot_key] = build_image_prompt(shot, scene, screenplay, shot_idx=si)
    return out


def generate_images_for_screenplay(
    screenplay: Screenplay,
    provider: ImageProvider,
    output_dir: str,
    style_reference_path: Optional[str] = None,
    defaults: Optional[GenerationDefaults] = None,
    progress_callback: Optional[Callable[[int, int, str], None]] = None,
    custom_prompts: Optional[dict[str, str]] = None,
    project_slug: Optional[str] = None,
) -> dict:
    """
    Generate images for all shots in a screenplay.

    Returns:
        Dict with shot_key -> image path mappings.
        Also includes an "_errors" key with a list of error strings.
    """
    if defaults is None:
        defaults = GenerationDefaults()

    images_dir = ensure_dir(os.path.join(output_dir, "images"))
    all_shots = []
    for scene in screenplay.scenes:
        for si, shot in enumerate(scene.shots):
            shot_key = f"s{scene.index}_sh{si}"
            all_shots.append((shot_key, shot, scene, si))

    if not all_shots:
        logger.warning("No shots found in screenplay — nothing to generate")
        return {"_errors": ["No shots found in screenplay"]}

    logger.info(f"Generating images for {len(all_shots)} shots...")
    tracker = ProgressTracker(len(all_shots), progress_callback)
    results: dict[str, str] = {}
    errors: list[str] = []

    for shot_key, shot, scene, shot_idx in all_shots:
        if custom_prompts and shot_key in custom_prompts:
            prompt = custom_prompts[shot_key]
        else:
            base_prompt = build_image_prompt(shot, scene, screenplay, shot_idx=shot_idx)
            char_refs = {}
            for char_name in shot.characters_present:
                char = screenplay.characters.get(char_name)
                if char and char.reference_image_path:
                    char_refs[char_name] = char.reference_image_path
            prompt = provider.build_prompt(base_prompt, char_refs)

        logger.info(f"[{shot_key}] Prompt: {prompt[:120]}...")

        try:
            task_id = provider.generate_image(
                prompt=prompt,
                style_reference_path=style_reference_path,
                style_adherence=defaults.creative_detailing,
                aspect_ratio=defaults.aspect_ratio,
                model=defaults.freepik_model,
                creative_detailing=defaults.creative_detailing,
                # Freepik Mystic per-model options (ignored by other providers)
                freepik_engine=defaults.freepik_engine,
                freepik_resolution=defaults.freepik_resolution,
                freepik_structure_strength=defaults.freepik_structure_strength,
                # Freepik multi-API dispatch (mystic / flux-* / seedream-* / ...)
                freepik_image_api=defaults.freepik_image_api,
                # OpenAI per-model options (ignored by other providers)
                openai_model=defaults.openai_model,
                openai_quality=defaults.openai_quality,
                openai_size=defaults.openai_size,
                openai_output_format=defaults.openai_output_format,
                openai_background=defaults.openai_background,
            )
            logger.info(f"[{shot_key}] Queued as task {task_id}")

            # Cloud APIs typically finish within 1-3 minutes; 10 minutes is
            # a generous ceiling. Local ComfyUI can be slower, but most
            # users running it know to bump this. The polling loop also
             # aborts after 5 consecutive errors so a stuck task can't
            # silently waste an hour.
            result = poll_until_complete(
                task_id,
                provider.check_image_status,
                timeout=600,
                interval=5,
                label=shot_key,
            )

            images = result.get("images", [])
            if images:
                # Include a unique hash in the filename to:
                # 1. Prevent DaVinci Resolve from detecting image sequences
                #    (sequential numbers like s0_sh0, s0_sh1 trigger sequence import)
                # 2. Prevent overwriting images from previous generations
                uid = uuid.uuid4().hex[:8]
                save_path = os.path.join(images_dir, f"{shot_key}_{uid}.png")
                # download_image may correct the extension (e.g. .png → .jpg)
                actual_path = provider.download_image(images[0], save_path)
                results[shot_key] = actual_path
                logger.info(f"[{shot_key}] Saved: {actual_path}")

                # Record the actual prompt used in the manifest
                if project_slug:
                    try:
                        from ..manifest import record_generated_image
                        char_refs_for_manifest = {}
                        for cn in shot.characters_present:
                            c = screenplay.characters.get(cn)
                            if c and c.reference_image_path:
                                char_refs_for_manifest[cn] = c.reference_image_path
                        record_generated_image(
                            project_slug=project_slug,
                            filename=os.path.basename(actual_path),
                            file_path=actual_path,
                            shot_key=shot_key,
                            prompt=prompt,  # The actual prompt sent to the provider
                            provider=type(provider).__name__,
                            provider_settings={
                                "model": defaults.freepik_model,
                                "aspect_ratio": defaults.aspect_ratio,
                            },
                            style_reference_path=style_reference_path or "",
                            character_refs=char_refs_for_manifest,
                        )
                    except Exception as e:
                        logger.warning(f"[{shot_key}] Manifest write failed: {e}")
            else:
                err = f"{shot_key}: No image returned by provider"
                logger.warning(err)
                errors.append(err)

        except Exception as e:
            err = f"{shot_key}: {e}"
            logger.error(f"Image generation failed — {err}")
            errors.append(err)

        tracker.advance(f"Generated {shot_key}")

    results["_errors"] = errors
    return results


def regenerate_single_image(
    shot_key: str,
    prompt: str,
    provider: ImageProvider,
    output_dir: str,
    style_reference_path: Optional[str] = None,
    defaults: Optional[GenerationDefaults] = None,
) -> Optional[str]:
    """Regenerate a single image by shot key."""
    if defaults is None:
        defaults = GenerationDefaults()

    images_dir = ensure_dir(os.path.join(output_dir, "images"))

    try:
        task_id = provider.generate_image(
            prompt=prompt,
            style_reference_path=style_reference_path,
            style_adherence=defaults.creative_detailing,
            aspect_ratio=defaults.aspect_ratio,
            model=defaults.freepik_model,
            creative_detailing=defaults.creative_detailing,
            # Per-model passthrough (ignored by providers that don't support these)
            freepik_engine=defaults.freepik_engine,
            freepik_resolution=defaults.freepik_resolution,
            freepik_structure_strength=defaults.freepik_structure_strength,
            freepik_image_api=defaults.freepik_image_api,
            openai_model=defaults.openai_model,
            openai_quality=defaults.openai_quality,
            openai_size=defaults.openai_size,
            openai_output_format=defaults.openai_output_format,
            openai_background=defaults.openai_background,
        )

        result = poll_until_complete(
            task_id, provider.check_image_status, timeout=600, interval=5,
            label=shot_key,
        )

        images = result.get("images", [])
        if images:
            uid = uuid.uuid4().hex[:8]
            save_path = os.path.join(images_dir, f"{shot_key}_{uid}.png")
            actual_path = provider.download_image(images[0], save_path)
            return actual_path

    except Exception as e:
        logger.error(f"Regeneration failed for {shot_key}: {e}")

    return None
