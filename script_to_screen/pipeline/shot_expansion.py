"""LLM-based shot expansion — SORA-style coverage enhancement.

Given a parsed screenplay, this module sends each scene's shot list to a
text LLM (TextProvider) and asks for additional cinematic shots (reaction
shots, inserts, cutaways, alternate angles). The resulting expanded
screenplay preserves all original shots and remaps dialogue indices to
point at the correct shots in the new order.
"""

from __future__ import annotations

import copy
import json
import logging
import re
from typing import Callable, Optional

from ..api.providers import TextProvider
from ..parsing.screenplay_model import Screenplay, Scene, Shot, DialogueLine

logger = logging.getLogger("ScriptToScreen")


# Max shots per scene after expansion (safety cap)
MAX_SHOTS_PER_SCENE = 20

# Valid shot types we accept from the LLM
VALID_SHOT_TYPES = {"WS", "MS", "CU", "ECU", "LS", "OTS", "POV"}


SYSTEM_PROMPT = """You are an expert film editor and cinematographer working on \
a screenplay-to-video pipeline. Your job is to add supplementary cinematic shots \
to an existing scene to improve visual coverage and storytelling flow.

Rules:
1. NEVER drop or alter original shots — include every one of them in your output with origin="original".
2. Add new shots with origin="expanded": reaction shots, inserts (close-ups of objects/hands/eyes), cutaways, alternate angles, establishing shots, POV, over-the-shoulder.
3. Return STRICT JSON only — no prose, no markdown, no comments.
4. Use only these shot_type values: WS, MS, CU, ECU, LS, OTS, POV.
5. Dialogue lines MUST stay associated with an original shot. When you insert a new shot between dialogue beats, do not attach dialogue to it.
6. Keep descriptions concise (one sentence, cinematic language).
7. Stay faithful to the scene's characters, location, and tone.
"""


STYLE_GUIDANCE = {
    "conservative": (
        "Style: CONSERVATIVE. Only add reaction shots and inserts. "
        "Keep expansion minimal — only add shots that enhance emotional beats."
    ),
    "standard": (
        "Style: STANDARD. Add reaction shots, inserts, and 1-2 alternate angles "
        "per key dialogue beat. Favor coverage that feels like a typical dramatic scene."
    ),
    "aggressive": (
        "Style: AGGRESSIVE. Provide full coverage: establishing shot, reversals, "
        "POV, over-the-shoulder, cutaways, and inserts. Feel free to add many shots."
    ),
}


def _build_user_prompt(
    scene: Scene,
    extra_shots_target: int,
    style: str,
) -> str:
    """Build the per-scene user prompt sent to the LLM."""
    style_text = STYLE_GUIDANCE.get(style, STYLE_GUIDANCE["standard"])

    # Serialize the original shots with any dialogue attached to them
    shots_payload = []
    for idx, shot in enumerate(scene.shots):
        dlg_lines = [
            {"character": dl.character, "text": dl.text[:200]}
            for dl in scene.dialogue
            if dl.shot_index == idx
        ]
        shots_payload.append({
            "index": idx,
            "shot_type": shot.shot_type,
            "description": shot.description or "",
            "characters_present": shot.characters_present or [],
            "dialogue": dlg_lines,
        })

    chars = sorted({
        *(c for shot in scene.shots for c in shot.characters_present),
        *(dl.character for dl in scene.dialogue),
    })

    schema_example = """{
  "shots": [
    {
      "origin": "original",
      "original_index": 0,
      "shot_type": "WS",
      "description": "Wide establishing shot of the library at night.",
      "characters_present": ["AIDEN", "ALIYAH"],
      "attach_dialogue_from_original_shot": 0
    },
    {
      "origin": "expanded",
      "original_index": null,
      "shot_type": "CU",
      "description": "Close-up on the dusty book cover glowing faintly.",
      "characters_present": [],
      "attach_dialogue_from_original_shot": null
    }
  ]
}"""

    return (
        f"{style_text}\n\n"
        f"Add approximately {extra_shots_target} additional shots to this scene.\n\n"
        f"Scene heading: {scene.heading}\n"
        f"Location: {scene.location_type}. {scene.location}\n"
        f"Time of day: {scene.time_of_day}\n"
        f"Characters in scene: {', '.join(chars) if chars else '(none)'}\n"
        f"Scene action: {scene.action_description[:500]}\n\n"
        f"Original shots (in order):\n{json.dumps(shots_payload, indent=2)}\n\n"
        f"Return JSON with this exact shape (no markdown, no prose):\n"
        f"{schema_example}\n\n"
        f"Remember: keep ALL original shots in your output with origin='original' "
        f"and their original_index, add new ones with origin='expanded'. "
        f"Max total shots after expansion: {MAX_SHOTS_PER_SCENE}."
    )


