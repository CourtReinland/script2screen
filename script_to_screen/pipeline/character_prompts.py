"""Character visual prompt generation helpers.

These helpers turn parsed screenplay context into editable character visual
prompts for characters that do not have a reference image.  If an xAI/Grok API
key is available, we ask the LLM for a concise cinematic description.  If not,
we fall back to deterministic context extraction so the wizard still works
offline/local-provider-first.
"""

from __future__ import annotations

import json
import logging
import re
from typing import Optional

try:
    import requests
except ImportError:  # Keep deterministic fallback usable in minimal Resolve Python installs.
    requests = None

from ..parsing.screenplay_model import Screenplay

logger = logging.getLogger("ScriptToScreen")

_XAI_CHAT_URL = "https://api.x.ai/v1/chat/completions"
_DEFAULT_MODEL = "grok-4-fast-reasoning"


def _clean(text: str) -> str:
    return re.sub(r"\s+", " ", text or "").strip()


def _sentence_mentions(sentence: str, name: str) -> bool:
    return re.search(rf"\b{re.escape(name)}\b", sentence, flags=re.IGNORECASE) is not None


def collect_character_context(screenplay: Screenplay, character_name: str, max_chars: int = 2400) -> str:
    """Collect screenplay snippets relevant to one character."""
    name = character_name.upper()
    snippets: list[str] = []

    for scene in screenplay.scenes:
        scene_label = _clean(f"{scene.heading} {scene.location} {scene.time_of_day}")

        # Action prose often contains the best physical description.
        action = _clean(scene.action_description)
        if action:
            sentences = re.split(r"(?<=[.!?])\s+", action)
            matches = [s for s in sentences if _sentence_mentions(s, name)]
            if matches:
                snippets.append(f"Scene {scene.index} ({scene_label}) action: " + " ".join(matches[:3]))

        for shot in scene.shots:
            if name in [c.upper() for c in shot.characters_present]:
                desc = _clean(shot.description)
                if desc:
                    snippets.append(f"Shot context: {desc}")

        for dl in scene.dialogue:
            if dl.character.upper() == name:
                line_bits = []
                if dl.parenthetical:
                    line_bits.append(f"parenthetical: {dl.parenthetical}")
                if dl.text:
                    line_bits.append(f"dialogue: {dl.text[:220]}")
                if line_bits:
                    snippets.append(f"{character_name} " + "; ".join(line_bits))

    context = _clean(" | ".join(snippets))
    if len(context) > max_chars:
        context = context[:max_chars].rsplit(" ", 1)[0] + "..."
    return context


def fallback_character_prompt(screenplay: Screenplay, character_name: str) -> str:
    """Create a useful, entertaining prompt without calling an LLM."""
    context = collect_character_context(screenplay, character_name, max_chars=900)

    # Infer a loose archetype from name/context.  This is intentionally
    # conservative: no hard-coded ethnicity, age, or protected traits.
    lower = context.lower()
    traits: list[str] = []
    if any(w in lower for w in ["whisper", "secret", "shadow", "hidden"]):
        traits.append("mysterious, watchful energy")
    if any(w in lower for w in ["laugh", "smile", "joke", "grin"]):
        traits.append("playful charisma")
    if any(w in lower for w in ["angry", "shout", "tense", "fight", "gun", "knife"]):
        traits.append("dangerous intensity")
    if any(w in lower for w in ["help", "please", "afraid", "fear", "cry"]):
        traits.append("vulnerable emotional depth")
    if any(w in lower for w in ["boss", "captain", "doctor", "detective", "officer"]):
        traits.append("professional authority")
    if not traits:
        traits.append("memorable screen presence")
        traits.append("expressive, story-specific personality")

    context_sentence = f" Script clues: {context}" if context else " No explicit physical description is given in the script."
    return (
        f"{character_name}: a visually distinctive supporting character with "
        f"{', '.join(traits[:3])}. Create an entertaining cinematic look that fits the story world, "
        f"wardrobe, posture, hairstyle, expression, and small signature details that make the character instantly recognizable."
        f"{context_sentence}"
    )


def llm_character_prompt(
    screenplay: Screenplay,
    character_name: str,
    api_key: str,
    model: str = _DEFAULT_MODEL,
    timeout: int = 35,
) -> Optional[str]:
    """Ask xAI/Grok to produce a concise visual prompt.

    Returns None on any failure so callers can fall back gracefully.
    """
    if not api_key or requests is None:
        return None

    context = collect_character_context(screenplay, character_name)
    story_overview_parts = []
    for scene in screenplay.scenes[:8]:
        story_overview_parts.append(
            _clean(f"Scene {scene.index}: {scene.heading}. {scene.action_description[:260]}")
        )
    story_overview = "\n".join(p for p in story_overview_parts if p)

    system = (
        "You are a film concept artist writing compact character visual prompts for text-to-image. "
        "Preserve any physical details explicitly present in the script. If details are missing, invent the most entertaining, cinematic design that fits the story context. "
        "Do not include dialogue quotations. Do not mention that details were missing. Output one prompt only."
    )
    user = (
        f"Screenplay title: {screenplay.title}\n\n"
        f"Story context:\n{story_overview}\n\n"
        f"Character: {character_name}\n"
        f"Character-specific script evidence:\n{context or '(none)'}\n\n"
        "Write a 1-paragraph visual character prompt, 45-90 words, suitable to concatenate into a larger shot prompt."
    )

    try:
        r = requests.post(
            _XAI_CHAT_URL,
            headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
            json={
                "model": model,
                "messages": [
                    {"role": "system", "content": system},
                    {"role": "user", "content": user},
                ],
                "temperature": 0.9,
                "max_tokens": 220,
            },
            timeout=timeout,
        )
        if r.status_code != 200:
            logger.warning("Character prompt LLM failed: HTTP %s %s", r.status_code, r.text[:200])
            return None
        data = r.json()
        content = data.get("choices", [{}])[0].get("message", {}).get("content", "")
        content = _clean(content.strip().strip('"'))
        return content or None
    except Exception as exc:  # requests exceptions + malformed responses
        logger.warning("Character prompt LLM failed: %s", exc)
        return None


def generate_character_prompt(screenplay: Screenplay, character_name: str, api_key: str = "") -> str:
    """Generate one editable visual prompt for a character."""
    prompt = llm_character_prompt(screenplay, character_name, api_key=api_key)
    if prompt:
        return prompt
    return fallback_character_prompt(screenplay, character_name)


def generate_character_prompts(screenplay: Screenplay, api_key: str = "") -> dict[str, str]:
    """Generate editable visual prompts for all parsed characters."""
    prompts: dict[str, str] = {}
    for name in sorted(screenplay.characters.keys()):
        prompts[name] = generate_character_prompt(screenplay, name, api_key=api_key)
    return prompts


def prompts_json(screenplay: Screenplay, api_key: str = "") -> str:
    """Convenience wrapper for Lua bridge calls."""
    return json.dumps(generate_character_prompts(screenplay, api_key=api_key))
