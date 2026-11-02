"""
Module: cli.py
Description: Non-interactive command line interface for the local RAG engine.
             Exposes query, ingest, status, and reset so external tools
             (including opencode) can drive the engine without the REPL.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Sequence

_DOC_SUFFIXES = {".md", ".txt"}


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m src.cli",
        description="Non-interactive interface to the local RAG engine.",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    ingest = sub.add_parser("ingest", help="chunk and embed a file or directory")
    ingest.add_argument("path", help="file or directory containing .md/.txt files")
    ingest.add_argument(
        "--reset", action="store_true", help="clear the store before inserting"
    )
    ingest.set_defaults(func=_cmd_ingest)

    query = sub.add_parser("query", help="search the store for a query")
    query.add_argument("text", help="query text")
    query.add_argument(
        "--top-k",
        type=int,
        default=None,
        help="number of results (default: settings.top_k)",
    )
    query.add_argument("--json", action="store_true", help="emit JSON results")
    query.add_argument(
        "--answer", action="store_true", help="synthesize an answer with the chat model"
    )
    query.set_defaults(func=_cmd_query)

    status = sub.add_parser("status", help="show store and configuration status")
    status.set_defaults(func=_cmd_status)

    reset = sub.add_parser("reset", help="delete all stored chunks and vectors")
    reset.add_argument("--yes", action="store_true", help="required confirmation")
    reset.set_defaults(func=_cmd_reset)

    return parser


def _collect(path_arg: str) -> list[Path]:
    path = Path(path_arg).expanduser()
    if path.is_file():
        return [path]
    if path.is_dir():
        files = sorted(
            item
            for item in path.rglob("*")
            if item.is_file() and item.suffix.lower() in _DOC_SUFFIXES
        )
        if not files:
            raise FileNotFoundError(f"no .md/.txt files under {path}")
        return files
    raise FileNotFoundError(f"not a file or directory: {path}")


def _cmd_ingest(args: argparse.Namespace) -> int:
    from src.chunker import RecursiveMarkdownChunker
    from src.config import settings
    from src.embeddings import OllamaEmbeddingClient
    from src.vector_store import SQLiteVectorStore

    files = _collect(args.path)
    chunker = RecursiveMarkdownChunker(
        chunk_size=settings.chunk_size,
        chunk_overlap=settings.chunk_overlap,
    )
    store = SQLiteVectorStore()
    embed = OllamaEmbeddingClient()
    try:
        chunks: list[dict[str, Any]] = []
        for file_path in files:
            text = file_path.read_text(encoding="utf-8")
            chunks.extend(chunker.chunk_text(text, source_name=str(file_path)))
        if not chunks:
            print("no chunks produced; nothing ingested")
            return 0
        embeddings = embed.generate_document_embeddings(
            [chunk["content"] for chunk in chunks]
        )
        if args.reset:
            store.reset()
            print(f"cleared {settings.db_path}")
        store.insert_chunks(chunks, embeddings)
        print(
            f"ingested {len(chunks)} chunks from {len(files)} file(s) "
            f"into {settings.db_path}"
        )
        return 0
    finally:
        embed.close()
        store.close()


def _cmd_query(args: argparse.Namespace) -> int:
    from src.config import settings
    from src.embeddings import OllamaEmbeddingClient
    from src.vector_store import SQLiteVectorStore

    top_k = args.top_k if args.top_k is not None else settings.top_k
    store = SQLiteVectorStore()
    embed = OllamaEmbeddingClient()
    try:
        if store.is_empty():
            print("store is empty; run: python -m src.cli ingest <path> --reset")
            return 2
        query_embedding = embed.generate_query_embedding(args.text)
        hits = store.similarity_search(query_embedding, top_k=top_k)
        if args.json:
            print(json.dumps(hits, indent=2, ensure_ascii=False, default=str))
        else:
            if not hits:
                print("no results")
            for hit in hits:
                print(f"[{hit['distance']:.4f}] {hit['source']}")
                print(hit["content"])
                print("-" * 60)
        if args.answer:
            from src.llm import OllamaChatClient

            context = "\n\n".join(
                f"Source: {hit['source']}\n{hit['content']}" for hit in hits
            )
            chat = OllamaChatClient()
            try:
                print(
                    chat.generate_answer(
                        f"Context:\n{context}\n\nQuestion: {args.text}"
                    )
                )
            finally:
                chat.close()
        return 0
    finally:
        embed.close()
        store.close()


def _cmd_status(_args: argparse.Namespace) -> int:
    from src.config import settings
    from src.vector_store import SQLiteVectorStore

    store = SQLiteVectorStore()
    try:
        print(f"db_path:         {settings.db_path}")
        print(f"embedding_model: {settings.embedding_model}")
        print(f"embedding_dim:   {settings.embedding_dim}")
        print(f"chat_model:      {settings.chat_model}")
        print(f"distance:        {settings.distance_metric}")
        print(f"chunks:          {store.count()}")
        print(f"empty:           {store.is_empty()}")
        return 0
    finally:
        store.close()


def _cmd_reset(args: argparse.Namespace) -> int:
    from src.config import settings
    from src.vector_store import SQLiteVectorStore

    if not args.yes:
        print("refusing to reset without --yes", file=sys.stderr)
        return 2
    store = SQLiteVectorStore()
    try:
        store.reset()
        print(f"cleared {settings.db_path}")
        return 0
    finally:
        store.close()


def main(argv: Sequence[str] | None = None) -> int:
    parser = _parser()
    args = parser.parse_args(argv)
    try:
        return int(args.func(args))
    except ModuleNotFoundError as exc:
        print(
            f"error: missing dependency '{exc.name}'; "
            "run: pip install -r requirements.txt",
            file=sys.stderr,
        )
        return 2
    except (FileNotFoundError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
