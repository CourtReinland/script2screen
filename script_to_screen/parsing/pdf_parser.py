"""Parse Hollywood-formatted screenplay PDFs using pdfplumber.

Handles both spec scripts (no scene/shot numbers) and shooting scripts
(numbered scene headings like "1 INT. LOCATION - DAY 1" and lettered
shot labels like "A WS DESCRIPTION").
"""

import re
from typing import Optional

import pdfplumber

from .screenplay_model import (
    Character, DialogueLine, Scene, Screenplay, Shot,
)

# ---------------------------------------------------------------------------
# Position thresholds (standard Courier 12pt screenplay, 8.5"x11", 72 pts/in)
# ---------------------------------------------------------------------------
PAGE_WIDTH_PTS = 612   # 8.5 * 72

# Left-edge (x0) thresholds – more reliable than x_center for classification
DIALOGUE_X0_MIN = 140  # dialogue text starts ~2.5" from left (x0 ≈ 180)
CHAR_X0_MIN = 220      # character names start ~3.3"+ from left (x0 ≈ 250)

# ---------------------------------------------------------------------------
# Regex patterns
# ---------------------------------------------------------------------------

# Scene heading: optional leading scene number, INT/EXT, then location/time,
# optional trailing scene/page number.
# Matches: "INT. COFFEE SHOP - DAY", "1 INT. SCHOOL LIBRARY - NIGHT 1",
#          "23 EXT. PARK - DAY 23"
SCENE_HEADING_RE = re.compile(
    r'^\s*\d*\s*(INT|EXT|INT/EXT|INT\./EXT|I/E)[\./]\s*(.+)',
    re.IGNORECASE,
)

# Shot with a letter label prefix (shooting-script format):
# "A WS LIBRARY AISLES", "B MS AIDEN AND ALIYAH", "AA CU CLOSEUP"
SHOT_LABEL_RE = re.compile(
    r'^\s*[A-Z]{1,2}\s+(WS|MS|CU|ECU|LS|OTS|POV)\b[:\s.-]*(.*)',
    re.IGNORECASE,
)

# Shot without label: "WS LIBRARY AISLES", "CU ALIYAH"
SHOT_TYPE_RE = re.compile(
    r'^\s*(WS|MS|CU|ECU|LS|OTS|POV)\b[:\s.-]*(.*)',
    re.IGNORECASE,
)

TRANSITION_RE = re.compile(
    r'^(CUT TO|DISSOLVE TO|FADE TO|SMASH CUT TO|MATCH CUT TO'
    r'|FADE IN|FADE OUT)[\.:]*\s*$',
    re.IGNORECASE,
)

PARENTHETICAL_RE = re.compile(r'^\(.*\)$')


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _is_all_caps(text: str) -> bool:
    """Check if all alphabetic characters in *text* are uppercase."""
    alpha = re.sub(r'[^a-zA-Z]', '', text)
    return len(alpha) > 1 and alpha == alpha.upper()


def _classify_line(text: str, x0: float, x_center: float,
                   page_width: float) -> str:
    """Classify a screenplay line using content first, then position."""
    stripped = text.strip()
    if not stripped:
        return "BLANK"

    # --- content-based (regex) checks first ---

    # Scene heading (with optional leading scene number)
    if SCENE_HEADING_RE.match(stripped):
        return "SCENE_HEADING"

    # Transition
    if TRANSITION_RE.match(stripped):
        return "TRANSITION"

    # Shot type (with or without letter label)
    if SHOT_LABEL_RE.match(stripped) or SHOT_TYPE_RE.match(stripped):
        return "SHOT"

    # --- position-based checks (use x0 = left edge) ---

    # Parenthetical: enclosed in parens, indented into dialogue zone
    if PARENTHETICAL_RE.match(stripped) and x0 > DIALOGUE_X0_MIN:
        return "PARENTHETICAL"

    # Character name: ALL CAPS, heavily indented, short
    if (_is_all_caps(stripped)
            and x0 > CHAR_X0_MIN
            and len(stripped) < 40):
        return "CHARACTER"

    # Dialogue: indented into dialogue zone, mixed case
    if x0 > DIALOGUE_X0_MIN and not _is_all_caps(stripped):
        return "DIALOGUE"

    # Action: everything else (left-justified)
    return "ACTION"


