"""LLM-driven screenplay parser.

Wraps any ``TextProvider`` (Grok / OpenAI / Claude) into a parser that
produces the same ``Screenplay`` dataclass as ``pdf_parser`` and
``fountain_parser``, so downstream pipeline code (image gen, video gen,
prompt review pages) stays untouched.

Why an LLM parser at all when we already have a heuristic one?

The heuristic ``pdf_parser`` reliably extracts scenes/shots/dialogue
from well-formatted Hollywood screenplays (Final Draft / Fade In
output, fountain-converted PDFs). It's brittle on:

  * Stage-directed indie scripts where shots are inferred from action.
  * Treatments / outlines where scene boundaries are paragraph breaks.
  * Rich shot-coverage notes ("the camera pushes in, then she turns…")
    that should yield multiple shots but read as one block.

The LLM parser asks the model to do that human judgment in one pass
and emit JSON the existing ``Screenplay`` constructor accepts. The
heuristic parser remains the default; users opt into LLM via the
wizard's Step-2 Parser dropdown.
"""

from __future__ import annotations

import json
import logging
from typing import Optional

from ..api.providers import TextProvider
from .screenplay_model import (
    Character,
    DialogueLine,
    Scene,
    Screenplay,
    Shot,
)

logger = logging.getLogger("ScriptToScreen")


# The contract we expect back. We're explicit about field names so the
# LLM produces JSON that maps cleanly into the dataclasses below — and
# loud about preferring "no information added" over hallucination.
SYSTEM_PROMPT = """You are a screenplay parser. Given the raw text of a screenplay, treatment, or shot list, you extract a structured representation.

Return ONE JSON object matching exactly this schema:

{
  "title": string,
  "scenes": [
    {
      "index": int,                         // 0-based, increments per scene
      "heading": string,                    // e.g. "INT. LIBRARY - NIGHT"
      "location_type": "INT" | "EXT",
      "location": string,                   // e.g. "LIBRARY"
      "time_of_day": "DAY"|"NIGHT"|"DAWN"|"DUSK"|"MORNING"|"EVENING"|"",
      "action_description": string,         // 1-3 sentences, the scene's action gist
      "shots": [
        {
          "shot_type": "WS"|"MS"|"CU"|"ECU"|"LS"|"OTS"|"POV"|"UNSPECIFIED",
          "description": string,            // what the shot shows + any motion
          "characters_present": [string]    // uppercase names, no titles
        }
      ],
      "dialogue": [
        {
          "character": string,              // uppercase
          "text": string,                   // the spoken line
          "parenthetical": string|null,     // (whispering), (V.O.), etc.
          "shot_index": int                 // 0-based index INTO THIS SCENE'S shots[]
        }
      ]
    }
  ],
  "characters": {
    "<NAME>": {
      "dialogue_count": int                 // total lines across all scenes
    }
  }
}

Rules:
1. If the script doesn't specify shot framing, infer the most reasonable type (CU for emotional close moments, WS for establishing, MS for general dialogue) and use that — do NOT default everything to UNSPECIFIED.
2. Split a continuous action paragraph into multiple shots ONLY when the script implies a camera change (cut, "we see", "the camera moves to", a new beat). Otherwise keep one shot per action beat.
3. Every dialogue line must reference a valid shot in its scene by integer index. If you can't tell which shot a line belongs to, attach it to the most recent action beat (highest shot_index so far).
4. Character names in characters_present and dialogue.character must match keys in the characters map exactly (case-sensitive uppercase).
5. Do not invent action that isn't in the script. Brevity over embellishment.
6. Return ONLY the JSON object, no markdown fences, no commentary."""


def _coerce_shot(d: dict, scene_index: int) -> Shot:
    """Build a Shot from one LLM-produced dict, defending against missing keys."""
    return Shot(
        shot_type=str(d.get("shot_type") or "UNSPECIFIED").upper(),
        description=str(d.get("description") or "").strip(),
        scene_index=scene_index,
        characters_present=[
            str(c).strip().upper()
            for c in (d.get("characters_present") or [])
            if c and str(c).strip()
        ],
        origin="llm",
    )


def _coerce_dialogue(d: dict, scene_index: int) -> Optional[DialogueLine]:
    text = (d.get("text") or "").strip()
    if not text:
        return None
    return DialogueLine(
        character=str(d.get("character") or "").strip().upper(),
        text=text,
        parenthetical=(d.get("parenthetical") or None) or None,
        scene_index=scene_index,
        shot_index=int(d.get("shot_index") or 0),
    )


