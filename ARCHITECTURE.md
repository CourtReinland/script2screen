# ScriptToScreen — Complete Architecture & Developer Guide

**Version:** 1.5.2
**Repo:** https://github.com/CourtReinland/script2screen
**Runtime:** DaVinci Resolve Studio 20 (Fusion scripting) + Python 3.12+
**Platform:** macOS (Apple Silicon optimized for MLX-Audio)

---

## What Is ScriptToScreen?

ScriptToScreen (STS) is a DaVinci Resolve plugin that converts Hollywood-formatted screenplays (Fountain or PDF) into fully edited video timelines with AI-generated images, videos, voice acting, and lip-synced dialogue. It orchestrates multiple AI providers through a 10-step wizard and a suite of standalone tools.

---

## Directory Layout

```
ScriptToScreen/                         ← Git repo root (github.com/CourtReinland/script2screen)
├── ScriptToScreen.lua                  ← Main wizard (~2900 lines, launched from Resolve)
├── STS_Common.lua                      ← Shared Lua infrastructure (config, Python bridge, bin helpers)
├── STS_Toolbar.lua                     ← Persistent floating toolbar for all STS tools
├── STS_Reprompt_Image.lua              ← Standalone: regenerate an image with edited prompt
├── STS_Reprompt_Video.lua              ← Standalone: regenerate a video with edited prompt
├── STS_Generate_Audio.lua              ← Standalone: TTS dialogue generation for selected clip
├── STS_Lip_Sync.lua                    ← Standalone: lip-sync video+audio via Kling API
├── STS_ReframeShot.lua                 ← Standalone: AI camera angle manipulation
├── STS_ScriptRef.lua                   ← Standalone: floating screenplay reference viewer
├── script_to_screen/                   ← Python package (pipeline + API clients)
│   ├── __init__.py
│   ├── config.py                       ← AppConfig dataclass, storage paths
│   ├── manifest.py                     ← Per-project metadata persistence
│   ├── screenplay_model.py             ← Data classes: Screenplay, Scene, Shot, DialogueLine, Character
│   ├── fountain_parser.py              ← Fountain screenplay format parser
│   ├── pdf_parser.py                   ← PDF screenplay parser (uses pdfplumber)
│   ├── providers.py                    ← Abstract base classes for all provider types
│   ├── registry.py                     ← Factory registry mapping provider IDs to classes
│   ├── polling.py                      ← Generic async polling (poll_until_complete, poll_batch)
│   ├── standalone.py                   ← CLI entry points for standalone Lua tools
│   ├── api/                            ← API client implementations
│   │   ├── freepik_client.py           ← Freepik REST API (image, video, lipsync)
│   │   ├── freepik_provider.py         ← Provider adapters wrapping freepik_client
│   │   ├── elevenlabs_client.py        ← ElevenLabs TTS API (voice clone + speech)
│   │   ├── elevenlabs_provider.py      ← Provider adapter wrapping elevenlabs_client
│   │   ├── comfyui_client.py           ← ComfyUI local server API
│   │   ├── comfyui_provider.py         ← ComfyUI Flux (image) + LTX (video) providers
│   │   ├── grok_provider.py            ← xAI Grok Imagine (image + video)
│   │   ├── voicebox_client.py          ← Voicebox local TTS server API
│   │   ├── voicebox_provider.py        ← Voicebox provider (CPU-based voice cloning)
│   │   ├── mlx_audio_provider.py       ← MLX-Audio/Chatterbox (Apple Silicon local TTS)
│   │   ├── kling_client.py             ← Kling direct API for lip sync
│   │   ├── kling_provider.py           ← Kling provider adapter
│   │   └── reframe_client.py           ← Qwen Image Edit via HuggingFace Gradio
│   ├── pipeline/                       ← Generation pipeline modules
│   │   ├── image_gen.py                ← Image generation + prompt building
│   │   ├── video_gen.py                ← Video generation + motion prompts + duration estimation
│   │   ├── voice_gen.py                ← Voice cloning + dialogue TTS
│   │   ├── lipsync.py                  ← Lip-sync generation pipeline
│   │   └── timeline_assembler.py       ← DaVinci Resolve timeline construction
│   └── ui/                             ← Python UI components (for wizard pages)
│       ├── __init__.py
│       ├── wizard.py                   ← 10-step wizard controller
│       ├── pages.py                    ← Page builders for each wizard step
│       └── components.py               ← Reusable UI widgets
└── .gitignore
```

