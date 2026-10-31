================================================================================
PRODUCTION-GRADE RAG ENGINE (LOCAL-FIRST ARCHITECTURE v1.3.0)
================================================================================

ORIGIN & ACKNOWLEDGEMENT:
This production-grade repository evolved from educational concepts demonstrated
in NeuralNine's tutorial video ("How to Build RAG From Scratch in 50 Lines of
Code"):
  https://www.youtube.com/watch?v=f9uAG3AQGWM

WHAT CHANGED IN v1.3.0 (relative to v1.2.1):
1. KNN query correctness: sqlite-vec v0.1.0+ requires `k = ?` on the virtual
   table. The query is now isolated in a subquery so the constraint is pushed
   into vec0; direct JOIN + LIMIT no longer works reliably.
   Ref: https://github.com/asg017/sqlite-vec/blob/main/site/features/knn.md
2. SQLite concurrency: WAL journal mode, NORMAL synchronous, and busy_timeout
   are enabled. All writes are wrapped in `with self.conn:` so mid-insert
   failures roll back cleanly.
3. Embedding endpoint: switched from the deprecated /api/embeddings (single
   `prompt`) to the current /api/embed endpoint (batch `input`).
   Ref: https://docs.ollama.com/api/embed
4. nomic prefixes: nomic-embed-text requires "search_document: " for indexed
   text and "search_query: " for queries. Both are now applied automatically.
   Ref: https://huggingface.co/nomic-ai/nomic-embed-text-v1.5#usage
5. Chunker size guarantee: paragraphs longer than chunk_size are recursively
   split on sentences, then words, then characters. The previous version
   could emit chunks far above chunk_size.
6. HTTP resilience: ConnectError, ReadTimeout, and ConnectTimeout are handled
   explicitly with exponential backoff on embed calls.
7. Lifecycle safety: initialization failures close DB and HTTP clients;
   KeyboardInterrupt / EOFError in the REPL exit cleanly.
8. Dimension safety: embedding_dim is configurable and validated on every
   insert and query.

WHERE WE CAME FROM:
The tutorial implementation used naive paragraph splitting, in-memory NumPy
scans (O(N)), zero persistence, and blocking HTTP. v1.2.1 replaced the storage
layer with sqlite-vec but retained a KNN query pattern that does not push the
k constraint into the virtual table, plus three smaller bugs fixed here.

BEST NEXT STEPS FORWARD:
1. Ingest Custom Documentation: drop .md files into docs/. The pipeline will
   chunk, embed, and index them on the next run.
2. Hybrid Search: add FTS5 + BM25 alongside dense vectors; fuse with
   Reciprocal Rank Fusion.
3. Cross-Encoder Re-Ranking: add bge-reranker to refine top-K before the LLM.

INSTALLATION & EXECUTION:
$ pip install -r requirements.txt
$ python -m src.pipeline

PREREQUISITES:
$ ollama serve
$ ollama pull nomic-embed-text
$ ollama pull qwen2.5:7b-instruct
