"""Main wizard controller for ScriptToScreen."""

import os
import sys
import logging
import threading
from typing import Optional

from ..config import AppConfig, get_output_dir
from ..parsing.screenplay_model import Screenplay
from ..parsing.pdf_parser import parse_pdf
from ..parsing.fountain_parser import parse_fountain
from ..api.freepik_client import FreepikClient
from ..api.elevenlabs_client import ElevenLabsClient
from ..pipeline.image_gen import generate_images_for_screenplay, build_image_prompt
from ..pipeline.video_gen import generate_videos_for_screenplay, build_motion_prompt
from ..pipeline.voice_gen import clone_character_voices, generate_dialogue_audio, generate_shot_audio
from ..pipeline.lipsync import generate_lipsync_for_shots, get_final_video_paths
from ..pipeline.timeline_assembler import assemble_timeline
from ..utils import setup_logging

from .pages import (
    build_welcome_page,
    build_script_import_page,
    build_character_setup_page,
    build_style_page,
    build_image_gen_page,
    build_video_gen_page,
    build_voice_setup_page,
    build_dialogue_gen_page,
    build_lipsync_page,
    build_assembly_page,
)

logger = logging.getLogger("ScriptToScreen")

STEPS = [
    "Welcome", "Script", "Characters", "Style",
    "Images", "Videos", "Voices", "Dialogue",
    "LipSync", "Assembly",
]