---

## Installation & File Locations

STS files live in THREE locations that must stay in sync:

| Location | Purpose | Path |
|----------|---------|------|
| **Git worktree** | Development source | `~/blueos/.claude/worktrees/angry-goodall/ScriptToScreen/` |
| **User package** | Python runtime + config | `~/Library/Application Support/ScriptToScreen/` |
| **System Scripts** | What Resolve actually loads | `/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility/` |

### System Scripts directory contains:
- `ScriptToScreen.lua` — Main wizard
- `STS_Common.lua` — Shared library
- `STS_Toolbar.lua`, `STS_Reprompt_Image.lua`, `STS_Reprompt_Video.lua`, etc.

### User package directory contains:
- `script_to_screen/` — Full Python package
- `config.json` — User configuration (API keys, provider selection)
- `projects/{slug}/` — Per-project output directories
- `venv/` — Python virtual environment
- `mlx-venv/` — Separate venv for MLX-Audio (Apple Silicon)

### Sync command (run after any code change):
```bash
# Copy Lua files to system Scripts
cp ScriptToScreen/*.lua "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility/"

# Copy Python package to user support dir
cp -R ScriptToScreen/script_to_screen/ ~/Library/Application\ Support/ScriptToScreen/script_to_screen/
```

**Important:** Resolve 20 has a bug where scripts launched from Workspace > Scripts menu silently fail. Use Fusion console `dofile("/path/to/script.lua")` or `comp:Execute()` instead.

---

## Architecture Layers

### Layer 1: Lua UI (DaVinci Resolve Fusion)

All UI runs inside Resolve's Fusion scripting environment using `fu.UIManager` and `bmd.UIDispatcher`. Lua scripts create windows with buttons, dropdowns, trees, and text fields.

**Key pattern — Python bridge:**
```lua
-- STS_Common.lua provides STS_runPython(code, callback)
-- Writes Python code to a temp .py file, executes it, reads JSON result
local result = STS_runPython([[
import json, sys
sys.path.insert(0, "~/Library/Application Support/ScriptToScreen")
from script_to_screen.standalone import generate_audio
data = generate_audio(shot_key="s0_sh2", text="Hello world", voice_id="abc123")
print(json.dumps(data))
]])
```

**Key pattern — Media Pool bin creation:**
```lua
-- STS_Common.lua provides STS_importAndTag(filePath, targetBinName)
-- Creates: ScriptToScreen/{EpPrefix}/S{N}/{targetBinName}
-- e.g.: ScriptToScreen/Ep1-Origins/S0/Audio
STS_importAndTag(audioFilePath, "Audio")
```

**Key pattern — Episode prefix:**
```lua
-- STS_Common.lua provides STS_buildEpisodePrefix()
-- Reads episodeNumber + episodeTitle from config
-- Returns: "Ep1-Origins" or "Ep5" or "MyTitle" or ""
-- Used by both wizard and all standalone tools
```

### Layer 2: Python Pipeline

The Python package handles all AI generation, screenplay parsing, and Resolve API interaction.

**Provider registry pattern:**
```python
from script_to_screen.registry import create_image_provider
provider = create_image_provider("grok", api_key="xai-xxx")
task_id = provider.generate_image(prompt="A sunset...", aspect_ratio="16:9")
result = poll_until_complete(task_id, provider.check_image_status)
provider.download_image(result, save_path="/path/to/output.jpg")
```

### Layer 3: AI Provider APIs

