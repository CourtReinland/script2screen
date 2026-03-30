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

# Available preset voices in Kokoro
KOKORO_VOICES = {
    # American English - Female
    "af_heart": "Heart (Female, American)",
    "af_bella": "Bella (Female, American)",
    "af_nova": "Nova (Female, American)",
    "af_sky": "Sky (Female, American)",
    # American English - Male
    "am_adam": "Adam (Male, American)",
    "am_echo": "Echo (Male, American)",
    # British English - Female
    "bf_alice": "Alice (Female, British)",
    "bf_emma": "Emma (Female, British)",
    # British English - Male
    "bm_daniel": "Daniel (Male, British)",
    "bm_george": "George (Male, British)",
}

# Default venv location
_MLX_VENV = Path.home() / "Library" / "Application Support" / "ScriptToScreen" / "mlx-venv"
_MLX_PYTHON = _MLX_VENV / "bin" / "python3"
_MODEL_ID = "mlx-community/Kokoro-82M-bf16"


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
        """Voice cloning via reference audio (Kokoro supports this via CSM).

        For now, returns a preset voice ID. Full voice cloning with
        reference audio requires the CSM model.
        """
        # Map common character names to fitting preset voices
        name_upper = name.upper()
        if any(f in name_upper for f in ["GIRL", "WOMAN", "FEMALE", "MOM", "MOTHER",
                                          "ALIYAH", "LISA", "LAUREN"]):
            voice_id = "af_bella"
        elif any(m in name_upper for m in ["BOY", "MAN", "MALE", "DAD", "FATHER",
                                            "AIDEN", "MAX", "ETHAN"]):
            voice_id = "am_adam"
        else:
            voice_id = "af_heart"  # default

        logger.info(f"MLX-Audio: mapped '{name}' to preset voice '{voice_id}'")
        return voice_id

    def generate_speech(
        self,
        voice_id: str,
        text: str,
        save_path: str,
        **kwargs,
    ) -> str:
        """Generate speech using MLX-Audio in a subprocess.

        Runs in the Python 3.12 venv since mlx-audio needs spacy.
        """
        # Ensure .wav extension
        save_path_wav = save_path
        if not save_path.lower().endswith(".wav"):
            save_path_wav = str(Path(save_path).with_suffix(".wav"))

        # Use voice_id as Kokoro voice name, fallback to default
        voice = voice_id if voice_id in KOKORO_VOICES else self.voice

        # Create temp output directory for mlx-audio
        import tempfile
        out_dir = tempfile.mkdtemp(prefix="sts_mlx_")

        # Build Python script to run in subprocess
        script = f'''
import os, sys, shutil
from mlx_audio.tts.generate import load_model, generate_audio

model = load_model("{_MODEL_ID}")
generate_audio(
    model=model,
    text={json.dumps(text)},
    voice="{voice}",
    output_path="{out_dir}",
)

# Move the generated file to the target path
src = os.path.join("{out_dir}", "audio_000.wav")
if os.path.isfile(src):
    shutil.move(src, "{save_path_wav}")
    print("OK:" + "{save_path_wav}")
else:
    print("ERROR:No audio file generated")
'''

        logger.info(f"MLX-Audio generating: {text[:60]}... (voice={voice})")

        try:
            result = subprocess.run(
                [self._python, "-c", script],
                capture_output=True, text=True,
                timeout=120,  # 2 minute timeout (MLX is fast)
            )

            # Clean up temp dir
            shutil.rmtree(out_dir, ignore_errors=True)

            # Parse result
            for line in result.stdout.strip().split("\n"):
                if line.startswith("OK:"):
                    actual_path = line[3:]
                    if os.path.isfile(actual_path):
                        size = os.path.getsize(actual_path)
                        logger.info(f"MLX-Audio speech saved: {actual_path} ({size:,} bytes)")
                        return actual_path
                elif line.startswith("ERROR:"):
                    raise RuntimeError(line[6:])

            # If we get here, check stderr
            if result.returncode != 0:
                raise RuntimeError(f"MLX-Audio subprocess failed: {result.stderr[:300]}")

            raise RuntimeError("No audio output from MLX-Audio")

        except subprocess.TimeoutExpired:
            shutil.rmtree(out_dir, ignore_errors=True)
            raise RuntimeError("MLX-Audio generation timed out (>120s)")

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