def _extract_lines(page) -> list[dict]:
    """Extract text lines with position info from a pdfplumber page."""
    words = page.extract_words(
        x_tolerance=3,
        y_tolerance=3,
        keep_blank_chars=True,
    )
    if not words:
        return []

    # Group words into lines by y-position
    lines = []
    current_line_words = [words[0]]
    current_y = words[0]["top"]

    for word in words[1:]:
        if abs(word["top"] - current_y) < 4:  # same line
            current_line_words.append(word)
        else:
            lines.append(_words_to_line(current_line_words, page.width))
            current_line_words = [word]
            current_y = word["top"]

    if current_line_words:
        lines.append(_words_to_line(current_line_words, page.width))

    return lines


def _words_to_line(words: list[dict], page_width: float) -> dict:
    """Combine words into a single line with metadata."""
    text = " ".join(w["text"] for w in words)
    x0 = min(w["x0"] for w in words)
    x1 = max(w["x1"] for w in words)
    x_center = (x0 + x1) / 2
    return {
        "text": text,
        "x0": x0,
        "x1": x1,
        "x_center": x_center,
        "top": words[0]["top"],
        "page_width": page_width,
    }


def _strip_scene_numbers(text: str) -> str:
    """Remove leading/trailing scene or page numbers from a heading line."""
    text = re.sub(r'^\s*\d+\s+', '', text.strip())   # leading  "1 "
    text = re.sub(r'\s+\d+\s*$', '', text)            # trailing " 1"
    return text.strip()


def _parse_scene_heading(text: str) -> tuple[str, str, str]:
    """Parse '1 INT. COFFEE SHOP - DAY 1' → (type, location, time)."""
    cleaned = _strip_scene_numbers(text)

    match = re.match(
        r'(INT|EXT|INT/EXT|INT\./EXT|I/E)[\./]\s*(.*)',
        cleaned,
        re.IGNORECASE,
    )
    if not match:
        return ("INT", cleaned, "DAY")

    loc_type = match.group(1).upper().replace("./", "/")
    remainder = match.group(2).strip()

    # Split on last " - " to separate location from time of day
    parts = remainder.rsplit(" - ", 1)
    location = parts[0].strip()
    time_of_day = parts[1].strip() if len(parts) > 1 else "DAY"

    return (loc_type, location, time_of_day)


def _flush_action(action_buffer: list[str],
                  current_scene: Optional["Scene"],
                  current_shot_idx: int) -> None:
    """Flush accumulated action text to scene and current shot."""
    if not action_buffer:
        return
    action_text = " ".join(action_buffer)
    if current_scene:
        current_scene.action_description += action_text + "\n"
        # Also append to current shot description for richer image prompts
        if 0 <= current_shot_idx < len(current_scene.shots):
            shot = current_scene.shots[current_shot_idx]
            if shot.description:
                shot.description += " " + action_text
            else:
                shot.description = action_text
    action_buffer.clear()


# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------