| Provider | ID | Category | Type | Auth |
|----------|-----|----------|------|------|
| Freepik Mystic | `freepik` | Image | Cloud | `x-freepik-api-key` header |
| Freepik Kling | `freepik` | Video | Cloud | `x-freepik-api-key` header |
| Freepik Kling | `freepik` | Lipsync | Cloud | `x-freepik-api-key` header |
| xAI Grok Imagine | `grok` | Image | Cloud | Bearer token |
| xAI Grok Imagine | `grok` | Video | Cloud | Bearer token |
| ComfyUI Flux | `comfyui_flux` | Image | Local | None (localhost:8188) |
| ComfyUI LTX | `comfyui_ltx` | Video | Local | None (localhost:8188) |
| ElevenLabs | `elevenlabs` | Voice | Cloud | `xi-api-key` header |
| Voicebox | `voicebox` | Voice | Local | None (localhost:17493) |
| MLX-Audio | `mlx_audio` | Voice | Local | None (in-process) |
| Kling Direct | `kling` | Lipsync | Cloud | JWT (access_key:secret_key) |

---

## The 10-Step Wizard (ScriptToScreen.lua)

The main wizard guides users through the full pipeline:

| Step | Name | What Happens |
|------|------|-------------|
| 1 | Welcome | Provider configuration (API keys, server URLs, test buttons) |
| 2 | Script Import | Load .fountain or .pdf screenplay file |
| 3 | Shot Review | Review parsed scenes/shots, edit prompts before generation |
| 4 | Character Setup | Assign reference images to characters |
| 5 | Image Generation | Generate images for all shots (with progress bar) |
| 6 | Import Images | Import generated images to Resolve media pool bins |
| 7 | Video Generation | Generate videos from images + motion prompts |
| 8 | Dialogue Generation | Voice assignment, TTS for all dialogue lines |
| 9 | Lip Sync | Generate lip-synced video from video + audio pairs |
| 10 | Timeline Assembly | Build Resolve timeline with all media |

### Wizard UI Header Bar
The wizard has a persistent header showing:
- Current step indicator: `1/10: Welcome`
- Episode number field: `Ep: [1]`
- Episode title field: `Title: [Origins]`

These values feed `buildEpisodePrefix()` for bin organization.

---

## Standalone Tools

Each tool is a separate Lua script that can be launched independently from the STS Toolbar.

### STS_Reprompt_Image.lua
- **Purpose:** Regenerate a single image with an edited prompt
- **Input:** Selected clip in media pool or timeline
- **Manifest lookup:** Retrieves original prompt, style refs, character refs
- **UI:** Prompt text area, style reference path, character ref grid, provider dropdown
- **Output:** New image imported to `ScriptToScreen/{Ep}/S{N}/Images`

### STS_Reprompt_Video.lua
- **Purpose:** Regenerate a single video with edited prompt/duration
- **Input:** Selected clip in media pool or timeline
- **Manifest lookup:** Retrieves original prompt, start image, duration, provider settings
- **UI:** Prompt text area, duration override, provider dropdown
- **Output:** New video imported to `ScriptToScreen/{Ep}/S{N}/Videos`

### STS_Generate_Audio.lua
- **Purpose:** Generate TTS dialogue for a shot
- **Input:** Selected clip or manual text entry
- **Pre-fill:** Extracts dialogue from screenplay pages JSON via shot key
- **Voice selection:** Dropdown populated from ElevenLabs cloud voices or local Voicebox profiles
- **Model selection:** ElevenLabs model dropdown (multilingual_v2, turbo_v2_5, etc.)
- **Output:** MP3 file imported to `ScriptToScreen/{Ep}/S{N}/Audio`

### STS_Lip_Sync.lua
- **Purpose:** Generate lip-synced video from video + audio
- **Auto-detection:** Finds matching audio file by shot key pattern
- **Upload:** For Kling direct API, uploads video/audio to tmpfiles.org for URL access
- **Output:** New video imported to `ScriptToScreen/{Ep}/S{N}/LipSync`

