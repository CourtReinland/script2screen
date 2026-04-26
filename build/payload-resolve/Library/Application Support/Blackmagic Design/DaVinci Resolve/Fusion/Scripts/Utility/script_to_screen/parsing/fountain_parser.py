"""Parse Fountain-format (.fountain) screenplays."""

import re
from typing import Optional

from .screenplay_model import (
    Character, DialogueLine, Scene, Screenplay, Shot,
)

SCENE_HEADING_RE = re.compile(
    r'^(?:\.(?!\.)|(?:INT|EXT|EST|INT\./EXT|INT/EXT|I/E)[\s.])',
    re.IGNORECASE,
)
SHOT_TYPE_RE = re.compile(r'^(WS|MS|CU|ECU|LS|OTS|POV)\b[:\s.-]*(.*)', re.IGNORECASE)
TRANSITION_RE = re.compile(r'^[A-Z\s]+TO:$')
FORCED_TRANSITION_RE = re.compile(r'^>\s*(.+)')
PARENTHETICAL_RE = re.compile(r'^\(.*\)$')
BONEYARD_RE = re.compile(r'/\*.*?\*/', re.DOTALL)
NOTE_RE = re.compile(r'\[\[.*?\]\]', re.DOTALL)
EMPHASIS_RE = re.compile(r'[*_]+')


def _clean_text(text: str) -> str:
    """Remove Fountain markup from text."""
    text = BONEYARD_RE.sub('', text)
    text = NOTE_RE.sub('', text)
    text = EMPHASIS_RE.sub('', text)
    return text.strip()


def _is_character_line(line: str, prev_blank: bool) -> bool:
    """Check if a line is a character name (Fountain rules)."""
    if not prev_blank:
        return False
    # Forced character
    if line.startswith("@"):
        return True
    # Must be ALL CAPS, no lowercase
    stripped = re.sub(r'\s*\(.*?\)\s*', '', line).strip()
    if not stripped:
        return False
    alpha = re.sub(r'[^a-zA-Z]', '', stripped)
    if not alpha:
        return False
    if alpha != alpha.upper():
        return False
    # Must not be a scene heading or transition
    if SCENE_HEADING_RE.match(line):
        return False
    if TRANSITION_RE.match(line):
        return False
    return True


def _parse_scene_heading(text: str) -> tuple[str, str, str]:
    """Parse scene heading into (type, location, time_of_day)."""
    # Remove forced scene heading marker
    if text.startswith("."):
        text = text[1:].strip()

    # Extract INT/EXT
    match = re.match(r'(INT|EXT|EST|INT\./EXT|INT/EXT|I/E)[\s./]+(.*)', text, re.IGNORECASE)
    if not match:
        return ("INT", text.strip(), "DAY")

    loc_type = match.group(1).upper()
    remainder = match.group(2).strip()

    parts = remainder.rsplit(" - ", 1)
    location = parts[0].strip()
    time_of_day = parts[1].strip() if len(parts) > 1 else "DAY"

    return (loc_type, location, time_of_day)


