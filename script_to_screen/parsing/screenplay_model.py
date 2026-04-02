"""Data model for parsed screenplays."""

from dataclasses import dataclass, field
from typing import Optional


@dataclass
class Character:
    name: str
    dialogue_count: int = 0
    reference_image_path: Optional[str] = None
    voice_id: Optional[str] = None
    voice_sample_path: Optional[str] = None


@dataclass
class Shot:
    shot_type: str  # WS, MS, CU, ECU, LS, or UNSPECIFIED
    description: str
    scene_index: int
    characters_present: list[str] = field(default_factory=list)

    @property
    def prompt_prefix(self) -> str:
        type_map = {
            "WS": "Wide shot",
            "MS": "Medium shot",
            "CU": "Close-up",
            "ECU": "Extreme close-up",
            "LS": "Long shot",
            "OTS": "Over the shoulder shot",
            "POV": "Point of view shot",
            "UNSPECIFIED": "",
        }
        return type_map.get(self.shot_type, "")


@dataclass
class DialogueLine:
    character: str
    text: str
    parenthetical: Optional[str] = None
    scene_index: int = 0
    shot_index: int = 0


@dataclass
class Scene:
    index: int
    heading: str  # "INT. COFFEE SHOP - DAY"
    location_type: str  # "INT" or "EXT"
    location: str  # "COFFEE SHOP"
    time_of_day: str  # "DAY", "NIGHT", etc.
    action_description: str = ""
    shots: list[Shot] = field(default_factory=list)
    dialogue: list[DialogueLine] = field(default_factory=list)

    @property
    def has_dialogue(self) -> bool:
        return len(self.dialogue) > 0

    @property
    def characters_in_scene(self) -> list[str]:
        chars = set()
        for dl in self.dialogue:
            chars.add(dl.character)
        for shot in self.shots:
            chars.update(shot.characters_present)
        return sorted(chars)


@dataclass
class Screenplay:
    title: str = "Untitled"
    scenes: list[Scene] = field(default_factory=list)
    characters: dict[str, Character] = field(default_factory=dict)
    raw_pages: list[str] = field(default_factory=list)

    @property
    def scene_count(self) -> int:
        return len(self.scenes)

    @property
    def total_shots(self) -> int:
        return sum(len(s.shots) for s in self.scenes)

    @property
    def total_dialogue_lines(self) -> int:
        return sum(len(s.dialogue) for s in self.scenes)

    @property
    def speaking_characters(self) -> list[str]:
        return [name for name, char in self.characters.items() if char.dialogue_count > 0]

    def get_all_shots(self) -> list[Shot]:
        shots = []
        for scene in self.scenes:
            shots.extend(scene.shots)
        return shots

    def get_dialogue_for_shot(self, scene_index: int, shot_index: int) -> list[DialogueLine]:
        if scene_index < len(self.scenes):
            scene = self.scenes[scene_index]
            return [d for d in scene.dialogue if d.shot_index == shot_index]
        return []

    def summary(self) -> str:
        lines = [
            f"Title: {self.title}",
            f"Scenes: {self.scene_count}",
            f"Total Shots: {self.total_shots}",
            f"Total Dialogue Lines: {self.total_dialogue_lines}",
            f"Characters ({len(self.characters)}):",
        ]
        for name, char in sorted(self.characters.items()):
            lines.append(f"  - {name} ({char.dialogue_count} lines)")
        return "\n".join(lines)
