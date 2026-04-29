"""LLM-driven prompt refinement with on-disk caching across runs.

Turn a parsed ``Screenplay`` into TWO sets of per-shot prompts:

  * ``image_prompts`` — describe a single FROZEN INSTANT. Composition,
    lighting, expression, pose, framing. NO camera-motion verbs (pan,
    push-in, dolly, zoom, follow). Still images don't move; including
    motion language pollutes the diffusion prompt and produces blurred
    or doubled subjects.

  * ``motion_prompts`` — describe the MOTION the still should perform.
    Camera move, character movement, environmental dynamics, dialogue
    delivery beats. Assumes the still already exists (we feed it to
    Seedance / Kling as the start frame).

The deterministic ``build_image_prompt`` / ``build_motion_prompt``
helpers in image_gen.py / video_gen.py do their best with regex +
heuristics, but they leak motion words into image prompts and miss
chances to enrich video prompts with implied beats. An LLM doing this
in one pass is dramatically better, especially on indie scripts where
shot framing was inferred rather than explicit.

This module is opt-in — the wizard's Step-4 "Refine prompts with LLM"
toggle calls ``refine_screenplay_prompts`` and stashes the output dict
into ``custom_prompts`` for the image and video gen pipelines.
"""

from __future__ import annotations

import json
import logging
import os
from typing import Optional

from ..api.providers import TextProvider
from ..parsing.screenplay_model import Screenplay

logger = logging.getLogger("ScriptToScreen")


SYSTEM_PROMPT = """You refine screenplay shots into two complementary AI-generation prompts: one for a STILL IMAGE (the start frame) and one for a VIDEO (the motion that follows from that frame).

Each shot is given to you with its scene heading, scene action, dialogue lines, characters present, and inferred shot framing. Return ONE JSON object:

{
  "shots": {
    "<shot_key>": {
      "image_prompt": string,    // describes a frozen instant
      "motion_prompt": string    // describes the motion / dialogue delivery
    },
    ...
  }
}

Hard rules:

IMAGE prompt ("the still")
  * Describe what the FRAME LOOKS LIKE at one instant: composition, framing, lighting, color palette, expression, pose, environment, props.
  * NO camera-motion verbs: never "pans across", "pushes in", "dollies", "zooms", "follows", "tracks", "rotates around". A still doesn't move.
  * NO "the camera <verb>" phrasing. Use noun-only framing language: "wide shot of …", "close-up of …".
  * NO dialogue lines in quotes. They cause image generators to render speech bubbles or text overlay.
  * Length: 1-3 sentences, ~40-120 words. Concrete sensory detail beats abstract description.

MOTION prompt ("the video")
  * Describe what HAPPENS over the next few seconds: camera move, character action, lip motion if speaking, ambient motion (curtains, wind, flickering candles).
  * INCLUDE camera-motion verbs here — that's the whole point.
  * INCLUDE the dialogue text in quotes (the video model uses it for lip-sync timing): e.g. ALIYAH whispers, "Why are we doing this?".
  * Mention environmental motion that would naturally exist in the scene (a crackling fire, drifting dust, breathing).
  * Length: 1-2 sentences, ~30-80 words. Specific verbs over generic "subtle movement".

Both prompts:
  * No proper-noun characters that aren't in characters_present.
  * No racial/age/body descriptors not present in the scene context.
  * No "high quality, 4k, masterpiece" boilerplate.

Return ONLY the JSON object, no markdown fences, no commentary."""


def _shot_key(scene_index: int, shot_index: int) -> str:
    return f"s{scene_index}_sh{shot_index}"


def _build_user_payload(screenplay: Screenplay) -> str:
    """Compact JSON describing every shot the LLM needs to refine."""
    shots_payload = []
    for scene in screenplay.scenes:
        for si, shot in enumerate(scene.shots):
            sk = _shot_key(scene.index, si)
            dlg = [
                {
                    "character": dl.character,
                    "text": dl.text,
                    "parenthetical": dl.parenthetical or "",
                }
                for dl in scene.dialogue
                if dl.shot_index == si
            ]
            shots_payload.append({
                "shot_key": sk,
                "scene_heading": scene.heading,
                "location": scene.location,
                "location_type": scene.location_type,
                "time_of_day": scene.time_of_day,
                "scene_action": scene.action_description,
                "shot_type": shot.shot_type,
                "shot_description": shot.description,
                "characters_present": shot.characters_present,
                "dialogue": dlg,
            })
    return json.dumps({"shots": shots_payload}, indent=2)


