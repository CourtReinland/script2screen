"""REST client for the xAI Grok chat/completions API.

This is separate from grok_client.py (which handles image/video) to keep
concerns clean.  Grok's chat endpoint is OpenAI-compatible.
"""

import json
import logging
from typing import Optional

import requests

logger = logging.getLogger("ScriptToScreen")

BASE_URL = "https://api.x.ai/v1"
DEFAULT_MODEL = "grok-4-latest"


class GrokTextClient:
    """Low-level HTTP wrapper for xAI chat completions."""

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
        """Verify credentials by listing available models."""
        try:
            r = self._session.get(f"{BASE_URL}/models", timeout=15)
            if r.status_code == 200:
                return True, f"Connected to Grok chat API ({self.model})"
            elif r.status_code == 401:
                return False, "Invalid Grok API key"
            elif r.status_code == 403:
                return False, "Access forbidden — check API plan"
            return True, f"Grok API responded (HTTP {r.status_code})"
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

        Args:
            system_prompt: System-level instructions for the LLM.
            user_prompt: The user's message (task input).
            max_tokens: Upper bound on generated tokens.
            temperature: Sampling temperature (0-2).
            json_mode: If True, ask the LLM to return valid JSON.
            model: Override the default model for this call.

        Returns:
            The assistant's response as a string.
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

        logger.info(f"[GrokText] POST /chat/completions  model={body['model']}  json={json_mode}")

        r = self._session.post(
            f"{BASE_URL}/chat/completions",
            json=body,
            timeout=120,
        )

        if r.status_code != 200:
            logger.error(f"[GrokText] chat failed: {r.status_code} {r.text[:400]}")
            raise RuntimeError(
                f"Grok chat API error (HTTP {r.status_code}): "
                f"{r.text[:300]}"
            )

        data = r.json()

        try:
            text = data["choices"][0]["message"]["content"]
        except (KeyError, IndexError) as e:
            raise RuntimeError(f"Unexpected Grok response shape: {data}") from e

        logger.info(f"[GrokText] Response length: {len(text)} chars")
        return text
