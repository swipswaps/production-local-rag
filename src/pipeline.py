"""
Module: pipeline.py
Description: Orchestrates ingestion and interactive retrieval. Closes resources
             on initialization failure, handles KeyboardInterrupt and EOFError,
             and uses the configured Rich console for prompts.
Citations:
- Rich Prompt: https://rich.readthedocs.io/en/stable/prompt.html
- Python logging: https://docs.python.org/3/library/logging.html
"""

import logging
from pathlib import Path

from rich.console import Console
from rich.panel import Panel
from rich.prompt import Prompt

from src.config import settings
from src.chunker import RecursiveMarkdownChunker
from src.embeddings import OllamaEmbeddingClient
from src.vector_store import SQLiteVectorStore
from src.llm import OllamaChatClient

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger(__name__)
console = Console()

_DEFAULT_HANDBOOK = """# Bite Bistro Employee Handbook

## Operating Hours
The cafe opens at 7:00 AM on Mondays through Fridays and at 8:00 AM on weekends.

## Pet Policy
No dogs are allowed inside the bistro except for certified service animals. Customers with dogs may use the outdoor patio seating.

## Security
The emergency back door alarm code is 4417. Never share this code with non-staff members.
"""


def initialize_pipeline() -> tuple[SQLiteVectorStore, OllamaEmbeddingClient, OllamaChatClient]:
    embed_client = OllamaEmbeddingClient()
    chat_client = OllamaChatClient()
    vector_store = SQLiteVectorStore()

    try:
        if vector_store.is_empty():
            console.print("[yellow]Vector store is empty. Ingesting...[/yellow]")
            docs_dir = Path("docs")
            docs_dir.mkdir(exist_ok=True)

            handbook = docs_dir / "handbook.md"
            if not handbook.exists():
                handbook.write_text(_DEFAULT_HANDBOOK, encoding="utf-8")

            chunker = RecursiveMarkdownChunker(
                chunk_size=settings.chunk_size,
                chunk_overlap=settings.chunk_overlap,
            )

            all_chunks = []
            for path in sorted(docs_dir.glob("*.md")):
                text = path.read_text(encoding="utf-8")
                all_chunks.extend(chunker.chunk_text(text, source_name=path.name))

            if all_chunks:
                texts = [c["content"] for c in all_chunks]
                console.print("[cyan]Generating embeddings...[/cyan]")
                embeddings = embed_client.generate_document_embeddings(texts)
                vector_store.insert_chunks(all_chunks, embeddings)
                console.print("[green]Ingestion complete.[/green]")
    except Exception:
        logger.exception("Pipeline initialization failed; closing resources")
        vector_store.close()
        embed_client.close()
        chat_client.close()
        raise

    return vector_store, embed_client, chat_client


def main() -> None:
    console.print(
        Panel.fit(
            "Production-Grade Local RAG Engine (v1.3.1) Initialized",
            style="bold blue",
        )
    )

    vector_store, embed_client, chat_client = initialize_pipeline()

    console.print(
        "\n[bold green]Pipeline ready. Type 'exit' or 'quit' to stop.[/bold green]\n"
    )

    try:
        while True:
            try:
                query = Prompt.ask("[bold cyan]Query[/bold cyan]", console=console).strip()
            except (KeyboardInterrupt, EOFError):
                console.print("\n[yellow]Interrupted. Shutting down.[/yellow]")
                break

            if not query:
                continue
            if query.lower() in {"exit", "quit"}:
                console.print("[yellow]Goodbye.[/yellow]")
                break

            try:
                query_embedding = embed_client.generate_query_embedding(query)
                retrieved = vector_store.similarity_search(
                    query_embedding, top_k=settings.top_k
                )

                context = "\n\n".join(
                    f"Source: {c['source']}\n{c['content']}" for c in retrieved
                )
                prompt = f"Context:\n{context}\n\nQuestion: {query}"
                answer = chat_client.generate_answer(prompt)
            except Exception as exc:
                logger.exception("Query failed")
                console.print(f"[red]Query failed: {exc}[/red]")
                continue

            console.print(Panel(answer, title="[bold green]Answer[/bold green]", expand=False))
            console.print("\n[dim]Sources:[/dim]")
            for c in retrieved:
                console.print(
                    f" - [dim italic]{c['source']} (distance={c['distance']:.4f})[/dim italic]"
                )
            console.print("-" * 50 + "\n")
    finally:
        embed_client.close()
        chat_client.close()
        vector_store.close()


if __name__ == "__main__":
    main()