class ScriptToScreenWizard:
    """Main wizard controller managing all pages and pipeline state."""

    def __init__(self, fusion):
        self.fusion = fusion
        self.ui = fusion.UIManager
        # In Resolve, bmd.UIDispatcher is the correct way to get the dispatcher
        # 'bmd' is injected as a global by Resolve's script environment
        import builtins
        bmd_module = getattr(builtins, 'bmd', None)
        if bmd_module:
            self.dispatcher = bmd_module.UIDispatcher(self.ui)
        else:
            self.dispatcher = fusion.UIDispatcher(self.ui)

        # State
        self.config = AppConfig.load()
        self.screenplay: Optional[Screenplay] = None
        self.current_step = 0
        self.output_dir = ""

        # API clients
        self.freepik: Optional[FreepikClient] = None
        self.elevenlabs: Optional[ElevenLabsClient] = None

        # Pipeline results
        self.image_prompts: dict[str, str] = {}
        self.image_paths: dict[str, str] = {}
        self.video_prompts: dict[str, str] = {}
        self.video_durations: dict[str, int] = {}
        self.video_paths: dict[str, str] = {}
        self.voice_samples: dict[str, list[str]] = {}
        self.dialogue_audio_paths: dict[str, str] = {}
        self.shot_audio_paths: dict[str, str] = {}
        self.lipsync_paths: dict[str, str] = {}

        # UI
        self.win = None
        self.items = None

        setup_logging()

    def run(self):
        """Launch the wizard window."""
        self.win = self.dispatcher.AddWindow(
            {
                "ID": "ScriptToScreenWin",
                "WindowTitle": "ScriptToScreen - AI Filmmaking",
                "Geometry": [100, 100, 700, 650],
            },
            [
                self.ui.VGroup([
                    # Step indicator
                    self.ui.HGroup({"ID": "StepIndicator"}, [
                        self.ui.Label({
                            "ID": "StepLabel",
                            "Text": "<b>Step 1 of 10: Welcome</b>",
                            "Alignment": {"AlignHCenter": True},
                            "StyleSheet": "font-size: 13px; padding: 8px; "
                                          "background-color: #333; color: #ddd;",
                        }),
                    ]),

                    # Stacked pages
                    self.ui.Stack({"ID": "PageStack"}, [
                        build_welcome_page(self.ui),        # 0
                        build_script_import_page(self.ui),   # 1
                        build_character_setup_page(self.ui),  # 2
                        build_style_page(self.ui),           # 3
                        build_image_gen_page(self.ui),       # 4
                        build_video_gen_page(self.ui),       # 5
                        build_voice_setup_page(self.ui),     # 6
                        build_dialogue_gen_page(self.ui),    # 7
                        build_lipsync_page(self.ui),         # 8
                        build_assembly_page(self.ui),        # 9
                    ]),
                ]),
            ],
        )

        self.items = self.win.GetItems()

        # Initialize UI state
        self._init_combos()
        self._load_saved_config()
        self._show_step(0)

        # Connect events
        self._connect_events()

        # Show and run
        self.win.Show()
        self.dispatcher.RunLoop()
        self.win.Hide()

    def _init_combos(self):
        """Populate combo boxes with options."""
        # Model combo
        model_combo = self.items.get("ModelCombo")
        if model_combo:
            for model in ["realism", "fluid", "zen", "flexible", "super_real", "editorial_portraits"]:
                model_combo.AddItem(model)

        # Aspect ratio combo
        aspect_combo = self.items.get("AspectCombo")
        if aspect_combo:
            for ar in ["widescreen_16_9", "classic_4_3", "square_1_1", "traditional_3_4", "social_story_9_16"]:
                aspect_combo.AddItem(ar)

        # Resolution combo
        res_combo = self.items.get("ResolutionCombo")
        if res_combo:
            for res in ["1920x1080", "3840x2160", "1280x720"]:
                res_combo.AddItem(res)

        # FPS combo
        fps_combo = self.items.get("FPSCombo")
        if fps_combo:
            for fps in ["24", "25", "30", "60"]:
                fps_combo.AddItem(fps)

    def _load_saved_config(self):
        """Load saved API keys into UI."""
        if self.config.api.freepik_api_key:
            self.items["FreepikKey"].Text = self.config.api.freepik_api_key
        if self.config.api.elevenlabs_api_key:
            self.items["ElevenLabsKey"].Text = self.config.api.elevenlabs_api_key

    def _show_step(self, step: int):
        """Navigate to a wizard step."""
        self.current_step = step
        stack = self.items.get("PageStack")
        if stack:
            stack.CurrentIndex = step

        step_label = self.items.get("StepLabel")
        if step_label:
            step_label.Text = f"<b>Step {step + 1} of {len(STEPS)}: {STEPS[step]}</b>"

    def _connect_events(self):
        """Connect all UI events to handlers."""
        win = self.win

        # Window close
        win.On.ScriptToScreenWin.Close = self._on_close

        # Navigation
        win.On.NextBtn.Clicked = self._on_next
        win.On.BackBtn.Clicked = self._on_back
        win.On.CancelBtn.Clicked = self._on_close
        win.On.FinishBtn.Clicked = self._on_close

        # Step 1: API config
        win.On.TestFreepik.Clicked = self._on_test_freepik
        win.On.TestElevenLabs.Clicked = self._on_test_elevenlabs

        # Step 2: Script import
        win.On.BrowseScript.Clicked = self._on_browse_script
        win.On.ParseScript.Clicked = self._on_parse_script

        # Step 3: Characters
        win.On.BrowseCharImg.Clicked = self._on_browse_char_image

        # Step 4: Style
        win.On.BrowseStyle.Clicked = self._on_browse_style
        win.On.DetailSlider.ValueChanged = self._on_detail_changed

        # Step 5: Image gen
        win.On.GenerateAllImages.Clicked = self._on_generate_all_images
        win.On.RegenSelected.Clicked = self._on_regen_selected_image

        # Step 6: Video gen
        win.On.GenerateAllVideos.Clicked = self._on_generate_all_videos

        # Step 7: Voice setup
        win.On.BrowseVoiceSample.Clicked = self._on_browse_voice_sample
        win.On.CloneVoice.Clicked = self._on_clone_voice

        # Step 8: Dialogue gen
        win.On.GenerateAllDialogue.Clicked = self._on_generate_all_dialogue

        # Step 9: Lip sync
        win.On.SyncAll.Clicked = self._on_sync_all

        # Step 10: Assembly
        win.On.AssembleTimeline.Clicked = self._on_assemble_timeline

    # ── Navigation ───────────────────────────────────────────────────

    def _on_next(self, ev):
        if self.current_step == 0:
            self._save_api_config()
        if self.current_step < len(STEPS) - 1:
            next_step = self.current_step + 1
            self._prepare_step(next_step)
            self._show_step(next_step)

    def _on_back(self, ev):
        if self.current_step > 0:
            self._show_step(self.current_step - 1)

    def _on_close(self, ev):
        self.config.save()
        self.dispatcher.ExitLoop()

    # ── Step Preparation ─────────────────────────────────────────────

    def _prepare_step(self, step: int):
        """Prepare data/UI for a step before showing it."""
        if step == 2 and self.screenplay:
            self._populate_character_tree()
        elif step == 4 and self.screenplay:
            self._populate_image_tree()
        elif step == 5 and self.screenplay:
            self._populate_video_tree()
        elif step == 6 and self.screenplay:
            self._populate_voice_tree()
        elif step == 7 and self.screenplay:
            self._populate_dialogue_tree()
        elif step == 8:
            self._populate_lipsync_tree()
        elif step == 9:
            self._populate_assembly_summary()

    # ── Step 1: API Config ───────────────────────────────────────────

    def _save_api_config(self):
        self.config.api.freepik_api_key = self.items["FreepikKey"].Text.strip()
        self.config.api.elevenlabs_api_key = self.items["ElevenLabsKey"].Text.strip()

        if self.config.api.freepik_api_key:
            self.freepik = FreepikClient(self.config.api.freepik_api_key)
        if self.config.api.elevenlabs_api_key:
            self.elevenlabs = ElevenLabsClient(self.config.api.elevenlabs_api_key)

        self.config.save()

    def _on_test_freepik(self, ev):
        key = self.items["FreepikKey"].Text.strip()
        if not key:
            self.items["FreepikStatus"].Text = "No key"
            return
        client = FreepikClient(key)
        ok, message = client.test_connection_details()
        if ok:
            self.items["FreepikStatus"].Text = "OK"
            self.items["FreepikStatus"].StyleSheet = "color: green;"
        else:
            self.items["FreepikStatus"].Text = message
            self.items["FreepikStatus"].StyleSheet = "color: red;"

    def _on_test_elevenlabs(self, ev):
        key = self.items["ElevenLabsKey"].Text.strip()
        if not key:
            self.items["ElevenLabsStatus"].Text = "No key"
            return
        client = ElevenLabsClient(key)
        ok, message = client.test_connection_details()
        if ok:
            self.items["ElevenLabsStatus"].Text = "OK"
            self.items["ElevenLabsStatus"].StyleSheet = "color: green;"
        else:
            self.items["ElevenLabsStatus"].Text = message
            self.items["ElevenLabsStatus"].StyleSheet = "color: red;"

    # ── Step 2: Script Import ────────────────────────────────────────

    def _request_file(self, title="Select File"):
        """Open a file dialog. Works across Resolve/Fusion environments."""
        try:
            path = self.fusion.RequestFile(title)
            return path if path else None
        except Exception:
            # Fallback: use a simple path input dialog
            return None

    def _on_browse_script(self, ev):
        path = self._request_file("Select Screenplay (PDF or .fountain)")
        if path:
            self.items["ScriptPath"].Text = path

    def _on_parse_script(self, ev):
        path = self.items["ScriptPath"].Text
        if not path or not os.path.exists(path):
            self.items["ParseStatus"].Text = "Please select a valid file."
            return

        self.items["ParseStatus"].Text = "Parsing..."

        try:
            if path.lower().endswith(".pdf"):
                self.screenplay = parse_pdf(path)
            elif path.lower().endswith(".fountain"):
                self.screenplay = parse_fountain(path)
            else:
                self.items["ParseStatus"].Text = "Unsupported format. Use PDF or .fountain."
                return

            # Set up output directory
            self.output_dir = str(get_output_dir(self.screenplay.title or "untitled"))

            # Show summary
            self.items["ScriptSummary"].PlainText = self.screenplay.summary()
            self.items["ParseStatus"].Text = f"Parsed successfully! {self.screenplay.scene_count} scenes found."
            self.items["ParseStatus"].StyleSheet = "color: green;"

            # Populate scene tree
            self._populate_scene_tree()

        except Exception as e:
            self.items["ParseStatus"].Text = f"Parse error: {e}"
            self.items["ParseStatus"].StyleSheet = "color: red;"
            logger.error(f"Parse error: {e}", exc_info=True)

    def _populate_scene_tree(self):
        tree = self.items.get("SceneTree")
        if not tree or not self.screenplay:
            return

        tree.SetHeaderLabels(["Scene", "Location", "Shots", "Dialogue Lines"])
        tree.Clear()

        for scene in self.screenplay.scenes:
            item = tree.NewItem()
            item.Text[0] = f"Scene {scene.index + 1}"
            item.Text[1] = scene.heading
            item.Text[2] = str(len(scene.shots))
            item.Text[3] = str(len(scene.dialogue))
            tree.AddTopLevelItem(item)

    # ── Step 3: Character Setup ──────────────────────────────────────

    def _populate_character_tree(self):
        tree = self.items.get("CharacterTree")
        if not tree or not self.screenplay:
            return

        tree.SetHeaderLabels(["Character", "Lines", "Reference Image"])
        tree.Clear()

        for name, char in sorted(self.screenplay.characters.items()):
            item = tree.NewItem()
            item.Text[0] = name
            item.Text[1] = str(char.dialogue_count)
            item.Text[2] = char.reference_image_path or "(none)"
            tree.AddTopLevelItem(item)

    def _on_browse_char_image(self, ev):
        tree = self.items.get("CharacterTree")
        if not tree:
            return

        selected = tree.CurrentItem()
        if not selected:
            return

        char_name = selected.Text[0]
        path = self._request_file("Select Character Reference Image")
        if path and char_name in self.screenplay.characters:
            self.screenplay.characters[char_name].reference_image_path = path
            selected.Text[2] = path

    # ── Step 4: Style ────────────────────────────────────────────────

    def _on_browse_style(self, ev):
        path = self._request_file("Select Style Reference Image")
        if path:
            self.items["StylePath"].Text = path

    def _on_detail_changed(self, ev):
        val = self.items["DetailSlider"].Value
        self.items["DetailValue"].Text = str(val)

    # ── Step 5: Image Generation ─────────────────────────────────────

    def _populate_image_tree(self):
        tree = self.items.get("ImageTree")
        if not tree or not self.screenplay:
            return

        tree.SetHeaderLabels(["Shot", "Type", "Prompt", "Status"])
        tree.Clear()

        for scene in self.screenplay.scenes:
            for shot_idx, shot in enumerate(scene.shots):
                shot_key = f"s{scene.index}_sh{shot_idx}"
                prompt = build_image_prompt(shot, scene, self.screenplay)
                self.image_prompts[shot_key] = prompt

                item = tree.NewItem()
                item.Text[0] = shot_key
                item.Text[1] = shot.shot_type
                item.Text[2] = prompt[:80] + "..." if len(prompt) > 80 else prompt
                item.Text[3] = "Generated" if shot_key in self.image_paths else "Pending"
                tree.AddTopLevelItem(item)

    def _on_generate_all_images(self, ev):
        if not self.freepik or not self.screenplay:
            return

        self.config.defaults.freepik_model = self.items["ModelCombo"].CurrentText or "realism"
        self.config.defaults.aspect_ratio = self.items["AspectCombo"].CurrentText or "widescreen_16_9"
        self.config.defaults.creative_detailing = self.items["DetailSlider"].Value

        style_path = self.items["StylePath"].Text or None

        def progress(current, total, msg):
            pct = int((current / max(total, 1)) * 100)
            self.items["ImageProgressBar"].Value = pct
            self.items["ImageProgress"].Text = f"{msg} ({current}/{total})"

        def run():
            self.image_paths = generate_images_for_screenplay(
                self.screenplay, self.freepik, self.output_dir,
                style_reference_path=style_path,
                defaults=self.config.defaults,
                progress_callback=progress,
                custom_prompts=self.image_prompts,
            )
            self.items["ImageProgress"].Text = f"Done! {len(self.image_paths)} images generated."

        threading.Thread(target=run, daemon=True).start()

    def _on_regen_selected_image(self, ev):
        tree = self.items.get("ImageTree")
        if not tree or not self.freepik:
            return
        selected = tree.CurrentItem()
        if selected:
            shot_key = selected.Text[0]
            prompt = self.image_prompts.get(shot_key, selected.Text[2])
            # TODO: regenerate in background thread

    # ── Step 6: Video Generation ─────────────────────────────────────

    def _populate_video_tree(self):
        tree = self.items.get("VideoTree")
        if not tree or not self.screenplay:
            return

        tree.SetHeaderLabels(["Shot", "Start Frame", "Duration", "Status"])
        tree.Clear()

        for scene in self.screenplay.scenes:
            for shot_idx, shot in enumerate(scene.shots):
                shot_key = f"s{scene.index}_sh{shot_idx}"
                motion = build_motion_prompt(shot, scene)
                self.video_prompts[shot_key] = motion

                item = tree.NewItem()
                item.Text[0] = shot_key
                item.Text[1] = "Yes" if shot_key in self.image_paths else "No"
                item.Text[2] = f"{self.video_durations.get(shot_key, 5)}s"
                item.Text[3] = "Generated" if shot_key in self.video_paths else "Pending"
                tree.AddTopLevelItem(item)

    def _on_generate_all_videos(self, ev):
        if not self.freepik or not self.screenplay:
            return

        def progress(current, total, msg):
            pct = int((current / max(total, 1)) * 100)
            self.items["VideoProgressBar"].Value = pct
            self.items["VideoProgress"].Text = f"{msg} ({current}/{total})"

        def run():
            self.video_paths = generate_videos_for_screenplay(
                self.screenplay, self.freepik, self.image_paths, self.output_dir,
                defaults=self.config.defaults,
                progress_callback=progress,
                custom_durations=self.video_durations,
                custom_prompts=self.video_prompts,
            )
            self.items["VideoProgress"].Text = f"Done! {len(self.video_paths)} videos generated."

        threading.Thread(target=run, daemon=True).start()

    # ── Step 7: Voice Setup ──────────────────────────────────────────

    def _populate_voice_tree(self):
        tree = self.items.get("VoiceTree")
        if not tree or not self.screenplay:
            return

        tree.SetHeaderLabels(["Character", "Lines", "Voice Sample", "Voice ID"])
        tree.Clear()

        for name in self.screenplay.speaking_characters:
            char = self.screenplay.characters[name]
            item = tree.NewItem()
            item.Text[0] = name
            item.Text[1] = str(char.dialogue_count)
            samples = self.voice_samples.get(name, [])
            item.Text[2] = f"{len(samples)} sample(s)" if samples else "(none)"
            item.Text[3] = char.voice_id or "(none)"
            tree.AddTopLevelItem(item)

    def _on_browse_voice_sample(self, ev):
        tree = self.items.get("VoiceTree")
        if not tree:
            return
        selected = tree.CurrentItem()
        if not selected:
            return

        char_name = selected.Text[0]
        path = self._request_file("Select Voice Sample (MP3, WAV, M4A)")
        if path:
            if char_name not in self.voice_samples:
                self.voice_samples[char_name] = []
            self.voice_samples[char_name].append(path)
            selected.Text[2] = f"{len(self.voice_samples[char_name])} sample(s)"

    def _on_clone_voice(self, ev):
        if not self.elevenlabs or not self.screenplay:
            return

        tree = self.items.get("VoiceTree")
        selected = tree.CurrentItem() if tree else None
        if not selected:
            return

        char_name = selected.Text[0]
        samples = self.voice_samples.get(char_name, [])
        if not samples:
            self.items["VoiceProgress"].Text = f"No voice samples for {char_name}"
            return

        self.items["VoiceProgress"].Text = f"Cloning voice for {char_name}..."

        def run():
            try:
                voice_ids = clone_character_voices(
                    self.screenplay, self.elevenlabs,
                    {char_name: samples},
                )
                if char_name in voice_ids:
                    selected.Text[3] = voice_ids[char_name]
                    self.items["VoiceProgress"].Text = f"Voice cloned for {char_name}!"
                else:
                    self.items["VoiceProgress"].Text = f"Cloning failed for {char_name}"
            except Exception as e:
                self.items["VoiceProgress"].Text = f"Error: {e}"

        threading.Thread(target=run, daemon=True).start()

    # ── Step 8: Dialogue Generation ──────────────────────────────────

    def _populate_dialogue_tree(self):
        tree = self.items.get("DialogueTree")
        if not tree or not self.screenplay:
            return

        tree.SetHeaderLabels(["Key", "Character", "Text", "Status"])
        tree.Clear()

        for scene in self.screenplay.scenes:
            for d_idx, dl in enumerate(scene.dialogue):
                key = f"s{scene.index}_d{d_idx}"
                item = tree.NewItem()
                item.Text[0] = key
                item.Text[1] = dl.character
                item.Text[2] = dl.text[:60] + "..." if len(dl.text) > 60 else dl.text
                item.Text[3] = "Generated" if key in self.dialogue_audio_paths else "Pending"
                tree.AddTopLevelItem(item)

    def _on_generate_all_dialogue(self, ev):
        if not self.elevenlabs or not self.screenplay:
            return

        self.config.defaults.voice_stability = self.items["StabilitySlider"].Value / 100.0
        self.config.defaults.voice_similarity_boost = self.items["SimilaritySlider"].Value / 100.0

        def progress(current, total, msg):
            pct = int((current / max(total, 1)) * 100)
            self.items["DialogueProgressBar"].Value = pct
            self.items["DialogueProgress"].Text = f"{msg} ({current}/{total})"

        def run():
            self.dialogue_audio_paths = generate_dialogue_audio(
                self.screenplay, self.elevenlabs, self.output_dir,
                defaults=self.config.defaults,
                progress_callback=progress,
            )
            self.shot_audio_paths = generate_shot_audio(
                self.screenplay, self.dialogue_audio_paths, self.output_dir,
            )
            self.items["DialogueProgress"].Text = (
                f"Done! {len(self.dialogue_audio_paths)} audio files generated."
            )

        threading.Thread(target=run, daemon=True).start()

    # ── Step 9: Lip Sync ─────────────────────────────────────────────

    def _populate_lipsync_tree(self):
        tree = self.items.get("LipSyncTree")
        if not tree:
            return

        tree.SetHeaderLabels(["Shot", "Has Video", "Has Audio", "Status"])
        tree.Clear()

        for shot_key in self.video_paths:
            item = tree.NewItem()
            item.Text[0] = shot_key
            item.Text[1] = "Yes"
            item.Text[2] = "Yes" if shot_key in self.shot_audio_paths else "No"
            item.Text[3] = "Synced" if shot_key in self.lipsync_paths else "Pending"
            tree.AddTopLevelItem(item)

    def _on_sync_all(self, ev):
        if not self.freepik:
            return

        def progress(current, total, msg):
            pct = int((current / max(total, 1)) * 100)
            self.items["LipSyncProgressBar"].Value = pct
            self.items["LipSyncProgress"].Text = f"{msg} ({current}/{total})"

        def run():
            self.lipsync_paths = generate_lipsync_for_shots(
                self.screenplay, self.freepik,
                self.video_paths, self.shot_audio_paths,
                self.output_dir,
                progress_callback=progress,
            )
            self.items["LipSyncProgress"].Text = (
                f"Done! {len(self.lipsync_paths)} clips lip-synced."
            )

        threading.Thread(target=run, daemon=True).start()

    # ── Step 10: Assembly ────────────────────────────────────────────

    def _populate_assembly_summary(self):
        final_videos = get_final_video_paths(self.video_paths, self.lipsync_paths)

        lines = [
            f"Screenplay: {self.screenplay.title if self.screenplay else 'N/A'}",
            f"Total video clips: {len(final_videos)}",
            f"Lip-synced clips: {len(self.lipsync_paths)}",
            f"Audio tracks: {len(self.shot_audio_paths)}",
            f"Output directory: {self.output_dir}",
            "",
            "Clip order:",
        ]

        if self.screenplay:
            for scene in self.screenplay.scenes:
                lines.append(f"  Scene {scene.index + 1}: {scene.heading}")
                for shot_idx, shot in enumerate(scene.shots):
                    key = f"s{scene.index}_sh{shot_idx}"
                    status = "ready" if key in final_videos else "missing"
                    lines.append(f"    {key} [{shot.shot_type}] - {status}")

        summary_widget = self.items.get("AssemblySummary")
        if summary_widget:
            summary_widget.PlainText = "\n".join(lines)

    def _on_assemble_timeline(self, ev):
        if not self.screenplay:
            return

        timeline_name = self.items["TimelineName"].Text or "ScriptToScreen Assembly"
        res_text = self.items["ResolutionCombo"].CurrentText or "1920x1080"
        fps_text = self.items["FPSCombo"].CurrentText or "24"

        parts = res_text.split("x")
        width = int(parts[0]) if len(parts) == 2 else 1920
        height = int(parts[1]) if len(parts) == 2 else 1080
        fps = float(fps_text)

        final_videos = get_final_video_paths(self.video_paths, self.lipsync_paths)

        def progress(current, total, msg):
            pct = int((current / max(total, 1)) * 100)
            self.items["AssemblyProgressBar"].Value = pct
            self.items["AssemblyProgress"].Text = f"{msg} ({current}/{total})"

        def run():
            try:
                success = assemble_timeline(
                    self.screenplay, final_videos, self.shot_audio_paths,
                    timeline_name=timeline_name,
                    width=width, height=height, fps=fps,
                    progress_callback=progress,
                )
                if success:
                    self.items["AssemblyProgress"].Text = "Timeline assembled successfully!"
                else:
                    self.items["AssemblyProgress"].Text = "Assembly failed. Check logs."
            except Exception as e:
                self.items["AssemblyProgress"].Text = f"Error: {e}"
                logger.error(f"Assembly error: {e}", exc_info=True)

        threading.Thread(target=run, daemon=True).start()
