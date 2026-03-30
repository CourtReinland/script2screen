"""ElevenLabs API client for voice cloning and text-to-speech."""

import logging
import time
from pathlib import Path
from typing import Optional

import requests

from ..utils import RateLimiter

logger = logging.getLogger("ScriptToScreen")

BASE_URL = "https://api.elevenlabs.io/v1"


class ElevenLabsClient:
    """Client for ElevenLabs voice cloning and TTS APIs."""

    def __init__(self, api_key: str):
        self.api_key = api_key
        self.session = requests.Session()
        self.session.headers.update({
            "xi-api-key": api_key,
        })
        self.limiter = RateLimiter(calls_per_minute=20)

    def test_connection(self) -> bool:
        """Test if the API key is valid."""
        ok, _ = self.test_connection_details()
        return ok

    def test_connection_details(self) -> tuple[bool, str]:
        """Test API key and return a user-facing diagnostic message."""
        if not self.api_key or self.api_key.strip() == "":
            return False, "No API key provided"

        try:
            # /models is ElevenLabs' quickstart auth-check endpoint.
            resp = self.session.get(f"{BASE_URL}/models", timeout=10)
        except requests.RequestException as exc:
            return False, f"Network error: {exc}"

        if resp.status_code == 200:
            return True, "Connected to ElevenLabs"
        if resp.status_code == 401:
            # Show key prefix for debugging (first 8 chars)
            key_hint = self.api_key[:8] + "..." if len(self.api_key) > 8 else "(short)"
            logger.error(
                f"ElevenLabs 401: key starts with '{key_hint}', "
                f"length={len(self.api_key)}. "
                f"Response: {resp.text[:200]}"
            )
            return False, f"Invalid API key (starts: {key_hint}, len={len(self.api_key)})"
        if resp.status_code == 403:
            return False, "Forbidden (403): key scope issue"
        if resp.status_code == 404:
            return False, "404 — key may be empty or workspace not found"
        if resp.status_code == 429:
            return False, "Rate limited (429): try again shortly"

        body = (resp.text or "").strip().replace("\n", " ")
        return False, f"HTTP {resp.status_code}: {body[:120]}"

    def list_voices(self) -> list[dict]:
        """List available voices."""
        resp = self.session.get(f"{BASE_URL}/voices", timeout=15)
        resp.raise_for_status()
        data = resp.json()
        return data.get("voices", [])

    # ── Voice Cloning ────────────────────────────────────────────────

    def clone_voice(
        self,
        name: str,
        audio_paths: list[str],
        description: str = "",
        remove_background_noise: bool = True,
    ) -> str:
        """
        Create an instant voice clone from audio samples.

        Args:
            name: Name for the cloned voice.
            audio_paths: List of audio file paths (1-2 min total recommended).
            description: Optional voice description.
            remove_background_noise: Clean audio before cloning.

        Returns:
            voice_id of the newly cloned voice.
        """
        self.limiter.wait()

        files = []
        for path in audio_paths:
            p = Path(path)
            files.append(
                ("files", (p.name, open(path, "rb"), "audio/mpeg"))
            )

        data = {
            "name": name,
            "remove_background_noise": str(remove_background_noise).lower(),
        }
        if description:
            data["description"] = description

        # Use multipart form - don't send JSON content-type
        headers = {"xi-api-key": self.api_key}
        resp = requests.post(
            f"{BASE_URL}/voices/add",
            headers=headers,
            data=data,
            files=files,
            timeout=60,
        )

        # Close file handles
        for _, (_, fh, _) in files:
            fh.close()

        resp.raise_for_status()
        result = resp.json()
        voice_id = result.get("voice_id", "")
        logger.info(f"Voice cloned: {name} -> {voice_id}")
        return voice_id

    def delete_voice(self, voice_id: str) -> bool:
        """Delete a cloned voice."""
        resp = self.session.delete(f"{BASE_URL}/voices/{voice_id}", timeout=15)
        return resp.status_code == 200

    # ── Text-to-Speech ───────────────────────────────────────────────

    def generate_speech(
        self,
        voice_id: str,
        text: str,
        save_path: str,
        model_id: str = "eleven_multilingual_v2",
        stability: float = 0.5,
        similarity_boost: float = 0.75,
        style: float = 0.0,
        speed: float = 1.0,
        output_format: str = "mp3_44100_128",
    ) -> str:
        """
        Generate speech from text using a voice.

        Args:
            voice_id: ElevenLabs voice ID.
            text: Text to speak.
            save_path: Where to save the audio file.
            model_id: TTS model to use.
            stability: Voice consistency (0-1).
            similarity_boost: How closely to match original voice (0-1).
            style: Emotional style intensity (0-1).
            speed: Speaking rate.
            output_format: Audio format string.

        Returns:
            Path to saved audio file.
        """
        self.limiter.wait()

        payload = {
            "text": text,
            "model_id": model_id,
            "voice_settings": {
                "stability": stability,
                "similarity_boost": similarity_boost,
                "style": style,
            },
        }

        headers = {
            "xi-api-key": self.api_key,
            "Content-Type": "application/json",
            "Accept": "audio/mpeg",
        }

        url = f"{BASE_URL}/text-to-speech/{voice_id}"
        params = {"output_format": output_format}

        for attempt in range(3):
            resp = requests.post(
                url, json=payload, headers=headers, params=params, timeout=60
            )
            if resp.status_code == 429:
                wait = 2 ** (attempt + 1)
                logger.warning(f"Rate limited, waiting {wait}s...")
                time.sleep(wait)
                continue
            resp.raise_for_status()
            break

        with open(save_path, "wb") as f:
            f.write(resp.content)

        logger.info(f"Speech generated: {save_path} ({len(resp.content)} bytes)")
        return save_path

    def generate_speech_test(self, voice_id: str, text: str = "Hello, this is a voice test.") -> bytes:
        """Generate a short test speech clip, returning raw audio bytes."""
        self.limiter.wait()

        payload = {
            "text": text,
            "model_id": "eleven_multilingual_v2",
            "voice_settings": {
                "stability": 0.5,
                "similarity_boost": 0.75,
            },
        }

        headers = {
            "xi-api-key": self.api_key,
            "Content-Type": "application/json",
            "Accept": "audio/mpeg",
        }

        resp = requests.post(
            f"{BASE_URL}/text-to-speech/{voice_id}",
            json=payload,
            headers=headers,
            timeout=30,
        )
        resp.raise_for_status()
        return resp.content
