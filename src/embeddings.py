"""
Module: embeddings.py
Description: Ollama embedding client using the current /api/embed endpoint
             (batch input, L2-normalized output). Applies nomic task prefixes
             and handles transient HTTP failures explicitly.
Citations:
- Ollama /api/embed: https://docs.ollama.com/api/embed
- nomic prefixes: https://huggingface.co/nomic-ai/nomic-embed-text-v1.5#usage
- HTTPX exceptions: https://www.python-httpx.org/exceptions/
"""

import logging
import time
from typing import List

import httpx
import numpy as np

from src.config import settings

logger = logging.getLogger(__name__)

_RETRYABLE = (httpx.ConnectError, httpx.ReadTimeout, httpx.ConnectTimeout)


class OllamaEmbeddingClient:
    """
    Client for generating L2-normalized float32 embeddings via Ollama.
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

    def _embed(self, inputs: List[str], prefix: str) -> List[np.ndarray]:
        """
        Send a batch of inputs to /api/embed and return normalized vectors.
        """
        payload = {
            "model": settings.embedding_model,
            "input": [prefix + text for text in inputs],
        }

        for attempt in range(3):
            try:
                response = self.client.post("/api/embed", json=payload)
                response.raise_for_status()
                data = response.json()
                vectors = data.get("embeddings", [])
                if len(vectors) != len(inputs):
                    raise RuntimeError(
                        f"Expected {len(inputs)} embeddings, received {len(vectors)}"
                    )
                return [self._normalize(np.asarray(v, dtype=np.float32)) for v in vectors]
            except _RETRYABLE as exc:
                if attempt == 2:
                    logger.error("Embedding request failed after retries: %s", exc)
                    raise
                wait = 0.5 * (2 ** attempt)
                logger.warning("Embedding request failed (%s). Retrying in %.1fs", exc, wait)
                time.sleep(wait)
            except httpx.HTTPStatusError as exc:
                logger.error(
                    "HTTP %s during embedding: %s",
                    exc.response.status_code,
                    exc.response.text,
                )
                raise
            except httpx.RequestError as exc:
                logger.error("Network error during embedding: %s", exc)
                raise

        raise RuntimeError("Unreachable")  # pragma: no cover

    @staticmethod
    def _normalize(vector: np.ndarray) -> np.ndarray:
        norm = np.linalg.norm(vector)
        if norm > 0:
            vector = vector / norm
        return vector

    def generate_document_embeddings(self, texts: List[str]) -> List[np.ndarray]:
        """Embed document chunks with the nomic search_document prefix."""
        return self._embed(texts, settings.embedding_document_prefix)

    def generate_query_embedding(self, text: str) -> np.ndarray:
        """Embed a user query with the nomic search_query prefix."""
        return self._embed([text], settings.embedding_query_prefix)[0]

    def close(self) -> None:
        self.client.close()
