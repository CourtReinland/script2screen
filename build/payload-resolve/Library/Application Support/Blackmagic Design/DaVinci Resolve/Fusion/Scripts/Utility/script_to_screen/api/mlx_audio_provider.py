"""MLX-Audio as VoiceProvider — fast local TTS on Apple Silicon.

Uses the Kokoro-82M model via Apple's MLX framework for native
Metal GPU acceleration. ~12x faster than Voicebox CPU mode.

Requires Python 3.12 venv with mlx-audio installed:
    ~/Library/Application Support/ScriptToScreen/mlx-venv/
"""

import json
import logging
import os
import shutil
import subprocess
import wave
from pathlib import Path
from typing import Optional

from .providers import VoiceProvider

logger = logging.getLogger("ScriptToScreen")

# Preset voices for Kokoro (fast, no cloning)
KOKORO_VOICES = {
    "af_heart": "Heart (Female, American)",
    "af_bella": "Bella (Female, American)",
    "af_nova": "Nova (Female, American)",
    "af_sky": "Sky (Female, American)",
    "am_adam": "Adam (Male, American)",
    "am_echo": "Echo (Male, American)",
    "bf_alice": "Alice (Female, British)",
    "bf_emma": "Emma (Female, British)",
    "bm_daniel": "Daniel (Male, British)",
    "bm_george": "George (Male, British)",
}

# Preset voices for Qwen3-TTS CustomVoice (voice cloning capable)
QWEN3_VOICES = {
    "aiden": "Aiden (Male)",
    "ryan": "Ryan (Male)",
    "eric": "Eric (Male)",
    "dylan": "Dylan (Male)",
    "serena": "Serena (Female)",
    "vivian": "Vivian (Female)",
}

# Default venv location
_MLX_VENV = Path.home() / "Library" / "Application Support" / "ScriptToScreen" / "mlx-venv"
_MLX_PYTHON = _MLX_VENV / "bin" / "python3"
_KOKORO_MODEL = "mlx-community/Kokoro-82M-bf16"
_CLONE_MODEL = "mlx-community/chatterbox-fp16"


