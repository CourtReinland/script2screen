"""Voicebox REST API client for local voice cloning and TTS."""

import logging
import os
import re
import struct
import time
import wave
from pathlib import Path
from typing import Optional

import requests

logger = logging.getLogger("ScriptToScreen")

DEFAULT_URL = "http://127.0.0.1:17493"


class VoiceboxClient:
    """Client for the Voicebox local voice synthesis API."""

    def __init__(self, server_url: str = DEFAULT_URL):
        self.server_url = server_url.rstrip("/")
        self.session = requests.Session()

    # ── Connection ──────────────────────────────────────────────────

    def test_connection(self) -> bool:
        ok, _ = self.test_connection_details()
        return ok

    def test_connection_details(self) -> tuple[bool, str]:
        """Test connection and return diagnostic info."""
        try:
            resp = self.session.get(
                f"{self.server_url}/health", timeout=5
            )
            if resp.status_code == 200:
                data = resp.json()
                gpu = data.get("gpu_type", "CPU")
                backend = data.get("backend_type", "unknown")
                model_loaded = data.get("model_loaded", False)
                status = "model loaded" if model_loaded else "no model loaded"
                return True, f"Connected — {gpu} ({backend}), {status}"
            return False, f"HTTP {resp.status_code}"
        except requests.ConnectionError:
            return False, (
                "Cannot connect to Voicebox. "
                "Start it with: cd ~/voicebox && ./start_voicebox.sh"
            )
        except Exception as e:
            return False, str(e)

    # ── Model Management ────────────────────────────────────────────

    def get_models_status(self) -> list[dict]:
        """Get status of all available TTS models."""
        resp = self.session.get(
            f"{self.server_url}/models/status", timeout=10
        )
        resp.raise_for_status()
        return resp.json().get("models", [])

    def download_model(self, model_name: str) -> dict:
        """Trigger a model download. Returns immediately."""
        resp = self.session.post(
            f"{self.server_url}/models/download",
            json={"model_name": model_name},
            timeout=10,
        )
        resp.raise_for_status()
        return resp.json()

    def ensure_model_available(self, model_name: str = "qwen-tts-1.7B") -> bool:
        """Check if a model is downloaded, trigger download if not."""
        models = self.get_models_status()
        for m in models:
            if m["model_name"] == model_name:
                if m["downloaded"]:
                    return True
                if not m["downloading"]:
                    self.download_model(model_name)
                return False
        return False

    def load_model(self, engine: str = "qwen", model_size: str = "1.7B") -> dict:
        """Load a TTS model into memory. Required before generation."""
        resp = self.session.post(
            f"{self.server_url}/models/load",
            json={"engine": engine, "model_size": model_size},
            timeout=120,  # Model loading can take a while
        )
        resp.raise_for_status()
        return resp.json()

    def ensure_model_loaded(self, engine: str = "qwen", model_size: str = "1.7B") -> bool:
        """Check if a model is loaded; load it if not. Returns True when ready."""
        try:
            resp = self.session.get(f"{self.server_url}/health", timeout=5)
            if resp.status_code == 200:
                data = resp.json()
                if data.get("model_loaded", False):
                    return True
            # Model not loaded — try to load it
            logger.info(f"Voicebox model not loaded, loading {engine} {model_size}...")
            self.load_model(engine, model_size)
            return True
        except Exception as e:
            logger.warning(f"Could not load Voicebox model: {e}")
            return False

    # ── Audio Validation ──────────────────────────────────────────

    @staticmethod
    def _validate_and_repair_wav(path: str) -> bool:
        """Validate a WAV file and attempt to repair if malformed.

        Common issues from streaming endpoints:
        - Missing or truncated RIFF header
        - Incorrect data chunk size (set to 0 or max int)
        - Raw PCM data without any header

        Returns True if the file is valid (or was successfully repaired).
        """
        try:
            with wave.open(path, "r") as w:
                frames = w.getnframes()
                rate = w.getframerate()
                duration = frames / rate if rate > 0 else 0
                if duration > 0.1:
                    logger.debug(f"WAV valid: {path} ({duration:.1f}s, {rate}Hz)")
                    return True
                logger.warning(f"WAV too short ({duration:.3f}s): {path}")
        except Exception as e:
            logger.warning(f"WAV validation failed for {path}: {e}")

        # Attempt repair: re-read raw bytes and write a proper WAV
        try:
            with open(path, "rb") as f:
                raw = f.read()

            if len(raw) < 100:
                logger.error(f"WAV file too small to repair ({len(raw)} bytes): {path}")
                return False

            # Find where PCM data starts — skip RIFF header if present
            pcm_data = raw
            if raw[:4] == b"RIFF":
                # Try to find the "data" sub-chunk
                idx = raw.find(b"data")
                if idx >= 0 and idx + 8 < len(raw):
                    pcm_data = raw[idx + 8:]  # skip "data" + 4-byte size
                    logger.info(f"Extracted PCM from WAV header at offset {idx + 8}")
                else:
                    # Header exists but malformed — skip standard 44-byte header
                    pcm_data = raw[44:] if len(raw) > 44 else raw
                    logger.info("Skipping standard 44-byte WAV header")

            if len(pcm_data) < 100:
                logger.error(f"Not enough PCM data to repair: {len(pcm_data)} bytes")
                return False

            # Re-write as proper WAV (assume 24kHz mono 16-bit — Qwen TTS default)
            sample_rate = 24000
            channels = 1
            sample_width = 2  # 16-bit

            # Ensure PCM data length is even (16-bit samples)
            if len(pcm_data) % 2 != 0:
                pcm_data = pcm_data[:-1]

            backup = path + ".bak"
            os.rename(path, backup)

            with wave.open(path, "w") as w:
                w.setnchannels(channels)
                w.setsampwidth(sample_width)
                w.setframerate(sample_rate)
                w.writeframes(pcm_data)

            os.remove(backup)

            # Verify the repair
            with wave.open(path, "r") as w:
                duration = w.getnframes() / w.getframerate()
            logger.info(f"WAV repaired: {path} ({duration:.1f}s, {sample_rate}Hz)")
            return duration > 0.1

        except Exception as e:
            logger.error(f"WAV repair failed for {path}: {e}")
            # Restore backup if it exists
            backup = path + ".bak"
            if os.path.exists(backup):
                if os.path.exists(path):
                    os.remove(path)
                os.rename(backup, path)
            return False

    # ── Voice Profiles ──────────────────────────────────────────────

    def list_profiles(self) -> list[dict]:
        """List all voice profiles."""
        resp = self.session.get(
            f"{self.server_url}/profiles", timeout=10
        )
        resp.raise_for_status()
        return resp.json()

    def create_profile(self, name: str, language: str = "en") -> dict:
        """Create a new voice profile."""
        resp = self.session.post(
            f"{self.server_url}/profiles",
            json={"name": name, "language": language},
            timeout=10,
        )
        resp.raise_for_status()
        return resp.json()

    @staticmethod
    def get_wav_duration(audio_path: str) -> float:
        """Get duration of a WAV file in seconds. Returns 0 for non-WAV."""
        try:
            with wave.open(audio_path, "r") as w:
                return w.getnframes() / w.getframerate()
        except Exception:
            return 0.0

    @staticmethod
    def _reference_text_from_filename(audio_path: str) -> str:
        """Derive a reference text from the filename when none provided.

        E.g., "Aiden find the cormorant.wav" → "find the cormorant"
        """
        stem = Path(audio_path).stem  # "Aiden find the cormorant"
        # Remove common prefixes like character names (any single word followed by space)
        cleaned = re.sub(r"^[A-Za-z]+\s+", "", stem)  # "aiden hello" → "hello"
        # Replace underscores with spaces
        cleaned = cleaned.replace("_", " ").strip()
        # If cleaning removed everything, use the full stem
        if not cleaned or len(cleaned) < 2:
            cleaned = stem.replace("_", " ").strip()
        return cleaned

    def add_sample(
        self,
        profile_id: str,
        audio_path: str,
        reference_text: str = "",
    ) -> dict:
        """Upload an audio sample to a voice profile for cloning.

        If reference_text is empty, auto-generates it from the filename.
        Validates audio duration (minimum 2.0 seconds required by Voicebox).
        """
        p = Path(audio_path)

        # Check WAV duration (Voicebox requires ≥ 2.0 seconds)
        if p.suffix.lower() == ".wav":
            duration = self.get_wav_duration(audio_path)
            if 0 < duration < 2.0:
                raise ValueError(
                    f"Audio too short ({duration:.1f}s). "
                    f"Voicebox requires at least 2.0 seconds. File: {p.name}"
                )

        # Auto-generate reference_text from filename if empty
        if not reference_text or not reference_text.strip():
            reference_text = self._reference_text_from_filename(audio_path)
            logger.info(f"Auto-generated reference text: '{reference_text}'")

        # Determine MIME type
        mime_map = {
            ".wav": "audio/wav",
            ".mp3": "audio/mpeg",
            ".m4a": "audio/mp4",
            ".ogg": "audio/ogg",
            ".flac": "audio/flac",
            ".aac": "audio/aac",
            ".webm": "audio/webm",
            ".opus": "audio/opus",
        }
        mime = mime_map.get(p.suffix.lower(), "audio/mpeg")

        with open(audio_path, "rb") as f:
            resp = self.session.post(
                f"{self.server_url}/profiles/{profile_id}/samples",
                files={"file": (p.name, f, mime)},
                data={"reference_text": reference_text},
                timeout=60,
            )
        resp.raise_for_status()
        return resp.json()

    def get_profile(self, profile_id: str) -> dict:
        """Get a profile by ID."""
        resp = self.session.get(
            f"{self.server_url}/profiles/{profile_id}", timeout=10
        )
        resp.raise_for_status()
        return resp.json()

    # ── Speech Generation ───────────────────────────────────────────

    def generate_speech(
        self,
        profile_id: str,
        text: str,
        language: str = "en",
        engine: str = "qwen",
        model_size: str = "1.7B",
        seed: Optional[int] = None,
    ) -> dict:
        """
        Submit a speech generation request (async).

        Returns a generation dict with 'id' and 'status'.
        The generation runs in the background; poll with check_generation().
        """
        payload = {
            "profile_id": profile_id,
            "text": text,
            "language": language,
            "engine": engine,
            "model_size": model_size,
        }
        if seed is not None:
            payload["seed"] = seed

        resp = self.session.post(
            f"{self.server_url}/generate",
            json=payload,
            timeout=30,
        )
        resp.raise_for_status()
        return resp.json()

    def generate_speech_stream(
        self,
        profile_id: str,
        text: str,
        save_path: str,
        language: str = "en",
        engine: str = "qwen",
        model_size: str = "1.7B",
    ) -> str:
        """
        Generate speech and stream WAV directly to a file (synchronous).

        Returns the save_path.
        """
        payload = {
            "profile_id": profile_id,
            "text": text,
            "language": language,
            "engine": engine,
            "model_size": model_size,
        }

        resp = self.session.post(
            f"{self.server_url}/generate/stream",
            json=payload,
            timeout=None,  # No timeout — CPU-mode TTS can take 60-120+ seconds per phrase
            stream=True,
        )
        resp.raise_for_status()

        with open(save_path, "wb") as f:
            for chunk in resp.iter_content(8192):
                f.write(chunk)

        # The streaming endpoint produces valid WAV files.
        # Do NOT run _validate_and_repair_wav here — it can corrupt
        # valid streaming WAV files by misinterpreting header sizes.
        file_size = os.path.getsize(save_path)
        logger.info(f"Voicebox speech saved: {save_path} ({file_size:,} bytes)")
        return save_path

    def check_generation(self, generation_id: str) -> dict:
        """Check generation status by fetching from history."""
        resp = self.session.get(
            f"{self.server_url}/history/{generation_id}", timeout=10
        )
        resp.raise_for_status()
        return resp.json()

    def download_audio(self, generation_id: str, save_path: str) -> str:
        """Download generated audio to a file.

        Voicebox may mark generations as 'completed' before the audio_path
        DB field is updated, causing /audio/{id} to return 500.  We retry
        a few times with a short delay to handle this race condition.
        """
        last_err = None
        for attempt in range(6):
            try:
                resp = self.session.get(
                    f"{self.server_url}/audio/{generation_id}",
                    timeout=60,
                    stream=True,
                )
                resp.raise_for_status()

                with open(save_path, "wb") as f:
                    for chunk in resp.iter_content(8192):
                        f.write(chunk)

                # Validate and repair the WAV if needed
                if save_path.lower().endswith(".wav"):
                    self._validate_and_repair_wav(save_path)

                return save_path

            except Exception as e:
                last_err = e
                if attempt < 5:
                    logger.info(
                        f"Audio download attempt {attempt + 1} failed, "
                        f"retrying in 5s... ({e})"
                    )
                    time.sleep(5)

        raise RuntimeError(
            f"Could not download audio after 6 attempts: {last_err}"
        )

    def poll_generation(
        self,
        generation_id: str,
        timeout: int = 300,
        interval: int = 2,
    ) -> dict:
        """Poll until generation completes or fails.

        Voicebox may briefly report 'completed' before the audio_path is
        populated in the DB. We require both status='completed' AND a
        non-empty audio_path before returning.
        """
        start = time.time()
        while time.time() - start < timeout:
            gen = self.check_generation(generation_id)
            status = gen.get("status", "")

            if status == "failed":
                error = gen.get("error", "Unknown error")
                raise RuntimeError(f"Voicebox generation failed: {error}")

            if status == "completed":
                audio_path = gen.get("audio_path", "")
                if audio_path:
                    return gen
                # Status is completed but no audio_path yet — keep waiting
                logger.debug(
                    f"Generation {generation_id} completed but audio_path "
                    f"not yet populated, waiting..."
                )

            time.sleep(interval)

        raise TimeoutError(
            f"Voicebox generation {generation_id} timed out after {timeout}s"
        )