def refine_screenplay_prompts(
    screenplay: Screenplay,
    text_provider: TextProvider,
    *,
    model: Optional[str] = None,
    max_tokens: int = 8192,
) -> dict:
    """Refine every shot's prompts via LLM. Returns a dict the caller
    can plug straight into ``custom_prompts`` of the image and video
    pipelines:

    ::

        {
          "image_prompts":  {shot_key: prompt_text, ...},
          "motion_prompts": {shot_key: prompt_text, ...},
        }

    A failure (LLM timeout / unparseable JSON) raises so the wizard's
    Step 4 can surface it cleanly rather than silently falling back.
    """
    user = (
        "Refine prompts for these shots. Return JSON per the system schema.\n\n"
        + _build_user_payload(screenplay)
    )

    logger.info(
        f"[PromptRefiner] {screenplay.total_shots} shots → "
        f"{type(text_provider).__name__}"
    )

    raw = text_provider.generate_text(
        system_prompt=SYSTEM_PROMPT,
        user_prompt=user,
        max_tokens=max_tokens,
        temperature=0.4,
        response_format="json",
        model=model,
    )

    cleaned = raw.strip()
    if cleaned.startswith("```"):
        cleaned = cleaned.split("\n", 1)[-1]
        if cleaned.endswith("```"):
            cleaned = cleaned.rsplit("\n", 1)[0]
    if cleaned.startswith("json\n"):
        cleaned = cleaned[5:]

    try:
        data = json.loads(cleaned)
    except json.JSONDecodeError as e:
        raise RuntimeError(
            f"Prompt refiner returned non-JSON ({e}). First 500 chars: "
            f"{cleaned[:500]!r}"
        ) from e

    image_prompts: dict[str, str] = {}
    motion_prompts: dict[str, str] = {}
    for sk, entry in (data.get("shots") or {}).items():
        if not isinstance(entry, dict):
            continue
        ip = (entry.get("image_prompt") or "").strip()
        mp = (entry.get("motion_prompt") or "").strip()
        if ip:
            image_prompts[sk] = ip
        if mp:
            motion_prompts[sk] = mp

    logger.info(
        f"[PromptRefiner] Got {len(image_prompts)} image / "
        f"{len(motion_prompts)} motion prompts"
    )

    if not image_prompts and not motion_prompts:
        raise RuntimeError(
            "Prompt refiner returned an empty 'shots' map — "
            f"raw response: {cleaned[:500]!r}"
        )

    return {
        "image_prompts": image_prompts,
        "motion_prompts": motion_prompts,
    }


# ----------------------------------------------------------------------
# Cached helper used by the wizard's image- and video-gen handlers
# ----------------------------------------------------------------------

CACHE_FILENAME = "refined_prompts.json"


def get_refined_prompts(
    screenplay: Screenplay,
    output_dir: str,
    *,
    text_provider: Optional[TextProvider] = None,
    use_cache: bool = True,
) -> dict:
    """Return refined prompts, reading the cache file when present.

    The wizard runs image gen first; that pass calls this helper to do
    the (cost-incurring) LLM refinement and writes
    ``output_dir/refined_prompts.json``. The subsequent video-gen pass
    on the same project reads that file instead of paying again, so
    image and motion prompts stay consistent within a single batch.

    Cache invalidation: this helper checks whether the cached file's
    shot keys match the current screenplay; if they don't (the user
    re-parsed and shots shifted) the cache is rebuilt. The wizard can
    also force a fresh pass by passing ``use_cache=False``.

    A missing ``text_provider`` is fatal only when no usable cache
    exists — the wizard can therefore call this from the video-gen
    handler without re-resolving an LLM key, as long as image gen
    populated the cache earlier in the session.
    """
    cache_path = os.path.join(output_dir, CACHE_FILENAME)

    expected_keys = {
        f"s{scene.index}_sh{si}"
        for scene in screenplay.scenes
        for si in range(len(scene.shots))
    }

    if use_cache and os.path.isfile(cache_path):
        try:
            with open(cache_path, "r") as f:
                cached = json.load(f)
            cached_keys = set(cached.get("image_prompts", {}).keys()) | set(
                cached.get("motion_prompts", {}).keys()
            )
            # If at least 80% of expected shots are covered, treat as
            # valid — small drift is fine, a wholly different parse means
            # we re-refine.
            if expected_keys and len(cached_keys & expected_keys) >= 0.8 * len(
                expected_keys
            ):
                logger.info(
                    f"[PromptRefiner] reusing cached prompts at {cache_path}"
                )
                return cached
            logger.info(
                f"[PromptRefiner] cache stale "
                f"({len(cached_keys & expected_keys)}/{len(expected_keys)} keys match) — rebuilding"
            )
        except (OSError, ValueError) as e:
            logger.info(f"[PromptRefiner] cache unreadable ({e}) — rebuilding")

    if text_provider is None:
        raise RuntimeError(
            "Prompt refinement requested but no LLM provider configured "
            "and no usable cache at " + cache_path
        )

    refined = refine_screenplay_prompts(screenplay, text_provider)

    try:
        os.makedirs(output_dir, exist_ok=True)
        with open(cache_path, "w") as f:
            json.dump(refined, f, indent=2)
        logger.info(f"[PromptRefiner] wrote cache to {cache_path}")
    except OSError as e:
        logger.warning(f"[PromptRefiner] could not write cache: {e}")

    return refined
