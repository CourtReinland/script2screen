"""Anthropic Claude text provider — implements TextProvider."""

import logging

from .providers import TextProvider
from .claude_text_client import ClaudeTextClient, DEFAULT_MODEL

logger = logging.getLogger("ScriptToScreen")


class ClaudeTextProvider(TextProvider):
    """Anthropic Claude messages provider.

    Uses ``config.providers.claude.apiKey`` (a new entry — Step 1 of the
    wizard surfaces it the same way as the OpenAI key). Defaults to
    ``claude-sonnet-4-5``; the standalone tools / wizard can override
    via ``model=`` kwarg.
    """

    def __init__(self, api_key: str = "", server_url: str = "", **kwargs):
        model = kwargs.get("model", DEFAULT_MODEL)
        self._client = ClaudeTextClient(api_key, model=model)

    def test_connection(self) -> bool:
        ok, _ = self._client.test_connection_details()
        return ok

    def test_connection_details(self) -> tuple[bool, str]:
        return self._client.test_connection_details()

    def generate_text(
        self,
        system_prompt: str,
        user_prompt: str,
        max_tokens: int = 4096,
        temperature: float = 0.7,
        response_format: str = "text",
        **kwargs,
    ) -> str:
        return self._client.chat(
            system_prompt=system_prompt,
            user_prompt=user_prompt,
            max_tokens=max_tokens,
            temperature=temperature,
            json_mode=(response_format == "json"),
            model=kwargs.get("model"),
        )
