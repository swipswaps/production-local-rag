"""
Module: mcp_server.py
Description: Minimal stdio Model Context Protocol server exposing retrieval-only
             tools for the local RAG engine. Uses only the standard library so
             it can run wherever the engine dependencies are installed.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any, Sequence

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _REPO_ROOT not in sys.path:
    sys.path.insert(0, _REPO_ROOT)

PROTOCOL_VERSION = "2024-11-05"
SERVER_NAME = "production-local-rag"
SERVER_VERSION = "1.3.1"

TOOLS: list[dict[str, Any]] = [
    {
        "name": "search_docs",
        "description": (
            "Search the local vector store and return the nearest chunks. "
            "Retrieval only: the caller synthesizes the answer."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "Natural-language query"},
                "top_k": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 50,
                    "description": "Number of chunks (default: settings.top_k)",
                },
            },
            "required": ["query"],
            "additionalProperties": False,
        },
    },
    {
        "name": "status",
        "description": "Report store and model configuration without searching.",
        "inputSchema": {
            "type": "object",
            "properties": {},
            "additionalProperties": False,
        },
    },
]


def _search_docs(arguments: dict[str, Any]) -> dict[str, Any]:
    query = arguments.get("query")
    if not isinstance(query, str) or not query.strip():
        raise ValueError("query must be a non-empty string")
    top_k = arguments.get("top_k")
    if top_k is not None:
        if isinstance(top_k, bool) or not isinstance(top_k, int) or not 1 <= top_k <= 50:
            raise ValueError("top_k must be an integer between 1 and 50")

    from src.config import settings
    from src.embeddings import OllamaEmbeddingClient
    from src.vector_store import SQLiteVectorStore

    store = SQLiteVectorStore()
    embed = OllamaEmbeddingClient()
    try:
        if store.is_empty():
            return {"results": [], "note": "store is empty; run the ingest command"}
        query_embedding = embed.generate_query_embedding(query)
        hits = store.similarity_search(
            query_embedding, top_k=top_k if top_k is not None else settings.top_k
        )
        return {"results": hits}
    finally:
        embed.close()
        store.close()


def _status(arguments: dict[str, Any]) -> dict[str, Any]:
    from src.config import settings
    from src.vector_store import SQLiteVectorStore

    store = SQLiteVectorStore()
    try:
        return {
            "db_path": settings.db_path,
            "embedding_model": settings.embedding_model,
            "embedding_dim": settings.embedding_dim,
            "chat_model": settings.chat_model,
            "distance_metric": settings.distance_metric,
            "chunks": store.count(),
            "empty": store.is_empty(),
        }
    finally:
        store.close()


def _call_tool(name: str, arguments: dict[str, Any]) -> dict[str, Any]:
    if name == "search_docs":
        return _search_docs(arguments)
    if name == "status":
        return _status(arguments)
    raise ValueError(f"unknown tool: {name}")


def _result(request_id: Any, result: dict[str, Any]) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": request_id, "result": result}


def _error(request_id: Any, code: int, message: str) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}}


def handle(request: dict[str, Any]) -> dict[str, Any] | None:
    method = request.get("method")
    request_id = request.get("id")
    params = request.get("params") or {}

    if method == "initialize":
        return _result(
            request_id,
            {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {"tools": {}},
                "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
            },
        )
    if method in ("notifications/initialized", "initialized"):
        return None
    if method == "ping":
        return _result(request_id, {})
    if method == "tools/list":
        return _result(request_id, {"tools": TOOLS})
    if method == "tools/call":
        name = params.get("name")
        arguments = params.get("arguments") or {}
        try:
            data = _call_tool(str(name), arguments)
        except Exception as exc:
            return _result(
                request_id,
                {
                    "content": [{"type": "text", "text": f"{type(exc).__name__}: {exc}"}],
                    "isError": True,
                },
            )
        return _result(
            request_id,
            {
                "content": [
                    {"type": "text", "text": json.dumps(data, ensure_ascii=False, default=str)}
                ],
                "isError": False,
            },
        )
    if request_id is None:
        return None
    return _error(request_id, -32601, f"method not found: {method}")


def _self_test() -> int:
    requests = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
        {"jsonrpc": "2.0", "id": 3, "method": "ping"},
    ]
    for request in requests:
        print(json.dumps(handle(request), ensure_ascii=False, default=str))
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="python -m src.mcp_server",
        description="Retrieval-only MCP server for the local RAG engine.",
    )
    parser.add_argument("--self-test", action="store_true", help="print protocol frames and exit")
    args = parser.parse_args(argv)

    if args.self_test:
        return _self_test()

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except json.JSONDecodeError as exc:
            print(json.dumps(_error(None, -32700, f"parse error: {exc}")), flush=True)
            continue
        if not isinstance(request, dict):
            print(json.dumps(_error(None, -32600, "invalid request")), flush=True)
            continue
        try:
            response = handle(request)
        except Exception as exc:
            response = _error(request.get("id"), -32603, f"{type(exc).__name__}: {exc}")
        if response is not None:
            print(json.dumps(response, ensure_ascii=False, default=str), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
