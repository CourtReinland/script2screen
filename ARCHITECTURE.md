# ScriptToScreen — Complete Architecture & Developer Guide

**Version:** 2.0 (experimental-shot-expansion branch)
**Repo:** https://github.com/CourtReinland/script2screen
**Runtime:** DaVinci Resolve Studio 20 (Fusion scripting) + Python 3.12+
**Platform:** macOS (Apple Silicon optimized for MLX-Audio)

For end-user installation and walkthrough, see **README.md**. This
file covers the developer-facing architecture: directory layout,
provider abstraction, the Lua↔Python boundary, and the debugging
patterns that have evolved across the project.

---

## What's New Since v1.5.2

The wizard expanded from 10 steps to **12** (two prompt-review pages
inserted at positions 5 and 7). The provider matrix grew significantly:

- **OpenAI** image (`gpt-image-1`/`-2`, DALL-E 2/3) and video (Sora 2 / Sora 2 Pro)
- **Google AI Studio** image: Gemini ("Nano Banana", "Nano Banana 2", "Nano Banana Pro") + Imagen 4 standard/ultra/fast — with full character-reference and style-reference inlining
- **Anthropic Claude** as a text/LLM provider (alongside the existing Grok)
- **Multi-API Freepik** image dispatch — one provider, twelve endpoints (Mystic, Flux Dev/Pro/2-Pro/2-Turbo/2-Klein/Kontext-Pro, HyperFlux, Seedream-4/v4.5, Z-Image-Turbo, Runway)
- **Multi-model Freepik** video — Kling v2.5 Pro / v2.6 Pro / o1 Pro / v3 Omni, Seedance Pro 1080p, MiniMax Hailuo 2.3, Wan v2.6 1080p

Two new Python modules:

- `parsing/llm_parser.py` — sends raw script text to any TextProvider with a JSON-extraction contract; emits the same `Screenplay` dataclass as the heuristic parser.
- `pipeline/prompt_refiner.py` — splits each shot into a still-image prompt (no camera motion verbs) and a video-motion prompt; caches to `<output>/refined_prompts.json` so image and video gen share one refinement pass.

Wizard regen flows now re-feed character references and start frames automatically, with per-shot Re-roll Provider/Model dropdowns on Steps 6 and 8 — useful when one model misinterprets a particular prompt and another nails it.

---

## What Is ScriptToScreen?

ScriptToScreen (STS) is a DaVinci Resolve plugin that converts screenplays (Fountain or PDF) into fully edited video timelines with AI-generated images, videos, voice acting, and lip-synced dialogue. It orchestrates 8+ providers through a 12-step wizard and a suite of standalone tools.

---

## Directory Layout

