"""
Module: config.py
Description: Centralized configuration management using Pydantic Settings.
             Adds embedding dimension, SQLite concurrency, HTTP granular
             timeouts, and nomic task-prefix configuration.
Citations:
- Pydantic Settings: https://docs.pydantic.dev/latest/concepts/pydantic_settings/
- nomic prefixes: https://huggingface.co/nomic-ai/nomic-embed-text-v1.5#usage
"""

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """
    Configuration schema bound to environment variables with prefix RAG_.
    """
    model_config = SettingsConfigDict(
        env_prefix="RAG_",
        env_file=".env",
        extra="ignore",
    )

    # Ollama service
    ollama_base_url: str = "http://localhost:11434"
    request_timeout: float = 30.0
    connect_timeout: float = 5.0
    max_connections: int = 10
    max_keepalive_connections: int = 5

    # Models
    embedding_model: str = "nomic-embed-text"
    embedding_dim: int = 768
    chat_model: str = "qwen2.5:7b-instruct"

    # nomic-embed-text requires task prefixes for optimal retrieval.
    # Documents: "search_document: <text>"
    # Queries:    "search_query: <text>"
    embedding_document_prefix: str = "search_document: "
    embedding_query_prefix: str = "search_query: "

    # Storage
    db_path: str = "vector_store.db"
    sqlite_busy_timeout_ms: int = 5000

    # Chunking
    chunk_size: int = 400
    chunk_overlap: int = 50

    # Retrieval
    top_k: int = 3
    distance_metric: str = "cosine"  # l2 | cosine | hamming

    # LLM system prompt
    system_prompt: str = (
        "You are a precise corporate assistant. Answer questions strictly "
        "using the provided context. If the answer cannot be found in the "
        "context, state 'I cannot answer this based on available documentation'."
    )


settings = Settings()