### STS_ReframeShot.lua
- **Purpose:** AI camera angle manipulation
- **Backend:** Qwen Image Edit via HuggingFace Gradio API
- **Presets:** Front View, Left/Right Side 45deg, Top Down, Low Angle, Wide Angle, Close Up, Back View, Move Forward
- **Output:** Reframed image imported to `ScriptToScreen/{Ep}/S{N}/Images`

### STS_ScriptRef.lua
- **Purpose:** Floating reference panel showing screenplay text for current shot
- **Auto-refresh:** Optional 3-second timer to track timeline position
- **Data source:** `screenplay_pages.json` in project output directory

### STS_Toolbar.lua
- **Purpose:** Persistent floating toolbar with buttons for all tools
- **Layout:** Groups: Main (Full Wizard), Reprompt (Image, Video), Generate (Audio, Lip Sync, Reframe Shot), Reference (Script Reference)
- **Launch method:** `comp:Execute()` with `dofile()` for each tool

---

## Data Model

### Screenplay Structure
```
Screenplay
├── title: string
├── scenes: Scene[]
│   ├── index: int (0-based)
│   ├── heading: string ("INT. COFFEE SHOP - DAY")
│   ├── location_type: "INT" | "EXT"
│   ├── location: string ("COFFEE SHOP")
│   ├── time_of_day: "DAY" | "NIGHT" | "DAWN" | "DUSK"
│   ├── action_description: string
│   ├── shots: Shot[]
│   │   ├── shot_type: "WS" | "MS" | "CU" | "ECU" | "LS" | "OTS" | "POV"
│   │   ├── description: string
│   │   ├── scene_index: int
│   │   └── characters_present: string[]
│   └── dialogue: DialogueLine[]
│       ├── character: string
│       ├── text: string
│       ├── parenthetical: string?
│       ├── scene_index: int
│       └── shot_index: int
├── characters: {name: Character}
│   ├── dialogue_count: int
│   ├── reference_image_path: string?
│   ├── voice_id: string?
│   └── voice_sample_path: string?
└── raw_pages: string[]
```

### Shot Key Format
- Pattern: `s{scene_index}_sh{shot_index}` (e.g., `s0_sh0`, `s2_sh5`)
- Zero-based indices
- Used in filenames: `s0_sh0_abc123.jpg`, `s0_sh2_def456.mp3`
- The hash suffix is a truncated UUID for uniqueness

### Manifest (manifest.json)
Stored per-project at `~/Library/Application Support/ScriptToScreen/projects/{slug}/manifest.json`:
```json
{
  "version": 1,
  "resolve_project_name": "STS5",
  "episode_number": "1",
  "episode_title": "Origins",
  "characters": {
    "ALICE": {
      "voice_id": "EL_voice_abc123",
      "reference_image_path": "/path/to/alice_ref.jpg"
    }
  },
  "generated_media": {
    "s0_sh0_abc123.jpg": {
      "type": "image",
      "shot_key": "s0_sh0",
      "prompt": "Wide shot of a neon-lit coffee shop...",
      "provider": "FreepikImageProvider",
      "provider_settings": {"model": "realism", "aspect_ratio": "widescreen_16_9"},
      "style_reference_path": "/path/to/style_ref.jpg",
      "character_refs": ["/path/to/alice_ref.jpg"],
      "file_path": "/full/path/to/s0_sh0_abc123.jpg",
      "generated_at": "2026-04-04T20:16:00+00:00"
    }
  }
}
```

