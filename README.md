# ScriptToScreen

A DaVinci Resolve plugin that turns a screenplay into a fully-edited timeline — AI-generated start-frame images, image-to-video clips, voiced dialogue, lip-synced characters, all assembled scene-by-scene in your Resolve project.

You drop in a Fountain or PDF script, click through twelve wizard steps, and end up with a timeline you can refine like any other Resolve project. Standalone tools sit alongside it for one-shot regenerations once the wizard's done.

```
script.pdf  →  parse  →  characters  →  style  →  images  →  videos  →  voices  →  lip-sync  →  Resolve timeline
```

---

## Status

Production-ready on macOS (Apple Silicon). DaVinci Resolve Studio 20+ required. The full pipeline has been live-tested end-to-end with real provider credits — every step lands in the bin.

Branch: `experimental-shot-expansion`. Default branch will move once we cut a v2 tag.

---

## What Providers Does It Support?

You don't pick one — you pick the best one for each task on its own dropdown:

| Stage | Cloud options | Local options |
|-------|---------------|---------------|
| **Screenplay parsing** | Heuristic (built-in regex), Claude, GPT-4o, Grok | — |
| **Image generation** | Freepik (Mystic, Flux 2 Pro, Seedream, HyperFlux, Z-Image, Runway, Flux Kontext, …), OpenAI gpt-image / dall-e, Google Gemini ("Nano Banana", "Nano Banana 2", "Nano Banana Pro"), Imagen 4, Grok Imagine | ComfyUI Flux Kontext |
| **Video generation** | Freepik (Kling v3 Omni / v2.5 Pro / v2.6 Pro / o1 Pro, Seedance Pro 1080p, MiniMax Hailuo 2.3, Wan v2.6 1080p), OpenAI Sora 2 / Sora 2 Pro, Grok Imagine Video | ComfyUI LTX 2.3 |
| **Voice / TTS** | ElevenLabs | MLX-Audio Kokoro (fast), Voicebox (slower) |
| **Lip-sync** | Kling AI direct, Kling via Freepik | — |
| **Prompt refinement** | Claude, GPT-4o, Grok | — |

Each provider's model selector is a dropdown — when you pick Gemini you get the six Nano Banana / Imagen variants; when you pick Freepik for video you get all seven of their endpoints; when you pick OpenAI for video you get Sora 2 / Sora 2 Pro. The wizard routes by model id, so if you pick Sora the request goes to OpenAI even if your default video provider was Freepik.

---

## Install

This isn't on the Resolve Marketplace yet. The shipping path is a `.pkg` installer that puts files in three places (Resolve's Scripts directory, a user package directory, and a launcher in Workspace > Scripts).

```bash
git clone https://github.com/CourtReinland/script2screen.git
cd script2screen
./install.sh    # (or use the .pkg if you have it)
```

You then need API keys for whichever cloud providers you plan to use. The wizard's Step 1 has a Test button next to each provider — paste a key, click Test, and it'll tell you immediately whether the credentials work.

For local generation:
- **ComfyUI** — run any recent ComfyUI install on `127.0.0.1:8188`. The wizard's image and video providers point there by default.
- **Voicebox** — local TTS server on `127.0.0.1:17493`.
- **MLX-Audio** — bundled, runs on Apple Silicon, no setup beyond `pip install` (the installer handles this).

---

## Quick Tutorial — Your First Episode

Open a Resolve project (any project — STS organizes its output into a `ScriptToScreen / Ep1-Test / S0 / …` bin tree under your Master folder, so it co-exists fine with anything else).

In Resolve: **Workspace → Scripts → Edit → STS_Toolbar**. A small floating panel appears with a Full Wizard button at the top. Click it.

### Step 1 — Providers

Pick a provider for each category and paste API keys. Click Test next to each one to confirm credentials work. Set `Ep:` and `Title:` at the top of the page — they become the bin folder name (e.g. "Ep1 - Test").