def parse_fountain(file_path: str) -> Screenplay:
    """Parse a .fountain file into a Screenplay model."""
    with open(file_path, "r", encoding="utf-8") as f:
        raw_text = f.read()

    raw_text = _clean_text(raw_text)
    lines = raw_text.split("\n")

    screenplay = Screenplay()
    characters: dict[str, Character] = {}

    current_scene: Optional[Scene] = None
    current_character: Optional[str] = None
    current_shot_idx = -1
    scene_index = 0
    prev_blank = True
    in_dialogue = False
    action_buffer: list[str] = []

    # Title page parsing
    title_done = False
    i = 0
    while i < len(lines):
        line = lines[i]
        if not title_done:
            if ":" in line and i < 20:
                key, _, value = line.partition(":")
                key = key.strip().lower()
                if key == "title":
                    screenplay.title = value.strip()
                i += 1
                continue
            elif line.strip() == "" and i < 5:
                i += 1
                continue
            else:
                title_done = True
        break

    for line in lines[i:]:
        stripped = line.strip()

        if not stripped:
            # Flush action buffer
            if action_buffer and current_scene:
                current_scene.action_description += " ".join(action_buffer) + "\n"
                action_buffer = []
            prev_blank = True
            in_dialogue = False
            current_character = None
            continue

        # Scene heading
        if SCENE_HEADING_RE.match(stripped):
            if action_buffer and current_scene:
                current_scene.action_description += " ".join(action_buffer) + "\n"
                action_buffer = []

            loc_type, location, tod = _parse_scene_heading(stripped)
            current_scene = Scene(
                index=scene_index,
                heading=stripped,
                location_type=loc_type,
                location=location,
                time_of_day=tod,
            )
            screenplay.scenes.append(current_scene)
            scene_index += 1
            current_shot_idx = -1
            current_character = None
            in_dialogue = False
            prev_blank = False
            continue

        # Shot type in action
        shot_match = SHOT_TYPE_RE.match(stripped)
        if shot_match and not in_dialogue:
            if action_buffer and current_scene:
                current_scene.action_description += " ".join(action_buffer) + "\n"
                action_buffer = []

            shot_type = shot_match.group(1).upper()
            shot_desc = shot_match.group(2).strip()

            if current_scene:
                current_shot_idx = len(current_scene.shots)
                shot = Shot(
                    shot_type=shot_type,
                    description=shot_desc,
                    scene_index=current_scene.index,
                )
                current_scene.shots.append(shot)
            prev_blank = False
            continue

        # Transition
        if TRANSITION_RE.match(stripped) or FORCED_TRANSITION_RE.match(stripped):
            if action_buffer and current_scene:
                current_scene.action_description += " ".join(action_buffer) + "\n"
                action_buffer = []
            prev_blank = False
            continue

        # Character name
        if _is_character_line(stripped, prev_blank):
            if action_buffer and current_scene:
                current_scene.action_description += " ".join(action_buffer) + "\n"
                action_buffer = []

            char_name = stripped.lstrip("@")
            char_name = re.sub(r'\s*\(.*?\)\s*', '', char_name).strip()
            current_character = char_name
            in_dialogue = True

            if char_name not in characters:
                characters[char_name] = Character(name=char_name)

            prev_blank = False
            continue

        # Parenthetical
        if in_dialogue and PARENTHETICAL_RE.match(stripped):
            prev_blank = False
            continue

        # Dialogue
        if in_dialogue and current_character:
            if current_scene:
                dl = DialogueLine(
                    character=current_character,
                    text=stripped,
                    scene_index=current_scene.index,
                    shot_index=max(0, current_shot_idx),
                )
                current_scene.dialogue.append(dl)
                if current_character in characters:
                    characters[current_character].dialogue_count += 1
            prev_blank = False
            continue

        # Action (everything else)
        action_buffer.append(stripped)
        in_dialogue = False
        current_character = None
        prev_blank = False

    # Flush remaining action
    if action_buffer and current_scene:
        current_scene.action_description += " ".join(action_buffer) + "\n"

    # Create default shots for scenes without explicit shots
    for scene in screenplay.scenes:
        if not scene.shots:
            shot = Shot(
                shot_type="UNSPECIFIED",
                description=scene.action_description.strip(),
                scene_index=scene.index,
            )
            scene.shots.append(shot)
            for dl in scene.dialogue:
                dl.shot_index = 0

    # Detect characters present in shots
    for scene in screenplay.scenes:
        for shot in scene.shots:
            for char_name in characters:
                if char_name.upper() in shot.description.upper():
                    shot.characters_present.append(char_name)
            for dl in scene.dialogue:
                if dl.shot_index == scene.shots.index(shot):
                    if dl.character not in shot.characters_present:
                        shot.characters_present.append(dl.character)

    screenplay.characters = characters
    return screenplay
