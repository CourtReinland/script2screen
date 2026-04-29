"""REST client for OpenAI's chat completions API.

Mirrors the shape of grok_text_client.py — Grok exposes the same
OpenAI-compatible /chat/completions schema, so the only differences
here are the base URL, the auth header, and the default model id.
"""

import json
import logging
from typing import Optional

import requests

logger = logging.getLogger("ScriptToScreen")

BASE_URL = "https://api.openai.com/v1"
DEFAULT_MODEL = "gpt-4o-mini"


class OpenAITextClient:
    """Low-level HTTP wrapper for OpenAI chat completions."""

    def __init__(self, api_key: str, model: str = DEFAULT_MODEL):
        self.api_key = api_key
        self.model = model
        self._session = requests.Session()
        self._session.headers.update({
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        })

    # ------------------------------------------------------------------
    # Connection test
    # ------------------------------------------------------------------

    def test_connection_details(self) -> tuple[bool, str]:
        """Verify credentials by hitting /models."""
        try:
            r = self._session.get(f"{BASE_URL}/models", timeout=15)
            if r.status_code == 200:
                return True, f"Connected to OpenAI chat API ({self.model})"
            elif r.status_code == 401:
                return False, "Invalid OpenAI API key"
            elif r.status_code == 403:
                return False, "Access forbidden — check API plan / org verification"
            return True, f"OpenAI API responded (HTTP {r.status_code})"
        except requests.RequestException as e:
            return False, f"Connection error: {e}"

    # ------------------------------------------------------------------
    # Chat completion
    # ------------------------------------------------------------------

    def chat(
        self,
        system_prompt: str,
        user_prompt: str,
        max_tokens: int = 4096,
        temperature: float = 0.7,
        json_mode: bool = False,
        model: Optional[str] = None,
    ) -> str:
        """Send a chat completion and return the assistant's text response.

        ``json_mode=True`` requests ``response_format=json_object`` so the
        screenplay-extraction call is guaranteed to come back parseable.
        """
        body: dict = {
            "model": model or self.model,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_prompt},
            ],
            "max_tokens": max_tokens,
            "temperature": temperature,
        }

        if json_mode:
            body["response_format"] = {"type": "json_object"}

        logger.info(
            f"[OpenAIText] POST /chat/completions  model={body['model']}  json={json_mode}"
        )

        r = self._session.post(
            f"{BASE_URL}/chat/completions",
            json=body,
            timeout=180,
        )

        if r.status_code != 200:
            logger.error(f"[OpenAIText] chat failed: {r.status_code} {r.text[:400]}")
            raise RuntimeError(
                f"OpenAI chat API error (HTTP {r.status_code}): {r.text[:300]}"
            )

        data = r.json()

        try:
            text = data["choices"][0]["message"]["content"]
        except (KeyError, IndexError) as e:
            raise RuntimeError(f"Unexpected OpenAI response shape: {data}") from e

        logger.info(f"[OpenAIText] Response length: {len(text)} chars")
        return text