### Step 2 — Script

Browse to your screenplay (`.pdf` or `.fountain`). The Parser dropdown lets you choose:

- **Heuristic** — built-in regex parser. Fast, free, reliable on well-formatted screenplays from Final Draft / Fade In / fountain conversions.
- **Claude / GPT-4o / Grok** — sends the raw text to an LLM with a strict JSON-extraction contract. Better for indie scripts where shots have to be inferred from action paragraphs, treatments, or scripts with non-standard formatting. Costs a few cents in tokens per parse.

If you pick an LLM parser, an API Key field appears next to the dropdown — paste a key (it's saved per-LLM so switching parsers later doesn't require re-typing). Click **Parse**. The summary panel below shows the parsed scene/shot/dialogue/character counts.

### Step 3 — Characters

Every speaking character gets a row. For each one, click **Set Image for Selected** and pick a reference photo — this anchors the character's likeness across all generated stills.

The wizard auto-loads any reference image you've used before for a character of the same name. So once you've assigned "ALIYAH" → `aliyah_ref.jpg`, every future project with an ALIYAH character starts with that reference pre-populated.

### Step 4 — Style

The Style Reference image (Browse → pick) sets the visual treatment — palette, mood, lens feel — for every still in the project. Optional but strongly recommended.

Aspect ratio defaults to `widescreen_16_9`. Creative Detail (slider) controls how aggressively the image model interprets the prompt.

**Refine prompts with LLM** is a big lever. When ticked, every shot's prompt goes through an LLM that splits it into:
- A **still-image prompt** — composition, lighting, expression. *No* camera-motion verbs.
- A **video-motion prompt** — the camera move, the action, the dialogue delivery beats.

Without refinement, both prompts are built from the same deterministic template, which means motion verbs ("pan", "push-in") leak into the still-image prompt and produce blurred or doubled subjects. With refinement on, the still is sharp and the video has richer motion. Costs ~5¢ per project in LLM tokens.

The provider-specific rows below (Model (Gemini), Engine (Mystic), etc.) only appear for the provider you picked on Step 1.

### Step 5 — Review Image Prompts

Every shot's prompt, listed and editable. Approve all, edit individually, refresh to re-pull the auto prompts. The point of this page is "see the prompt before you spend money on it."

If you skip this page (just click Next), the auto prompts run as-is.

### Step 6 — Image Generation

Click **Generate All Images**. The progress label shows shot-by-shot status; failures get a red Failed badge and the full error message in the Resolve Console.

Once the batch finishes:
- **Regenerate Selected** — pick a shot in the tree, optionally change the **Re-roll Provider/Model** dropdowns to a different model, click. The shot regenerates with character refs + style ref re-fed automatically.
- **Retry Failed** — appears if any shots failed. One click retries them all (with the same model unless you switch the re-roll combos).

Generated images land in `<project>/images/` and get imported into the bin under `…/Ep1-Test/S0/Images`.

### Step 7 — Review Video Prompts

Same as Step 5 but for motion prompts. Skip if you don't need to micro-edit.

### Step 8 — Video Generation

**Generate All Videos**. Defaults to the Step-1 video provider; you can pick any model from the dropdown. Same Re-roll Provider/Model combo for retries — handy when one model misinterprets a shot and another nails it.

Pacing: the Freepik video endpoints have tight per-minute rate limits (verified empirically: ~1 submission per 60s for Seedance Pro 1080p), so the pipeline spaces submissions automatically. A 6-shot batch takes ~7-10 minutes total.

Each video lands in `…/Ep1-Test/S0/Videos`.

### Steps 9-10 — Voices and Dialogue

If you picked ElevenLabs, you'll be prompted per-character to either pick a stock voice or upload a clip to clone from. Clicked through, **Generate All Dialogue** TTS-es every line and saves to `…/Audio`.

For local TTS (MLX-Audio / Voicebox), each character just needs a voice sample (one short audio clip).