### Config (config.json)
Stored at `~/Library/Application Support/ScriptToScreen/config.json`:
```json
{
  "imageProvider": "grok",
  "imageApiKey": "xai-xxx...",
  "imageServerUrl": "http://127.0.0.1:8188",
  "videoProvider": "grok",
  "videoApiKey": "xai-xxx...",
  "voiceProvider": "elevenlabs",
  "voiceApiKey": "sk_xxx...",
  "voiceServerUrl": "http://127.0.0.1:17493",
  "lipsyncProvider": "kling",
  "lipsyncApiKey": "access_key:secret_key",
  "model": "realism",
  "aspectRatio": "widescreen_16_9",
  "detailing": 50,
  "episodeNumber": "1",
  "episodeTitle": "Origins",
  "lastScriptPath": "/path/to/screenplay.fountain",
  "projectSlug": "sts5",
  "voiceModel": "eleven_multilingual_v2"
}
```

---

## Media Pool Bin Structure

```
Master/
└── ScriptToScreen/
    └── Ep1-Origins/          ← buildEpisodePrefix() output
        ├── S0/               ← Scene 0
        │   ├── Images/       ← Generated images (JPG)
        │   ├── Videos/       ← Generated videos (MP4)
        │   ├── Audio/        ← Dialogue TTS audio (MP3)
        │   └── LipSync/      ← Lip-synced videos (MP4)
        ├── S1/               ← Scene 1
        │   ├── Images/
        │   ├── Videos/
        │   ├── Audio/
        │   └── LipSync/
        ...
```

The `findOrCreate` pattern ensures bins are created if missing and reused if they exist:
```python
def find_or_create(parent, name):
    for f in (parent.GetSubFolders() or {}).values():
        if f.GetName() == name: return f
    return mp.AddSubFolder(parent, name)
```

---

## On-Disk Output Structure

```
~/Library/Application Support/ScriptToScreen/projects/{slug}/
├── manifest.json              ← Generation metadata
├── screenplay_pages.json      ← Parsed screenplay for ScriptRef viewer
├── images/
│   ├── s0_sh0_abc123.jpg
│   ├── s0_sh1_def456.jpg
│   └── ...
├── videos/
│   ├── s0_sh0_ghi789.mp4
│   └── ...
├── audio/
│   └── dialogue_audio/
│       ├── s0_sh2_jkl012.mp3
│       └── ...
└── lipsync/
    ├── s0_sh2_mno345.mp4
    └── ...
```

---

## Key Functions Reference

### STS_Common.lua
| Function | Purpose |
|----------|---------|
| `STS_loadConfig()` | Load config.json into Lua table |
| `STS_saveConfig(cfg)` | Write config table to config.json |
| `STS_runPython(code, callback)` | Execute Python code via temp file, return JSON result |
| `STS_buildEpisodePrefix()` | Build "Ep1-Origins" string from config |
| `STS_importAndTag(filePath, binName)` | Import file to episode/scene bin, tag with STS metadata |
| `STS_getProjectSlug()` | Get current Resolve project name as slug |
| `STS_jsonEncode(tbl)` | Minimal JSON encoder (no external deps) |
| `STS_jsonDecode(str)` | Minimal JSON decoder |

### ScriptToScreen.lua (Wizard)
| Function | Purpose |
|----------|---------|
| `buildEpisodePrefix()` | Local version (same logic as STS_Common) |
| `parseScript()` | Parse screenplay via Python fountain/pdf parser |
| `generateImages()` | Run image_gen pipeline for all shots |
| `generateVideos()` | Run video_gen pipeline for all shots |
| `generateDialogue()` | Run voice_gen pipeline for all dialogue |
| `assembleTimeline()` | Build Resolve timeline from all media |
| `populateShotTree()` | Fill shot review tree from screenplay data |
| `populateDialogueTree()` | Fill dialogue tree for voice assignment |
| `FetchCloudVoices handler` | Populate VoiceAssignCombo dropdown from ElevenLabs |
| `AssignVoice handler` | Connect selected voice to selected character |