```
ScriptToScreen/                         ← Git repo root (github.com/CourtReinland/script2screen)
├── ScriptToScreen.lua                  ← Main wizard (~4500 lines now, 12 steps, launched from Resolve)
├── STS_Common.lua                      ← Shared Lua infrastructure (config, Python bridge, bin helpers, provider+model lists)
├── STS_Toolbar.lua                     ← Persistent floating toolbar — height bumped to 600px to fit the current button set
├── STS_Reprompt_Image.lua              ← Standalone: Generate / Reprompt image (dual-mode + per-provider Model dropdown)
├── STS_Reprompt_Video.lua              ← Standalone: Generate / Reprompt video (same dual-mode pattern)
├── STS_Generate_Audio.lua              ← Standalone: TTS dialogue generation for selected clip
├── STS_Lip_Sync.lua                    ← Standalone: lip-sync video+audio via Kling API
├── STS_ReframeShot.lua                 ← Standalone: AI camera angle manipulation
├── STS_ScriptRef.lua                   ← Standalone: floating screenplay reference viewer
├── STS_ExpandShots.lua                 ← Standalone: LLM-driven shot expansion (Sora-style coverage)
├── README.md                           ← End-user install + tutorial
├── ARCHITECTURE.md                     ← This file (developer reference)
├── script_to_screen/                   ← Python package (pipeline + API clients)
│   ├── __init__.py
│   ├── config.py                       ← AppConfig + GenerationDefaults (now includes openai/gemini/claude fields)
│   ├── manifest.py                     ← Per-project metadata persistence
│   ├── standalone.py                   ← Entry points for standalone Lua tools (reprompt_image / reprompt_video / etc.)
│   ├── parsing/
│   │   ├── screenplay_model.py         ← Data classes: Screenplay, Scene, Shot, DialogueLine, Character
│   │   ├── fountain_parser.py          ← Fountain screenplay format parser
│   │   ├── pdf_parser.py               ← PDF screenplay parser (heuristic, uses pdfplumber)
│   │   ├── llm_parser.py               ← LLM-driven parser — uses any TextProvider, JSON-extraction contract
│   │   └── fountain_writer.py          ← Round-trip writer for Screenplay → fountain
│   ├── api/                            ← API client implementations
│   │   ├── providers.py                ← Abstract base classes (Image/Video/Voice/Lipsync/Text Provider)
│   │   ├── registry.py                 ← Factory registry mapping provider IDs to classes
│   │   ├── polling.py                  ← Generic async polling (poll_until_complete, poll_batch)
│   │   ├── freepik_client.py           ← Freepik REST API — multi-API image (12 endpoints) + multi-model video (7 endpoints) + lipsync
│   │   ├── freepik_provider.py         ← Provider adapters wrapping freepik_client
│   │   ├── elevenlabs_client.py        ← ElevenLabs TTS API (voice clone + speech)
│   │   ├── elevenlabs_provider.py      ← Provider adapter wrapping elevenlabs_client
│   │   ├── comfyui_client.py           ← ComfyUI local server API
│   │   ├── comfyui_provider.py         ← ComfyUI Flux (image) + LTX (video) providers
│   │   ├── grok_client.py              ← xAI Grok Imagine REST (image + video)
│   │   ├── grok_provider.py            ← Grok provider adapter
│   │   ├── grok_text_client.py         ← xAI Grok chat-completions (text/JSON for parser + refiner)
│   │   ├── grok_text_provider.py       ← Grok TextProvider adapter
│   │   ├── openai_image_client.py      ← OpenAI gpt-image / dall-e
│   │   ├── openai_image_provider.py    ← OpenAI image provider adapter
│   │   ├── openai_video_client.py      ← OpenAI Sora 2 / Sora 2 Pro
│   │   ├── openai_video_provider.py    ← OpenAI video provider adapter
│   │   ├── openai_text_client.py       ← OpenAI chat-completions (text/JSON for parser + refiner)
│   │   ├── openai_text_provider.py     ← OpenAI TextProvider adapter
│   │   ├── claude_text_client.py       ← Anthropic /v1/messages (text/JSON; system as top-level field)
│   │   ├── claude_text_provider.py     ← Claude TextProvider adapter
│   │   ├── gemini_image_client.py      ← Google AI Studio: Gemini multimodal + Imagen with reference-image inlining
│   │   ├── gemini_image_provider.py    ← Gemini provider adapter
│   │   ├── voicebox_client.py          ← Voicebox local TTS server API
│   │   ├── voicebox_provider.py        ← Voicebox provider (CPU-based voice cloning)
│   │   ├── mlx_audio_provider.py       ← MLX-Audio/Chatterbox (Apple Silicon local TTS)
│   │   ├── kling_client.py             ← Kling direct API for lip sync — rate-limited at 2/min, 60s flat 429 backoff
│   │   ├── kling_provider.py           ← Kling provider adapter
│   │   └── reframe_client.py           ← Qwen Image Edit via HuggingFace Gradio
│   └── pipeline/                       ← Generation pipeline modules
│       ├── image_gen.py                ← Image gen — char_refs + prompt-mode characters threaded end-to-end, **provider_kwargs passthrough**
│       ├── character_prompts.py        ← Editable character text prompt generation (LLM + fallback)
│       ├── video_gen.py                ← Video gen — duration snapping (5/10s) + per-model payload schema
│       ├── prompt_refiner.py           ← LLM-driven still-vs-motion prompt split, caches to refined_prompts.json
│       ├── shot_expansion.py           ← LLM-driven shot expansion (more coverage from a single action beat)
│       ├── voice_gen.py                ← Voice cloning + dialogue TTS
│       ├── audio_merge.py              ← Per-shot audio merging
│       ├── lipsync.py                  ← Lip-sync generation pipeline
│       └── timeline_assembler.py       ← DaVinci Resolve timeline construction
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

## The 12-Step Wizard (ScriptToScreen.lua)

The main wizard guides users through the full pipeline:

| Step | Name | What Happens |
|------|------|-------------|
| 1 | Welcome | Provider configuration (API keys, server URLs, Test buttons) per category — image / video / voice / lip-sync |
| 2 | Script | Load .fountain or .pdf, pick parser (heuristic / Claude / GPT-4o / Grok), enter the LLM key if applicable, click Parse |
| 3 | Characters | Assign reference images or editable AI-generated text prompts to characters; auto-loads reference images from a per-character library across projects |
| 4 | Style | Style reference image, aspect ratio, creative-detail slider, "Refine prompts with LLM" toggle, per-provider model dropdowns (Mystic style / Freepik API / OpenAI model+quality+size+format+background / Gemini model) — all conditionally hidden based on the Step-1 image provider |
| 5 | Review Image Prompts | Per-shot editable prompt tree; user can approve all, edit individually, or skip |
| 6 | Image Generation | Generate All Images / Regenerate Selected / Retry Failed, with per-shot Re-roll Provider+Model dropdowns |
| 7 | Review Video Prompts | Same as Step 5 but for motion prompts |
| 8 | Video Generation | Generate All Videos / Regenerate Selected, with re-roll combos. Sora-* models auto-route to OpenAI regardless of saved videoProvider |
| 9 | Voices | Per-character voice assignment (stock voice or upload-to-clone for ElevenLabs; voice sample per character for local TTS) |
| 10 | Dialogue | TTS every dialogue line, merge per-shot audio |
| 11 | LipSync | Per-shot video+audio → Kling lip-sync (rate-limited at 2/min) |
| 12 | Assembly | Build Resolve timeline from synced clips |

### Wizard UI Header Bar
The wizard has a persistent header showing:
- Current step indicator: `1/12: Welcome`
- Episode number field: `Ep: [1]`
- Episode title field: `Title: [Origins]`

These values feed `buildEpisodePrefix()` for bin organization (e.g. `Ep1 - Origins`).

### Layout pattern for conditionally-hidden rows
Step 4 has 13 conditionally-hidden rows (Mystic-only, OpenAI-only,
Gemini-only). Each is declared `Hidden = true` AT CONSTRUCTION; the
visibility logic in `refreshProviderControls()` then only ever
*shows* rows — never hides them post-init. This is one-directional
visibility logic, which Fusion's UI engine handles reliably; the
two-directional version (default visible, hide what's irrelevant)
caused three separate "Browse button doesn't work" regressions
because Fusion didn't always reflow when a row's `Hidden` flipped
false→true after the page was realized.

---

## Standalone Tools

Each tool is a separate Lua script that can be launched independently from the STS Toolbar.

### STS_Reprompt_Image.lua  (Generate / Reprompt — dual mode)
- **Purpose:** Regenerate a selected clip's image with an edited prompt, OR generate a brand-new image when no clip is selected
- **Input:** Selected clip in media pool (optional)
- **Manifest lookup:** When a clip is selected, retrieves original prompt, style refs, character refs
- **UI:** Prompt text area, style reference path, character ref tree, provider dropdown, **per-provider Model dropdown** (Mystic style for Freepik, gpt-image-1/dall-e for OpenAI, Nano Banana variants for Gemini), Clear button to wipe pre-fills
- **Output:** New image imported to `ScriptToScreen/{Ep}/S{N}/Images`
- **Backend:** `script_to_screen.standalone.reprompt_image` accepts `**provider_kwargs` so the per-provider model id flows through to `provider.generate_image()` without the function knowing about each provider's flavors

### STS_Reprompt_Video.lua  (Generate / Reprompt — dual mode)
- **Purpose:** Regenerate or generate a video; pick start image from disk + motion prompt + provider+model
- **Manifest lookup:** When a clip is selected, retrieves original prompt, start image, duration, provider settings
- **UI:** Prompt text area, start-image path picker, duration override, provider dropdown, **per-provider Model dropdown** (Kling/Seedance/MiniMax/Wan for Freepik, Sora 2/Sora 2 Pro for OpenAI), Clear button
- **Output:** New video imported to `ScriptToScreen/{Ep}/S{N}/Videos`
- **Backend:** `standalone.reprompt_video` accepts `**provider_kwargs` for the same passthrough pattern

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
- **Layout:** Groups: Main (Full Wizard), Generate / Reprompt (Image, Video), Generate (Audio, Lip Sync, Reframe Shot), Reference (Script Reference)
- **Launch method:** `comp:Execute()` with `dofile()` for each tool
- **Sizing:** Window declared at 200×600px so the full button set + section labels fit without clipping. The previous 420px clipped the bottom row.

---

## LLM Parser & Prompt Refiner

Two opt-in modules that route screenplay processing through any
configured TextProvider (Grok / Claude / OpenAI). Both produce
output that's structurally identical to the deterministic
heuristics, so downstream pipeline code is untouched.

### parsing/llm_parser.py

`parse_with_llm(raw_text, text_provider, *, title, model, max_tokens)`
sends the raw screenplay text plus a strict system prompt that
specifies the exact JSON shape the model must return:

```
{
  "title": str,
  "scenes": [
    {"index", "heading", "location_type", "location", "time_of_day",
     "action_description", "shots": [{"shot_type", "description",
     "characters_present"}], "dialogue": [{"character", "text",
     "parenthetical", "shot_index"}]}
  ],
  "characters": {"<NAME>": {"dialogue_count"}}
}
```

Defends against hallucination: shot_index values are clamped into
`[0, len(scene.shots)-1]`, missing dialogue is skipped, missing
shots fall back to a single UNSPECIFIED shot synthesized from the
scene action so downstream iteration never skips a scene. Backfills
character dialogue_counts from actual scene dialogue if the LLM
under-counted.

The wizard's Step-2 dropdown picks between heuristic and the three
LLM options. The Parse handler reads the API key from the on-page
field (so the user can paste it without pressing Next first), saves
it to `config.providers.<id>.apiKey`, and routes the raw text
through `pdfplumber` (PDF) or `read()` (.fountain / .txt) before
calling `parse_with_llm`.

### pipeline/prompt_refiner.py

`refine_screenplay_prompts(screenplay, text_provider)` produces
two prompts per shot:

- **Image prompt** — describes a frozen instant. Hard rule in the
  system prompt: NO camera-motion verbs (pan, push-in, dolly, zoom,
  follow, track, rotate). Length 1-3 sentences, ~40-120 words.
- **Motion prompt** — describes what happens over the next few
  seconds. Camera move + character action + dialogue text in
  quotes (for lip-sync timing). Length 1-2 sentences.

`get_refined_prompts(screenplay, output_dir, *, text_provider, use_cache=True)`
wraps the above with on-disk caching at
`<output_dir>/refined_prompts.json`. Cache invalidates when shot
keys drift (re-parse with different results); the wizard's
GenAllImages handler runs the refinement; GenAllVideos reads the
cached file. So image and motion prompts stay consistent for a
given batch.

Wizard wiring: Step 4's "Refine prompts with LLM" checkbox is
read by both GenAllImages and GenAllVideos handlers. When ticked,
they pick the parser provider when LLM (already validated to have
a key on Step 2), or fall back to whichever LLM has a key
configured. The refined prompts are merged into `custom_prompts`
just before submission — user overrides from Step 5/7 review pages
still win.

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
| `image_gen.py` | `generate_images_for_screenplay()` | Generate all shot images; concatenates prompt-mode character descriptions into shot prompts |
| `image_gen.py` | `build_image_prompt(shot, scene)` | Construct detailed image prompt |
| `character_prompts.py` | `generate_character_prompts()` | Generate editable character visual prompts via xAI/Grok when configured, with deterministic fallback |
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