def _coerce_scene(d: dict, idx: int) -> Scene:
    scene = Scene(
        index=int(d.get("index", idx)),
        heading=str(d.get("heading") or f"SCENE {idx + 1}"),
        location_type=str(d.get("location_type") or "INT").upper(),
        location=str(d.get("location") or "").strip(),
        time_of_day=str(d.get("time_of_day") or "").upper(),
        action_description=str(d.get("action_description") or "").strip(),
    )
    for shot_dict in d.get("shots") or []:
        scene.shots.append(_coerce_shot(shot_dict, scene.index))
    # If the LLM produced no shots, synthesize one from the action so
    # downstream pipeline (which iterates scene.shots) doesn't skip the
    # scene entirely.
    if not scene.shots:
        scene.shots.append(
            Shot(
                shot_type="UNSPECIFIED",
                description=scene.action_description or scene.heading,
                scene_index=scene.index,
                origin="llm-fallback",
            )
        )
    for line_dict in d.get("dialogue") or []:
        line = _coerce_dialogue(line_dict, scene.index)
        if line is None:
            continue
        # Clamp shot_index into [0, len(shots)-1] so a hallucinated index
        # doesn't break the manifest later.
        line.shot_index = max(0, min(line.shot_index, len(scene.shots) - 1))
        scene.dialogue.append(line)
    return scene


def parse_with_llm(
    raw_text: str,
    text_provider: TextProvider,
    *,
    title: str = "Untitled",
    model: Optional[str] = None,
    max_tokens: int = 8192,
) -> Screenplay:
    """Parse a screenplay's raw text into a ``Screenplay`` via an LLM.

    Args:
        raw_text: The full screenplay text (already extracted from PDF
            via pdfplumber, or read from a fountain/text file).
        text_provider: Any registered TextProvider — Grok, OpenAI,
            Claude. The user picks via the wizard's Parser dropdown.
        title: Optional fallback title if the LLM doesn't infer one.
        model: Optional override of the provider's default chat model.
        max_tokens: Generous default — long screenplays need headroom.

    Returns:
        A ``Screenplay`` populated from the LLM's structured response.

    Raises:
        RuntimeError if the LLM doesn't return parseable JSON or the
        JSON doesn't match the contract enough to build a screenplay.
    """
    user_prompt = (
        "Here is the screenplay text. Parse it according to the schema "
        "in the system message and return ONLY the JSON.\n\n"
        "------ SCREENPLAY START ------\n"
        f"{raw_text}\n"
        "------ SCREENPLAY END ------"
    )

    logger.info(
        f"[LLMParser] Sending {len(raw_text)} chars of script to "
        f"{type(text_provider).__name__}"
    )

    raw = text_provider.generate_text(
        system_prompt=SYSTEM_PROMPT,
        user_prompt=user_prompt,
        max_tokens=max_tokens,
        temperature=0.3,             # low temp — we want deterministic structure
        response_format="json",
        model=model,
    )

    # Some models still wrap output in ```json fences despite the "no
    # markdown" instruction. Strip defensively.
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
            f"LLM parser returned non-JSON ({e}). First 500 chars: "
            f"{cleaned[:500]!r}"
        ) from e

    screenplay = Screenplay(title=str(data.get("title") or title).strip() or title)

    for i, scene_dict in enumerate(data.get("scenes") or []):
        screenplay.scenes.append(_coerce_scene(scene_dict, i))

    chars_block = data.get("characters") or {}
    if isinstance(chars_block, dict):
        for raw_name, info in chars_block.items():
            name = str(raw_name).strip().upper()
            if not name:
                continue
            count = (
                int(info.get("dialogue_count", 0))
                if isinstance(info, dict)
                else 0
            )
            screenplay.characters[name] = Character(
                name=name, dialogue_count=count
            )

    # Backfill dialogue_count from actual scenes if the LLM under-counted
    # — saves the wizard from showing "0 lines" for speakers who clearly
    # have lines.
    actual = {}
    for scene in screenplay.scenes:
        for line in scene.dialogue:
            actual[line.character] = actual.get(line.character, 0) + 1
    for name, count in actual.items():
        if name not in screenplay.characters:
            screenplay.characters[name] = Character(name=name, dialogue_count=count)
        elif screenplay.characters[name].dialogue_count < count:
            screenplay.characters[name].dialogue_count = count

    logger.info(
        f"[LLMParser] Parsed: {len(screenplay.scenes)} scenes, "
        f"{screenplay.total_shots} shots, "
        f"{screenplay.total_dialogue_lines} dialogue lines, "
        f"{len(screenplay.characters)} characters"
    )
    return screenplay