def _strip_json_fences(text: str) -> str:
    """Remove ```json ... ``` code fences if the LLM added them."""
    text = text.strip()
    if text.startswith("```"):
        text = re.sub(r"^```(?:json)?\s*", "", text)
        text = re.sub(r"\s*```\s*$", "", text)
    return text.strip()


def _parse_llm_response(response_text: str) -> list[dict]:
    """Parse the LLM response into a list of shot dicts. Raises on failure."""
    cleaned = _strip_json_fences(response_text)
    data = json.loads(cleaned)
    if not isinstance(data, dict) or "shots" not in data:
        raise ValueError("Response missing 'shots' array")
    shots = data["shots"]
    if not isinstance(shots, list):
        raise ValueError("'shots' must be a list")
    return shots


def _expand_scene(
    scene: Scene,
    provider: TextProvider,
    extra_shots_target: int,
    style: str,
) -> Scene:
    """Expand a single scene. Returns a new Scene with expanded shots.

    On any failure, logs and returns the original scene unchanged.
    """
    # Skip scenes with no shots at all
    if not scene.shots:
        return scene

    # Skip if extra_shots_target is 0
    if extra_shots_target <= 0:
        return scene

    user_prompt = _build_user_prompt(scene, extra_shots_target, style)

    try:
        response = provider.generate_text(
            system_prompt=SYSTEM_PROMPT,
            user_prompt=user_prompt,
            max_tokens=4096,
            temperature=0.8,
            response_format="json",
        )
    except Exception as e:
        logger.error(f"[expand] Scene {scene.index}: LLM call failed: {e}")
        return scene

    try:
        shot_dicts = _parse_llm_response(response)
    except (json.JSONDecodeError, ValueError) as e:
        logger.error(f"[expand] Scene {scene.index}: could not parse LLM response: {e}")
        logger.debug(f"[expand] Raw response: {response[:1000]}")
        return scene

    # Validate: every original shot must appear with origin="original" + correct original_index
    seen_originals: set[int] = set()
    validated: list[tuple[Shot, Optional[int]]] = []  # (shot, dialogue_attach_to_orig_idx)

    for entry in shot_dicts:
        if not isinstance(entry, dict):
            continue

        origin = entry.get("origin", "expanded")
        if origin not in ("original", "expanded"):
            origin = "expanded"

        shot_type = (entry.get("shot_type") or "UNSPECIFIED").upper()
        if shot_type not in VALID_SHOT_TYPES:
            shot_type = "UNSPECIFIED"

        description = str(entry.get("description") or "").strip()[:500]
        chars_present = entry.get("characters_present") or []
        if not isinstance(chars_present, list):
            chars_present = []
        chars_present = [str(c).strip() for c in chars_present if c]

        attach = entry.get("attach_dialogue_from_original_shot")
        if attach is not None:
            try:
                attach = int(attach)
                if attach < 0 or attach >= len(scene.shots):
                    attach = None
            except (ValueError, TypeError):
                attach = None

        if origin == "original":
            orig_idx = entry.get("original_index")
            try:
                orig_idx = int(orig_idx) if orig_idx is not None else None
            except (ValueError, TypeError):
                orig_idx = None
            if orig_idx is None or orig_idx < 0 or orig_idx >= len(scene.shots):
                logger.warning(f"[expand] Scene {scene.index}: invalid original_index {orig_idx}, skipping")
                continue
            seen_originals.add(orig_idx)
            # Preserve the original shot's description if LLM didn't provide a richer one
            orig_shot = scene.shots[orig_idx]
            new_shot = Shot(
                shot_type=orig_shot.shot_type,  # keep original type
                description=orig_shot.description or description,
                scene_index=scene.index,
                characters_present=list(orig_shot.characters_present) or chars_present,
                origin="original",
            )
            validated.append((new_shot, orig_idx))
        else:
            if not description:
                continue
            new_shot = Shot(
                shot_type=shot_type,
                description=description,
                scene_index=scene.index,
                characters_present=chars_present,
                origin="expanded",
            )
            validated.append((new_shot, attach))

    # Safety check: all originals must be present
    missing_originals = set(range(len(scene.shots))) - seen_originals
    if missing_originals:
        logger.warning(
            f"[expand] Scene {scene.index}: LLM dropped originals {sorted(missing_originals)}. "
            f"Appending them to preserve script integrity."
        )
        for orig_idx in sorted(missing_originals):
            orig_shot = scene.shots[orig_idx]
            validated.append((
                Shot(
                    shot_type=orig_shot.shot_type,
                    description=orig_shot.description,
                    scene_index=scene.index,
                    characters_present=list(orig_shot.characters_present),
                    origin="original",
                ),
                orig_idx,
            ))

    # Cap total shots
    if len(validated) > MAX_SHOTS_PER_SCENE:
        logger.warning(
            f"[expand] Scene {scene.index}: LLM returned {len(validated)} shots, "
            f"capping at {MAX_SHOTS_PER_SCENE}"
        )
        # Keep all originals; drop excess expanded shots
        kept: list[tuple[Shot, Optional[int]]] = []
        originals = [(s, a) for s, a in validated if s.origin == "original"]
        expanded = [(s, a) for s, a in validated if s.origin == "expanded"]
        kept.extend(originals)
        room = MAX_SHOTS_PER_SCENE - len(kept)
        if room > 0:
            kept.extend(expanded[:room])
        # Preserve order by rebuilding from the original validated order
        kept_set = {id(s) for s, _ in kept}
        validated = [(s, a) for s, a in validated if id(s) in kept_set]

    # Build new scene
    new_scene = Scene(
        index=scene.index,
        heading=scene.heading,
        location_type=scene.location_type,
        location=scene.location,
        time_of_day=scene.time_of_day,
        action_description=scene.action_description,
        shots=[s for s, _ in validated],
    )

    # Remap dialogue: for each DialogueLine in the original scene, find
    # the NEW shot index where it should attach. Default: the first
    # original shot whose old index matches the dialogue's old shot_index.
    old_idx_to_new_idx: dict[int, int] = {}
    for new_idx, (shot, attach_to_orig) in enumerate(validated):
        if shot.origin == "original" and attach_to_orig is not None:
            # This shot IS original attach_to_orig (validated above)
            old_idx_to_new_idx.setdefault(attach_to_orig, new_idx)

    # Fallback: if any old shot doesn't have a mapping (shouldn't happen after safety check), map to 0
    for old_idx in range(len(scene.shots)):
        if old_idx not in old_idx_to_new_idx:
            old_idx_to_new_idx[old_idx] = 0

    for dl in scene.dialogue:
        new_dl = DialogueLine(
            character=dl.character,
            text=dl.text,
            parenthetical=dl.parenthetical,
            scene_index=scene.index,
            shot_index=old_idx_to_new_idx.get(dl.shot_index, 0),
        )
        new_scene.dialogue.append(new_dl)

    orig_count = len(scene.shots)
    new_count = len(new_scene.shots)
    expanded_count = sum(1 for s in new_scene.shots if s.origin == "expanded")
    logger.info(
        f"[expand] Scene {scene.index}: {orig_count} → {new_count} shots "
        f"(+{expanded_count} expanded)"
    )
    return new_scene


