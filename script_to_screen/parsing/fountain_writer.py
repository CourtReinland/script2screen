"""Write a Screenplay model back out as a Fountain (.fountain) file.

This is used for round-trip serialization by the shot expansion pipeline:
parse PDF/fountain → expand shots → write fountain → re-parse in wizard.

The output format is intentionally minimal and follows the Fountain spec:
  - Title page with "Title: ..." etc.
  - Scene headings: "INT. LOCATION - TIME"
  - Shot lines: "WS description" (shot type first, then description)
  - Action lines: plain paragraphs
  - Character: ALL CAPS name
  - Dialogue: lines after character
  - Parentheticals: (like this)
"""

from __future__ import annotations

from .screenplay_model import Screenplay, Scene


def _escape_text(text: str) -> str:
    """Escape/clean text for Fountain output."""
    # Fountain is mostly plain text; strip problematic chars
    return text.replace("\r", "").strip()


def write_fountain(screenplay: Screenplay, output_path: str) -> None:
    """Write a Screenplay to a .fountain file.

    Args:
        screenplay: The Screenplay to serialize.
        output_path: Path where the .fountain file will be written.
    """
    lines: list[str] = []

    # Title page
    if screenplay.title:
        lines.append(f"Title: {_escape_text(screenplay.title)}")
    lines.append("")  # blank line ends title page

    for scene in screenplay.scenes:
        # Scene heading: "INT. LOCATION - TIME"
        heading = scene.heading.strip()
        if not heading:
            # Reconstruct from parts
            heading = f"{scene.location_type}. {scene.location} - {scene.time_of_day}"
        lines.append(heading.upper())
        lines.append("")

        # Scene action (if any)
        if scene.action_description:
            action = _escape_text(scene.action_description)
            if action:
                lines.append(action)
                lines.append("")

        # Shots, interleaved with dialogue attached to each shot
        for shot_idx, shot in enumerate(scene.shots):
            # Emit shot as a shot line: "WS DESCRIPTION"
            shot_type = shot.shot_type if shot.shot_type != "UNSPECIFIED" else ""
            desc = _escape_text(shot.description) if shot.description else ""

            # Mark expanded shots with a note so they're visible when the
            # fountain file is opened in a text editor. The Fountain parser
            # strips [[ ... ]] notes so this round-trips cleanly.
            origin_note = ""
            if getattr(shot, "origin", "original") == "expanded":
                origin_note = " [[AI-expanded]]"

            if shot_type:
                shot_line = f"{shot_type} {desc}".strip()
            else:
                shot_line = desc or "UNSPECIFIED"

            lines.append(shot_line + origin_note)
            lines.append("")

            # Dialogue lines attached to this shot, in order
            shot_dialogue = [dl for dl in scene.dialogue if dl.shot_index == shot_idx]
            for dl in shot_dialogue:
                lines.append(dl.character.strip().upper())
                if dl.parenthetical:
                    paren = dl.parenthetical.strip()
                    if not paren.startswith("("):
                        paren = f"({paren})"
                    if not paren.endswith(")"):
                        paren = f"{paren})"
                    lines.append(paren)
                lines.append(_escape_text(dl.text))
                lines.append("")

        # Scene separator
        lines.append("")

    content = "\n".join(lines).rstrip() + "\n"

    with open(output_path, "w", encoding="utf-8") as f:
        f.write(content)