class MLXAudioVoiceProvider(VoiceProvider):
    """Fast local TTS via MLX-Audio on Apple Silicon.

    Runs in a separate Python 3.12 subprocess because mlx-audio
    requires spacy which doesn't support Python 3.14.
    """

    def __init__(self, voice: str = "af_heart", **kwargs):
        self.voice = voice
        self._python = str(_MLX_PYTHON)

    def test_connection(self) -> bool:
        ok, _ = self.test_connection_details()
        return ok

    def test_connection_details(self) -> tuple[bool, str]:
        """Check if MLX-Audio is installed and working."""
        if not _MLX_PYTHON.exists():
            return False, (
                "MLX-Audio venv not found. Create it with:\n"
                f"  python3.12 -m venv '{_MLX_VENV}'\n"
                f"  '{_MLX_PYTHON}' -m pip install mlx-audio 'misaki[en]'"
            )

        try:
            result = subprocess.run(
                [self._python, "-c", "import mlx_audio; print('OK')"],
                capture_output=True, text=True, timeout=10,
            )
            if "OK" in result.stdout:
                return True, "MLX-Audio ready (Apple Silicon GPU)"
            return False, f"Import failed: {result.stderr[:200]}"
        except Exception as e:
            return False, f"Error: {e}"

    def clone_voice(self, name: str, audio_paths: list[str], **kwargs) -> str:
        """Clone a voice by analyzing the reference audio and storing it.

        Detects the speaker's gender from pitch analysis to select the
        correct base speaker for the Qwen3-TTS CustomVoice model.
        If the reference audio is longer than 30s, trims to first 20s
        to avoid transcription artifacts.

        Returns a voice_id in the format 'clone:<base_speaker>:<ref_audio_path>'
        """
        if not audio_paths:
            raise ValueError("No audio samples provided for voice cloning")

        ref_path = audio_paths[0]
        if not os.path.isfile(ref_path):
            raise FileNotFoundError(f"Voice sample not found: {ref_path}")

        # Detect gender from pitch using a subprocess (needs librosa in mlx-venv)
        base_speaker = "serena"  # default to female
        try:
            result = subprocess.run(
                [self._python, "-c",
                 f"import librosa, numpy as np; "
                 f"y, sr = librosa.load('{ref_path}', sr=None, duration=15); "
                 f"f0 = librosa.yin(y, fmin=50, fmax=500, sr=sr); "
                 f"f0v = f0[f0 > 0]; "
                 f"mf0 = np.mean(f0v) if len(f0v) > 0 else 200; "
                 f"print('MALE' if mf0 < 165 else 'FEMALE')"],
                capture_output=True, text=True, timeout=30,
            )
            gender = result.stdout.strip()
            if gender == "MALE":
                base_speaker = "aiden"
            else:
                base_speaker = "serena"
            logger.info(f"MLX-Audio: detected {gender} voice -> base speaker '{base_speaker}'")
        except Exception as e:
            logger.warning(f"Gender detection failed ({e}), defaulting to '{base_speaker}'")

        # If audio is too long, trim it (avoids transcription hallucinations)
        trimmed_path = ref_path
        try:
            result = subprocess.run(
                [self._python, "-c",
                 f"import librosa; "
                 f"y, sr = librosa.load('{ref_path}', sr=None); "
                 f"print(len(y)/sr)"],
                capture_output=True, text=True, timeout=15,
            )
            duration = float(result.stdout.strip())
            if duration > 30:
                # Trim to first 20 seconds
                import tempfile
                trimmed_path = tempfile.mktemp(suffix=".wav")
                subprocess.run(
                    [self._python, "-c",
                     f"import librosa, soundfile as sf; "
                     f"y, sr = librosa.load('{ref_path}', sr=None, duration=20); "
                     f"sf.write('{trimmed_path}', y, sr)"],
                    capture_output=True, text=True, timeout=30,
                )
                logger.info(f"MLX-Audio: trimmed {duration:.0f}s ref audio to 20s")
        except Exception as e:
            logger.warning(f"Duration check failed ({e}), using original")

        voice_id = f"clone:{base_speaker}:{trimmed_path}"
        logger.info(f"MLX-Audio: voice clone for '{name}' -> {base_speaker}, {os.path.basename(ref_path)}")
        return voice_id

    def generate_speech(
        self,
        voice_id: str,
        text: str,
        save_path: str,
        **kwargs,
    ) -> str:
        """Generate speech using MLX-Audio in a subprocess.

        If voice_id starts with 'clone:', uses the CustomVoice model
        with the reference audio for voice cloning. Otherwise uses
        the Kokoro model with preset voices.
        """
        save_path_wav = save_path
        if not save_path.lower().endswith(".wav"):
            save_path_wav = str(Path(save_path).with_suffix(".wav"))

        import tempfile
        out_dir = tempfile.mkdtemp(prefix="sts_mlx_")

        # Determine model and voice based on voice_id
        if voice_id.startswith("clone:"):
            # Voice cloning mode — Chatterbox uses ref_audio directly
            # Format: clone:<base_speaker>:<ref_audio_path>
            parts = voice_id.split(":", 2)
            if len(parts) == 3:
                _, _base, ref_audio = parts
            elif len(parts) == 2:
                ref_audio = parts[1]
            else:
                raise ValueError(f"Invalid clone voice_id: {voice_id}")
            model_id = _CLONE_MODEL
            voice = "af_heart"  # Chatterbox ignores this when ref_audio is provided
            ref_audio_escaped = ref_audio.replace("\\", "\\\\").replace('"', '\\"')
            ref_audio_arg = f'    ref_audio="{ref_audio_escaped}",\n'
            logger.info(f"MLX-Audio Chatterbox clone: ref={os.path.basename(ref_audio)}")
        else:
            # Preset voice mode — use Kokoro model (faster, no ref audio)
            model_id = _KOKORO_MODEL
            voice = voice_id if voice_id in KOKORO_VOICES else self.voice
            ref_audio_arg = ""
            logger.info(f"MLX-Audio preset voice: {voice} -> {text[:50]}...")

        script = f'''
import os, sys, shutil
from mlx_audio.tts.generate import load_model, generate_audio

model = load_model("{model_id}")
generate_audio(
    model=model,
    text={json.dumps(text)},
    voice="{voice}",
{ref_audio_arg}    output_path="{out_dir}",
)

src = os.path.join("{out_dir}", "audio_000.wav")
if os.path.isfile(src):
    shutil.move(src, "{save_path_wav}")
    print("OK:" + "{save_path_wav}")
else:
    print("ERROR:No audio file generated")
'''

        try:
            result = subprocess.run(
                [self._python, "-c", script],
                capture_output=True, text=True,
                timeout=180,  # 3 min timeout for voice cloning
            )

            shutil.rmtree(out_dir, ignore_errors=True)

            for line in result.stdout.strip().split("\n"):
                if line.startswith("OK:"):
                    actual_path = line[3:]
                    if os.path.isfile(actual_path):
                        size = os.path.getsize(actual_path)
                        logger.info(f"MLX-Audio saved: {actual_path} ({size:,} bytes)")
                        return actual_path
                elif line.startswith("ERROR:"):
                    raise RuntimeError(line[6:])

            if result.returncode != 0:
                err = result.stderr[-500:] if result.stderr else "(no stderr)"
                raise RuntimeError(f"MLX-Audio failed: {err}")

            raise RuntimeError("No audio output from MLX-Audio")

        except subprocess.TimeoutExpired:
            shutil.rmtree(out_dir, ignore_errors=True)
            raise RuntimeError("MLX-Audio generation timed out (>180s)")

    def list_voices(self) -> list[dict]:
        """List available Kokoro preset voices."""
        voices = []
        for voice_id, display_name in KOKORO_VOICES.items():
            voices.append({
                "voice_id": voice_id,
                "name": display_name,
                "language": "en",
                "provider": "mlx_audio",
            })
        return voices
