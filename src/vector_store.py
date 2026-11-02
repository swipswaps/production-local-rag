"""
Module: vector_store.py
Description: Persistent vector store using SQLite and sqlite-vec. Fixes the
             KNN query to use k = ? inside a subquery, enables WAL mode and
             busy timeout, validates dimensions, and uses explicit transactions.
Citations:
- sqlite-vec KNN queries: https://github.com/asg017/sqlite-vec/blob/main/site/features/knn.md
- SQLite WAL mode: https://www.sqlite.org/wal.html
- sqlite-vec Python bindings: https://github.com/asg017/sqlite-vec/tree/main/examples/simple-python
"""

import logging
import sqlite3
from typing import List, Dict, Any

import numpy as np
import sqlite_vec

from src.config import settings

logger = logging.getLogger(__name__)


class SQLiteVectorStore:
    """
    Manages vector persistence and KNN retrieval via SQLite and sqlite-vec.
    """

    def __init__(self, db_path: str = settings.db_path) -> None:
        self.db_path = db_path
        self.embedding_dim = settings.embedding_dim

        self.conn = sqlite3.connect(
            self.db_path,
            check_same_thread=False,
            timeout=settings.sqlite_busy_timeout_ms / 1000,
        )
        self.conn.row_factory = sqlite3.Row
        self.conn.execute("PRAGMA journal_mode=WAL")
        self.conn.execute("PRAGMA synchronous=NORMAL")
        self.conn.execute(f"PRAGMA busy_timeout={settings.sqlite_busy_timeout_ms}")

        self.conn.enable_load_extension(True)
        sqlite_vec.load(self.conn)
        self.conn.enable_load_extension(False)

        self._create_tables()

    def _create_tables(self) -> None:
        with self.conn:
            self.conn.execute(
                """
                CREATE TABLE IF NOT EXISTS chunks_meta (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    source TEXT NOT NULL,
                    content TEXT NOT NULL
                )
                """
            )
            self.conn.execute(
                f"""
                CREATE VIRTUAL TABLE IF NOT EXISTS vec_items USING vec0(
                    embedding float[{self.embedding_dim}]
                    distance_metric={settings.distance_metric}
                )
                """
            )

    def insert_chunks(
        self,
        chunks: List[Dict[str, Any]],
        embeddings: List[np.ndarray],
    ) -> None:
        """
        Insert metadata and embeddings in a single transaction.
        """
        if len(chunks) != len(embeddings):
            raise ValueError(
                f"chunks ({len(chunks)}) and embeddings ({len(embeddings)}) length mismatch"
            )

        with self.conn:
            for chunk, embedding in zip(chunks, embeddings):
                if embedding.shape[0] != self.embedding_dim:
                    raise ValueError(
                        f"Embedding dimension {embedding.shape[0]} does not match "
                        f"vec0 dimension {self.embedding_dim}"
                    )

                cursor = self.conn.execute(
                    "INSERT INTO chunks_meta (source, content) VALUES (?, ?)",
                    (chunk["source"], chunk["content"]),
                )
                row_id = cursor.lastrowid
                self.conn.execute(
                    "INSERT INTO vec_items(rowid, embedding) VALUES (?, ?)",
                    (row_id, sqlite_vec.serialize_float32(embedding)),
                )

        logger.info("Persisted %d vector records", len(chunks))

    def similarity_search(
        self,
        query_embedding: np.ndarray,
        top_k: int = settings.top_k,
    ) -> List[Dict[str, Any]]:
        """
        Execute a KNN query. The vec0 MATCH must be isolated in a subquery so
        the k = ? constraint is pushed into the virtual table.
        """
        if query_embedding.shape[0] != self.embedding_dim:
            raise ValueError(
                f"Query dimension {query_embedding.shape[0]} does not match "
                f"vec0 dimension {self.embedding_dim}"
            )

        query_bytes = sqlite_vec.serialize_float32(query_embedding)

        rows = self.conn.execute(
            """
            SELECT m.source, m.content, v.distance
            FROM (
                SELECT rowid, distance
                FROM vec_items
                WHERE embedding MATCH ?
                AND k = ?
            ) v
            JOIN chunks_meta m ON v.rowid = m.id
            ORDER BY v.distance
            """,
            (query_bytes, top_k),
        ).fetchall()

        return [dict(row) for row in rows]

    def is_empty(self) -> bool:
        row = self.conn.execute("SELECT 1 FROM chunks_meta LIMIT 1").fetchone()
        return row is None

    def count(self) -> int:
        """Return the number of stored chunks."""
        row = self.conn.execute("SELECT COUNT(*) FROM chunks_meta").fetchone()
        return int(row[0])

    def reset(self) -> None:
        """Remove every stored chunk and vector in one transaction."""
        with self.conn:
            self.conn.execute("DELETE FROM vec_items")
            self.conn.execute("DELETE FROM chunks_meta")

    def close(self) -> None:
        self.conn.commit()
        self.conn.close()
