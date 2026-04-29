"""REST client for Anthropic's Claude messages API.

Anthropic's schema differs from OpenAI's: ``system`` is a top-level
field (not a message role), the auth header is ``x-api-key``, and an
``anthropic-version`` header is required. The response shape also
differs — text lives at ``content[0].text`` instead of
``choices[0].message.content``.

Default model is the Sonnet 4.5 family — fast and cheap enough for
screenplay parsing while strong enough to follow the JSON-extraction
contract reliably.
"""

import json
import logging
from typing import Optional

import requests

logger = logging.getLogger("ScriptToScreen")

BASE_URL = "https://api.anthropic.com/v1"
ANTHROPIC_VERSION = "2023-06-01"
DEFAULT_MODEL = "claude-sonnet-4-5"


class ClaudeTextClient:
    """Low-level HTTP wrapper for Anthropic /v1/messages."""

    def __init__(self, api_key: str, model: str = DEFAULT_MODEL):
        self.api_key = api_key
        self.model = model
        self._session = requests.Session()
        self._session.headers.update({
            "x-api-key": api_key,
            "anthropic-version": ANTHROPIC_VERSION,
            "Content-Type": "application/json",
        })

    # ------------------------------------------------------------------
    # Connection test
    # ------------------------------------------------------------------

    def test_connection_details(self) -> tuple[bool, str]:
        """Hit a tiny chat to verify credentials. Anthropic doesn't
        publish a free /models listing, so we send a 1-token ping.
        """
        try:
            r = self._session.post(
                f"{BASE_URL}/messages",
                json={
                    "model": self.model,
                    "max_tokens": 1,
                    "messages": [{"role": "user", "content": "ping"}],
                },
                timeout=15,
            )
            if r.status_code == 200:
                return True, f"Connected to Anthropic Claude API ({self.model})"
            elif r.status_code == 401:
                return False, "Invalid Anthropic API key"
            elif r.status_code == 403:
                return False, "Access forbidden — check API plan"
            elif r.status_code == 404:
                return False, f"Model {self.model} not available on this key"
            return True, f"Anthropic API responded (HTTP {r.status_code})"
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
        """Send a message and return the assistant's text response.

        ``json_mode=True`` doesn't have a dedicated Anthropic toggle the
        way OpenAI does (no ``response_format=json``). We instead append
        a strong "Return ONLY valid JSON, no prose" rider to the system
        prompt; Sonnet/Opus follow it reliably for screenplay extraction.
        """
        sys = system_prompt
        if json_mode:
            sys = (
                system_prompt.rstrip()
                + "\n\nIMPORTANT: Return ONLY a valid JSON object. "
                "No prose, no markdown fences, no explanation — just the JSON."
            )

        body: dict = {
            "model": model or self.model,
            "max_tokens": max_tokens,
            "temperature": temperature,
            "system": sys,
            "messages": [
                {"role": "user", "content": user_prompt},
            ],
        }

        logger.info(
            f"[ClaudeText] POST /messages  model={body['model']}  json={json_mode}"
        )

        r = self._session.post(f"{BASE_URL}/messages", json=body, timeout=180)

        if r.status_code != 200:
            logger.error(f"[ClaudeText] chat failed: {r.status_code} {r.text[:400]}")
            raise RuntimeError(
                f"Anthropic API error (HTTP {r.status_code}): {r.text[:300]}"
            )

        data = r.json()

        try:
            # Anthropic returns content as a list of typed blocks; we want the
            # text block(s) concatenated.
            blocks = data.get("content") or []
            text = "".join(b.get("text", "") for b in blocks if b.get("type") == "text")
            if not text:
                raise KeyError("no text blocks in content")
        except (KeyError, IndexError, TypeError) as e:
            raise RuntimeError(f"Unexpected Anthropic response shape: {data}") from e

        logger.info(f"[ClaudeText] Response length: {len(text)} chars")
        return text