def expand_screenplay_shots(
    screenplay: Screenplay,
    provider: TextProvider,
    expansion_ratio: float = 0.5,
    style: str = "standard",
    progress_callback: Optional[Callable[[int, int, str], None]] = None,
) -> Screenplay:
    """Return a NEW Screenplay with LLM-expanded shots.

    Args:
        screenplay: The parsed input screenplay (not mutated).
        provider: A TextProvider (e.g., GrokTextProvider).
        expansion_ratio: Target ratio of extra shots per scene
            (0.0 = no change, 0.5 = +50%, 2.0 = triple).
        style: "conservative", "standard", or "aggressive".
        progress_callback: Optional callback(current, total, message).

    Returns:
        A new Screenplay instance with expanded shots. On per-scene
        failures, the original scene is preserved unchanged.
    """
    if style not in STYLE_GUIDANCE:
        logger.warning(f"[expand] Unknown style '{style}', defaulting to 'standard'")
        style = "standard"

    new_screenplay = Screenplay(
        title=screenplay.title,
        raw_pages=list(screenplay.raw_pages),
    )
    # Deep copy characters so we don't mutate the input
    new_screenplay.characters = copy.deepcopy(screenplay.characters)

    total_scenes = len(screenplay.scenes)
    for scene_idx, scene in enumerate(screenplay.scenes):
        if progress_callback:
            progress_callback(scene_idx, total_scenes, f"Expanding scene {scene_idx + 1}/{total_scenes}")

        orig_shot_count = len(scene.shots)
        extra_target = max(1, round(orig_shot_count * expansion_ratio)) if orig_shot_count > 0 else 0

        expanded_scene = _expand_scene(scene, provider, extra_target, style)
        new_screenplay.scenes.append(expanded_scene)

    if progress_callback:
        progress_callback(total_scenes, total_scenes, "Shot expansion complete")

    return new_screenplay