def parse_pdf(pdf_path: str) -> Screenplay:
    """Parse a screenplay PDF into a Screenplay model."""
    screenplay = Screenplay()
    characters: dict[str, Character] = {}

    current_scene: Optional[Scene] = None
    current_character: Optional[str] = None
    current_shot_idx = -1
    scene_index = 0
    action_buffer: list[str] = []
    last_classification = ""

    with pdfplumber.open(pdf_path) as pdf:
        # ---- Title extraction ----
        # If the first page starts with a scene heading, there is no title
        # page — leave title as "Untitled".
        if pdf.pages:
            first_page_text = pdf.pages[0].extract_text() or ""
            first_lines = first_page_text.strip().split("\n")

            # Check whether the first content line is a scene heading
            first_content = ""
            for ln in first_lines[:5]:
                if ln.strip():
                    first_content = ln.strip()
                    break

            if first_content and not SCENE_HEADING_RE.match(first_content):
                # Looks like a title page – grab the first short,
                # non-heading line as the title
                for ln in first_lines[:10]:
                    stripped = ln.strip()
                    if not stripped:
                        continue
                    if SCENE_HEADING_RE.match(stripped):
                        break  # hit a scene heading → stop
                    if TRANSITION_RE.match(stripped):
                        continue
                    if stripped.upper().startswith("FADE"):
                        continue
                    if len(stripped) < 60:
                        screenplay.title = stripped
                        break

        # ---- Page-by-page parsing ----
        for page in pdf.pages:
            # Extract full page text for raw_pages
            page_text = page.extract_text() or ""
            screenplay.raw_pages.append(page_text)

            page_lines = _extract_lines(page)

            for line_info in page_lines:
                text = line_info["text"].strip()
                if not text:
                    _flush_action(action_buffer, current_scene,
                                  current_shot_idx)
                    current_character = None
                    last_classification = "BLANK"
                    continue

                classification = _classify_line(
                    text,
                    line_info["x0"],
                    line_info["x_center"],
                    line_info["page_width"],
                )

                # ---------- SCENE HEADING ----------
                if classification == "SCENE_HEADING":
                    _flush_action(action_buffer, current_scene,
                                  current_shot_idx)

                    loc_type, location, tod = _parse_scene_heading(text)
                    clean_heading = _strip_scene_numbers(text)
                    current_scene = Scene(
                        index=scene_index,
                        heading=clean_heading,
                        location_type=loc_type,
                        location=location,
                        time_of_day=tod,
                    )
                    screenplay.scenes.append(current_scene)
                    scene_index += 1
                    current_shot_idx = -1
                    current_character = None

                # ---------- CHARACTER ----------
                elif classification == "CHARACTER":
                    _flush_action(action_buffer, current_scene,
                                  current_shot_idx)

                    # Strip extensions like (V.O.), (O.S.), (CONT'D)
                    char_name = re.sub(r'\s*\(.*?\)\s*', '', text).strip()
                    current_character = char_name

                    if char_name not in characters:
                        characters[char_name] = Character(name=char_name)

                # ---------- PARENTHETICAL ----------
                elif classification == "PARENTHETICAL":
                    pass  # consumed implicitly; kept for classification

                # ---------- DIALOGUE ----------
                elif classification == "DIALOGUE":
                    if current_character and current_scene:
                        if last_classification == "DIALOGUE" and current_scene.dialogue:
                            # Continuation of the same speech (line wrap)
                            current_scene.dialogue[-1].text += " " + text
                        else:
                            # New dialogue line
                            dl = DialogueLine(
                                character=current_character,
                                text=text,
                                scene_index=current_scene.index,
                                shot_index=max(0, current_shot_idx),
                            )
                            current_scene.dialogue.append(dl)
                            if current_character in characters:
                                characters[current_character].dialogue_count += 1

                # ---------- SHOT ----------
                elif classification == "SHOT":
                    _flush_action(action_buffer, current_scene,
                                  current_shot_idx)

                    # Try labeled shot first ("A WS …"), then bare ("WS …")
                    match = SHOT_LABEL_RE.match(text)
                    if not match:
                        match = SHOT_TYPE_RE.match(text)

                    shot_type = (match.group(1).upper()
                                 if match else "UNSPECIFIED")
                    shot_desc = (match.group(2).strip()
                                 if match and match.group(2) else text)

                    if current_scene:
                        current_shot_idx = len(current_scene.shots)
                        shot = Shot(
                            shot_type=shot_type,
                            description=shot_desc,
                            scene_index=current_scene.index,
                        )
                        current_scene.shots.append(shot)
                    current_character = None

                # ---------- ACTION ----------
                elif classification == "ACTION":
                    action_buffer.append(text)
                    current_character = None

                # ---------- TRANSITION ----------
                elif classification == "TRANSITION":
                    _flush_action(action_buffer, current_scene,
                                  current_shot_idx)
                    current_character = None

                last_classification = classification

    # Flush any remaining action text
    _flush_action(action_buffer, current_scene, current_shot_idx)

    # If no shots were explicitly defined, create one default shot per scene
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

    # Detect characters present in each shot from description & dialogue
    for scene in screenplay.scenes:
        for shot in scene.shots:
            desc_upper = shot.description.upper()
            for char_name in characters:
                if char_name in desc_upper:
                    shot.characters_present.append(char_name)
            for dl in scene.dialogue:
                if dl.shot_index == scene.shots.index(shot):
                    if dl.character not in shot.characters_present:
                        shot.characters_present.append(dl.character)

    screenplay.characters = characters
    return screenplay