### Python Pipeline
| Module | Key Function | Purpose |
|--------|-------------|---------|
| `image_gen.py` | `generate_images_for_screenplay()` | Generate all shot images |
| `image_gen.py` | `build_image_prompt(shot, scene)` | Construct detailed image prompt |
| `video_gen.py` | `generate_videos_for_screenplay()` | Generate all shot videos |
| `video_gen.py` | `build_motion_prompt(shot, scene)` | Construct motion/animation prompt |
| `video_gen.py` | `_estimate_duration(shot, scene)` | Estimate video duration from dialogue/action |
| `voice_gen.py` | `generate_dialogue_audio()` | TTS for all dialogue lines |
| `voice_gen.py` | `clone_character_voices()` | Clone voices from audio samples |
| `manifest.py` | `record_generated_image()` | Save image metadata to manifest |
| `manifest.py` | `lookup_by_filename()` | Retrieve generation params for reprompting |
| `standalone.py` | `generate_image()` | Single image generation (for standalone tools) |
| `standalone.py` | `generate_video()` | Single video generation |
| `standalone.py` | `generate_audio()` | Single TTS generation |
| `standalone.py` | `generate_lipsync()` | Single lip-sync generation |
| `polling.py` | `poll_until_complete()` | Generic polling with timeout |

---

## Known Issues & Gotchas

1. **Resolve 20 Scripts menu bug:** Scripts silently fail when launched from Workspace > Scripts. Use Fusion console `dofile()` instead, or the STS Toolbar.

2. **Three-location sync:** Changes must be copied to worktree, user package dir, AND system Scripts/Utility. Forgetting any one location causes stale code to run.

3. **Cached Fusion windows:** Resolve persists UI windows across script executions. Old windows from previous sessions show stale content. Click Cancel to dismiss before new window appears.

4. **ElevenLabs quota error:** Returns HTTP 401 (not 429) for quota_exceeded. The error body contains `{"detail": {"status": "quota_exceeded"}}`. Added proper handling in elevenlabs_client.py.

5. **Audio format:** ElevenLabs returns MP3 (`output_format=mp3_44100_128`). Files MUST be saved with `.mp3` extension. DaVinci Resolve refuses to import MP3 content in a `.wav` container.

6. **buildEpisodePrefix() was missing:** In v1.5.1 and earlier, the function was called 3 times in ScriptToScreen.lua but never defined. This caused all media to import to flat `ScriptToScreen/Images` instead of `ScriptToScreen/Ep1-Origins/S0/Images`. Fixed in v1.5.2.

7. **Voice dropdown vs character tree:** Voices populate in VoiceAssignCombo (dropdown), characters in VoiceTree (tree widget). The "Assign to Selected" button connects them. They should NOT be mixed in the same widget.

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| v1.5.2 | 2026-04-04 | Add missing `buildEpisodePrefix()` function definition — fixes flat bin structure |
| v1.5.1 | 2026-04-04 | Fix audio file extension (.wav to .mp3) for ElevenLabs |
| v1.5.0 | 2026-04-04 | Audio bin import, dialogue tree population, quota handling |
| v1.4.9 | 2026-04-04 | Fix dialogue generation, tree population, script path saving |
| v1.4.8 | 2026-04-03 | Separate voice assignment from character list |
| v1.4.7 | 2026-04-03 | Re-apply ElevenLabs cloud voices after linter removed them |
| v1.4.6 | 2026-04-03 | STS_Generate_Audio: voice model dropdown, cloud voice fetch |

---

## Remaining TODO / Known Gaps

1. **Timeline assembly** — Step 10 needs testing. The timeline creation code exists but hasn't been verified end-to-end with the episode/scene bin structure.

2. **Reprompt tools live testing** — The standalone Reprompt Image and Reprompt Video tools use `STS_importAndTag()` which should work correctly, but haven't been tested with a fresh generation since the v1.5.2 fix.

3. **Multi-scene support** — Currently tested with a single scene (S0). Multi-scene screenplays should create S0, S1, S2... bins automatically, but this needs verification.

4. **Legacy flat bins** — Previous runs created flat `ScriptToScreen/Images` bins. These are harmless but should be manually cleaned up by the user.

5. **GitHub repo** — The repo at CourtReinland/script2screen contains only the ScriptToScreen directory. The Python venv and project output files are gitignored.