### Step 11 — Lip Sync

For shots with dialogue, the lip-sync step takes the generated video + the matching audio and produces a synced version. Goes through Kling AI (direct or via Freepik). Same 1/min rate limit as video gen; 6 shots takes ~10 minutes.

### Step 12 — Assembly

Click **Build Timeline**. The wizard creates a Resolve timeline with each shot's video and synced audio on the right tracks, in scene order. You're done — what's on screen is your first cut.

---

## Standalone Tools

Once the wizard's run, the floating STS Tools toolbar exposes per-shot operations:

| Tool | What it does |
|------|--------------|
| **Image** (Generate / Reprompt) | Regenerate a selected media-pool clip, OR generate a fresh image from scratch. Per-provider Model dropdown. |
| **Video** (Generate / Reprompt) | Same but for video. Pick a start frame from disk, set a motion prompt, pick provider+model, click. |
| **Generate Audio** | Re-TTS a dialogue line for a clip selected in the bin. |
| **Lip Sync** | Sync a selected video to a selected audio. |
| **Reframe Shot** | Use Qwen Image Edit (via HuggingFace Gradio) to change the camera angle on a selected still without re-generating from scratch. |
| **Script Reference** | Floating screenplay viewer that scrolls in lock-step with your timeline playhead. |

All tools share the wizard's saved API keys. None of them require you to re-run the full pipeline.

---

## Project Structure

Every wizard run produces a project directory at `~/Library/Application Support/ScriptToScreen/projects/<slug>/`:

```
sts17/
├── images/             # generated start frames (one per shot)
├── videos/             # image-to-video output
├── audio/              # TTS-generated dialogue lines + merged-per-shot audio
├── lipsync/            # lip-synced video versions
├── refined_prompts.json    # cached LLM-refined prompts (if Step 4 toggle was on)
├── manifest.json       # per-shot prompt history, character refs, provider settings
└── screenplay_pages.json   # cached page-text for the Script Reference tool
```

Files in the `images/` and `videos/` directories use shot-key naming (`s{scene}_sh{shot}_{8charuid}.{ext}`) so the wizard can track regenerations: the newest mtime per shot wins.

The slug comes from the active Resolve project name (sanitized). So switching Resolve projects switches STS projects automatically — no manual project picker.

---

## Common Gotchas

- **Step-4 Browse button doesn't open the file picker.** Should be fixed for good as of `6433b77`. If it ever comes back, the cause is layout overflow from conditionally-hidden rows; the fix is to declare them `Hidden = true` at construction (not just toggle visibility post-init).
- **"All N videos failed: 400 Validation error"** on Seedance Pro. Almost always Freepik's rate-limiter signaling overflow as a 400 instead of 429. The fix is in `freepik_client.py`'s 60s flat backoff. If you see it after a fresh sync, your account may be out of credits — the new error logger surfaces the real billing message after three retries.
- **Sora returns 403 from a kling URL.** You picked Sora but your `videoProvider` is set to Freepik. The wizard now auto-routes sora-* models to OpenAI (`3d76751`); make sure you're on a recent enough version.
- **Generated images don't match the character refs.** Make sure you're on a recent version of the Gemini provider (`character_refs` are inlined as `inlineData` parts only since `c056048`). Older versions silently dropped them.
- **Videos don't look like the start frame.** Same kind of bug for video: Seedance/MiniMax/Wan use `image` as the start-frame field, not `image_url` — fixed in `7c20563`.

---

## Related Reading

- **`ARCHITECTURE.md`** — developer-focused overview: directory layout, provider abstraction, the threading model between Lua / Python / Resolve API, debugging flow.
- **Per-commit history on the experimental branch** — every meaningful change has a long commit message explaining the bug and the diagnosis. `git log --grep=Fix` is a good place to start when something behaves unexpectedly.

---

## License

MIT. Use it, fork it, ship it.
