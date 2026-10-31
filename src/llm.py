"""
Module: llm.py
Description: Ollama chat client with granular timeout configuration and
             explicit handling for connect/read failures.
Citations:
- Ollama chat API: https://github.com/ollama/ollama/blob/main/docs/api.md#chat-request-and-response
- HTTPX exceptions: https://www.python-httpx.org/exceptions/
"""

import logging

import httpx

from src.config import settings

logger = logging.getLogger(__name__)


class OllamaChatClient:
    """
    Client for grounded chat completions via Ollama.
    """

    def __init__(self) -> None:
        self.client = httpx.Client(
            base_url=settings.ollama_base_url,
            timeout=httpx.Timeout(
                settings.request_timeout,
                connect=settings.connect_timeout,
            ),
            limits=httpx.Limits(
                max_connections=settings.max_connections,
                max_keepalive_connections=settings.max_keepalive_connections,
            ),
        )

    def generate_answer(self, prompt: str) -> str:
        payload = {
            "model": settings.chat_model,
            "messages": [
                {"role": "system", "content": settings.system_prompt},
                {"role": "user", "content": prompt},
            ],
            "stream": False,
        }

        try:
            response = self.client.post("/api/chat", json=payload)
            response.raise_for_status()
            data = response.json()
            return data.get("message", {}).get("content", "").strip()
        except httpx.HTTPStatusError as exc:
            logger.error(
                "HTTP %s during chat: %s",
                exc.response.status_code,
                exc.response.text,
            )
            raise
        except (httpx.ConnectError, httpx.ReadTimeout, httpx.ConnectTimeout) as exc:
            logger.error("Ollama chat service unreachable: %s", exc)
            raise
        except httpx.RequestError as exc:
            logger.error("Network error during chat: %s", exc)
            raise

    def close(self) -> None:
        self.client.close()
