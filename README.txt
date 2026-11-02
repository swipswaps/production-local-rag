================================================================================
PRODUCTION-GRADE RAG ENGINE (LOCAL-FIRST ARCHITECTURE v1.3.1)
================================================================================

ORIGIN & ACKNOWLEDGEMENT:
This production-grade repository evolved from educational concepts demonstrated
in NeuralNine's tutorial video ("How to Build RAG From Scratch in 50 Lines of
Code"):
  https://www.youtube.com/watch?v=f9uAG3AQGWM

WHERE WE CAME FROM:
The tutorial implementation used naive paragraph splitting, in-memory NumPy
scans (O(N)), zero persistence, and blocking HTTP. v1.2.1 replaced the storage
layer with sqlite-vec but retained a KNN query pattern that did not push the
k constraint into the virtual table, plus three smaller bugs fixed in v1.3.0.

WHERE WE ARE NOW (FOUR PILLARS):
1. Persistent Vector Indexing: SQLite with the sqlite-vec extension using
   vec0 virtual tables and the required `k = ?` subquery form.
   Ref: https://github.com/asg017/sqlite-vec
2. Semantic Chunking: Size-bounded recursive markdown chunker with
   word-boundary-aware overlap, guaranteeing chunk_size is never exceeded.
   Ref: https://github.com/gkamradt/LLMTest_RetrievalfromTheBottom
3. Resilient Networking: Connection-pooled httpx clients with granular
   connect/read timeouts and exponential backoff on retryable failures.
   Ref: https://www.python-httpx.org/advanced/clients/
4. Automation Guardrails: setup_repo.py provides idempotent repo automation
   using subprocess.Popen exclusively (no subprocess.run, no sed, no set -e),
   with exit codes restricted to 0 (success) and 2 (handled failure).

WHAT CHANGED IN v1.3.1 (vs v1.3.0):
- Restored setup_repo.py, the guardrail-compliant repo automation script.
- Restored the four-pillar architecture summary above.
- Corrected the white paper's "verbatim" claim; section 3 now labels its
  excerpts as representative v1.2.1 snapshots.
- Bumped pyproject.toml and the pipeline banner to v1.3.1.

WHAT CHANGED IN v1.3.0 (vs v1.2.1):
1. KNN query correctness: `k = ?` inside a subquery so the constraint is
   pushed into vec0.
   Ref: https://github.com/asg017/sqlite-vec/blob/main/site/features/knn.md
2. SQLite concurrency: WAL journal mode, NORMAL synchronous, busy_timeout.
3. Embedding endpoint: switched from /api/embeddings to /api/embed (batch).
   Ref: https://docs.ollama.com/api/embed
4. nomic prefixes: search_document / search_query applied automatically.
   Ref: https://huggingface.co/nomic-ai/nomic-embed-text-v1.5#usage
5. Chunker size guarantee: recursive sentence/word/character fallback.
6. HTTP resilience: ConnectError / ReadTimeout / ConnectTimeout handled.
7. Lifecycle safety: init failures close DB/HTTP clients; REPL handles
   KeyboardInterrupt and EOFError.
8. Dimension safety: embedding_dim configurable and validated per row.

BEST NEXT STEPS FORWARD:
1. Ingest Custom Documentation: drop .md files into docs/, then remove
   vector_store.db (it is gitignored) so the next run re-ingests the corpus.
   Ingestion runs only while the vector store is empty; there is no incremental
   append yet, and adding a file without clearing the store will not index it.
2. Hybrid Search: add FTS5 + BM25 alongside dense vectors; fuse with
   Reciprocal Rank Fusion.
3. Cross-Encoder Re-Ranking: add bge-reranker to refine top-K before the LLM.

INSTALLATION & EXECUTION:
$ ./scripts/setup-rag-venv.sh
$ . .venv/bin/activate
$ python -m src.pipeline

PYTHON VERSION:
Use Python 3.10-3.13. Python 3.14 fails because the pinned pydantic-core
does not build (PyO3 supports at most 3.13). setup-rag-venv.sh picks a
compatible interpreter and installs the pinned requirements.

NON-INTERACTIVE CLI:
$ ./scripts/rag-cli.sh status
$ ./scripts/rag-cli.sh ingest docs/ --reset
$ ./scripts/rag-cli.sh query "What is the pet policy?" --top-k 3
$ ./scripts/rag-cli.sh query "What is the pet policy?" --json
$ ./scripts/rag-cli.sh query "What is the pet policy?" --answer
$ ./scripts/rag-cli.sh reset --yes
   (ingest appends; use --reset for a clean rebuild. .md and .txt are read.)

CONTRACT CHECK:
$ python -m unittest discover -s tests -v
   (enforces the chunk_size bound and chunk metadata shape)

OPTIONAL - AUTOMATED REPO SYNC:
$ python setup_repo.py

PREREQUISITES:
$ ollama serve
$ ollama pull nomic-embed-text
$ ollama pull qwen2.5:7b-instruct

TIMEOUTS:
RAG_REQUEST_TIMEOUT  embedding/read timeout (default 30s)
RAG_CHAT_TIMEOUT     chat read timeout (default 300s)
RAG_CONNECT_TIMEOUT  connect timeout (default 5s)

MCP (RETRIEVAL ONLY):
$ ./scripts/rag-mcp.sh --self-test
   tools: search_docs(query, top_k), status
   The server must run where the venv and Ollama are reachable.

OPERATIONS:
$ ./scripts/01-audit-cpu-lock.sh --stress 10
$ ./scripts/02-relieve-contention.sh --dashboard-low
$ ./scripts/03-verify-local-llm.sh --warm
$ ./scripts/04-retrieval-only.sh --query "What is the pet policy?"
