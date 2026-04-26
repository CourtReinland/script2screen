"""ElevenLabs as VoiceProvider."""

from .providers import VoiceProvider
from .elevenlabs_client import ElevenLabsClient


class ElevenLabsVoiceProvider(VoiceProvider):
    """Wraps ElevenLabsClient for the VoiceProvider interface."""

    def __init__(self, api_key: str, model_id: str = "eleven_multilingual_v2",
                 **kwargs):
        self._client = ElevenLabsClient(api_key)
        self.model_id = model_id

    def test_connection(self) -> bool:
        return self._client.test_connection()

    def test_connection_details(self) -> tuple[bool, str]:
        return self._client.test_connection_details()

    def clone_voice(self, name, audio_paths, **kwargs) -> str:
        return self._client.clone_voice(
            name=name,
            audio_paths=audio_paths,
            description=kwargs.get("description", ""),
            remove_background_noise=kwargs.get("remove_background_noise", True),
        )

    def generate_speech(self, voice_id, text, save_path, **kwargs) -> str:
        return self._client.generate_speech(
            voice_id=voice_id,
            text=text,
            save_path=save_path,
            model_id=kwargs.get("model_id", self.model_id),
            stability=kwargs.get("stability", 0.5),
            similarity_boost=kwargs.get("similarity_boost", 0.75),
            style=kwargs.get("style", 0.0),
            speed=kwargs.get("speed", 1.0),
        )

    def list_voices(self) -> list[dict]:
        return self._client.list_voices()
