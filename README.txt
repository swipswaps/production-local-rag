================================================================================
PRODUCTION-GRADE RAG ENGINE (LOCAL-FIRST) - README
================================================================================

WHAT THIS IS
------------
A local retrieval-augmented generation (RAG) engine. It turns .md/.txt files
into bounded chunks, embeds them with Ollama's nomic-embed-text model, stores
the vectors in SQLite through the sqlite-vec extension, and returns the closest
chunks for a query. Answer synthesis is optional: the reliable default is
retrieval-only, with a remote model (opencode / DeepSeek) writing the answer
from the chunks this engine returns.

WHO IT IS FOR
-------------
Anyone who wants document search that runs on this host, without sending the
corpus to a remote vector database. You need Python 3.10-3.13 and, for
embeddings, a reachable Ollama service with nomic-embed-text pulled.

WHAT WORKS TODAY
----------------
- Ingest .md/.txt files into SQLite (sqlite-vec vec0 table).
- Status: database path, models, dimension, distance, chunk count, empty flag.
- Retrieval (KNN, cosine) with JSON output for a remote model.
- Retrieval-only MCP server: search_docs(query, top_k) and status.
- Optional local chat via Ollama (CPU-bound; test it before relying on it).

NOT BUILT YET
-------------
- Incremental re-index. Ingest appends; use --reset for a clean rebuild.
- Hybrid BM25 + dense fusion.
- Cross-encoder re-ranking.

QUICK START
-----------
  ./scripts/setup-rag-venv.sh
  ollama pull nomic-embed-text
  ollama pull qwen2.5:3b-instruct        # optional local chat
  ./scripts/rag-cli.sh ingest docs/ --reset
  ./scripts/rag-cli.sh status
  ./scripts/rag-cli.sh query "What is the pet policy?" --top-k 3
  ./scripts/04-retrieval-only.sh --query "What is the pet policy?"

The last command returns JSON chunks. Feed those chunks to opencode/DeepSeek;
do not use --answer on a host where local generation is not wanted.

HOW IT WORKS
------------
  files
    -> RecursiveMarkdownChunker (size-bounded chunks + word-aware overlap)
    -> task prefixes: "search_document: " and "search_query: "
    -> Ollama /api/embed (batch)
    -> SQLite + sqlite-vec vec0 table (768-d by default)
    -> KNN with k pushed into the subquery, cosine distance
    -> top-k chunks (JSON or the REPL)
    -> optional local answer, or a remote model reads the chunks

INGESTION RULES (the most common confusion)
-------------------------------------------
- `rag-cli.sh ingest docs/` APPENDS to the store. Rerunning it duplicates
  chunks; it does not replace the corpus.
- `rag-cli.sh ingest docs/ --reset` clears first, then inserts (clean rebuild).
- `python -m src.pipeline` (the interactive REPL) ingests only when the store is
  empty.
- Adding a file does NOT index it automatically. Ingest it explicitly.
- `status` prints `chunks:` and `empty:`; use it before and after ingestion.

COMMANDS
--------
  ./scripts/setup-rag-venv.sh                  create/repair the host venv
  ./scripts/rag-cli.sh status                  store + config status
  ./scripts/rag-cli.sh ingest docs/            append documents
  ./scripts/rag-cli.sh ingest docs/ --reset    clean rebuild
  ./scripts/rag-cli.sh query "..." --top-k 3   retrieval only
  ./scripts/rag-cli.sh query "..." --json      machine-readable chunks
  ./scripts/rag-cli.sh query "..." --answer    local chat (optional)
  ./scripts/rag-cli.sh reset --yes             delete all chunks/vectors
  ./scripts/04-retrieval-only.sh --query "..." JSON chunks for a remote model
  ./scripts/rag-mcp.sh --self-test             retrieval-only MCP proof
  python -m unittest discover -s tests -v      contract tests
  python -m src.pipeline                       interactive REPL

CONFIGURATION (RAG_ environment variables or .env)
--------------------------------------------------
  RAG_OLLAMA_BASE_URL   default http://localhost:11434
  RAG_REQUEST_TIMEOUT   embedding/read timeout, default 120s
                        (5x the measured 20.6s cold load of nomic-embed-text)
  RAG_CHAT_TIMEOUT      chat read timeout, default 300s
  RAG_CONNECT_TIMEOUT   connect timeout, default 5s
  RAG_EMBEDDING_MODEL   default nomic-embed-text
  RAG_EMBEDDING_DIM     default 768
  RAG_CHAT_MODEL        default qwen2.5:7b-instruct
                        (the host runbooks use qwen2.5:3b-instruct)
  RAG_DB_PATH           default vector_store.db
  RAG_DISTANCE_METRIC   default cosine (l2 | cosine | hamming)
  RAG_CHUNK_SIZE        default 400
  RAG_CHUNK_OVERLAP     default 50

OPERATIONS AND RECOVERY (host-only)
-----------------------------------
  01-audit-cpu-lock.sh       CPU frequency-lock audit
  02-relieve-contention.sh   lower dashboard priority / cap containers
  03-verify-local-llm.sh     warm + time local generation; --warm also warms
                             the embedding model and prints its measured time
  04-retrieval-only.sh       JSON chunks for a remote model
  05-resource-toggles.sh     pause/resume/stop/start optional services
  06-runbook.sh              phases 1-6 (contention, RAG, dashboard)
  07-io-triage.sh            I/O, indexer, Docker, DB, dashboard triage
  08-gated-recovery.sh       fail-closed recovery: --diagnose or --all --yes
  09-ollama-start.sh         start Ollama and verify chat + embedding models
  10-recovery-autopilot.sh   run 08 under a watchdog; retries safe stalls
  11-host-access.sh          container -> host SSH, tmux capture, OCR fallback

Full tool descriptions: scripts/README.txt.

TROUBLESHOOTING
---------------
- "ollama API unreachable": start it (`sudo systemctl start ollama` or
  `./scripts/09-ollama-start.sh`), then confirm `curl 127.0.0.1:11434/api/tags`.
- "model nomic-embed-text not found": `ollama pull nomic-embed-text`.
- Embedding timed out on the first query: the model can take ~20s to cold-load.
  The default read timeout is 120s; `03-verify-local-llm.sh --warm` preloads
  both models. Re-run the query.
- Retrieval returns nothing: run `status`; if `empty: True`, ingest the corpus.
  If the corpus changed, use `ingest --reset` (default ingest appends).
- Python 3.14 fails: use 3.10-3.13. The pinned pydantic-core does not build on
  3.14; setup-rag-venv.sh picks a compatible interpreter.
- The OpenCode container cannot use this venv: it is host-specific. Run the
  engine on the host and expose the MCP server where the container can reach it.
- `11-host-access.sh` says "ssh client missing" after a web recreate: run
  `./scripts/11-host-access.sh --install --yes`. `/home/node` is container-local
  and is reset when the web container is recreated; the host `authorized_keys`
  keeps old `opencode-container` entries (remove them if you reinstall often).

REPOSITORY MAP
--------------
  src/                 chunker, embeddings, vector_store, pipeline, CLI, LLM, MCP
  scripts/             runbooks 01-11, rag-cli, rag-mcp, venv setup
  tests/               stdlib contract tests (chunk bound + metadata)
  docs/handbook.md     sample corpus used by the retrieval proof
  vector_store.db      local data (gitignored; not shipped)
  README.txt           this file
  scripts/README.txt   per-script catalog

SECURITY AND LIMITS
-------------------
- Local-first: embeddings and vectors stay on this host; chat may also be local.
- The MCP server is retrieval-only: search_docs/status, no answer generation.
- Retrieval is not access control. The store contains whatever you ingest; do
  not ingest secrets you would not put in a local database.
- Latency and quality claims belong in tests/logs, not prose. The white paper's
  numbers are labeled as unmeasured design notes.

--------------------------------------------------------------------------------
HISTORY (why this repo looks like this)
--------------------------------------------------------------------------------

ORIGIN AND ACKNOWLEDGEMENT
This repository evolved from educational concepts demonstrated in NeuralNine's
tutorial video ("How to Build RAG From Scratch in 50 Lines of Code"):
  https://www.youtube.com/watch?v=f9uAG3AQGWM

WHERE WE CAME FROM
The tutorial used naive paragraph splitting, in-memory NumPy scans (O(N)), zero
persistence, and blocking HTTP. v1.2.1 replaced the storage layer with
sqlite-vec but retained a KNN pattern that did not push the k constraint into
the virtual table, plus three smaller bugs fixed in v1.3.0.

FOUR PILLARS
1. Persistent vector indexing: SQLite + sqlite-vec vec0 tables, with the k = ?
   subquery form.
   Ref: https://github.com/asg017/sqlite-vec
2. Semantic chunking: size-bounded recursive markdown chunker with
   word-boundary-aware overlap; chunk_size is never exceeded.
   Ref: https://github.com/gkamradt/LLMTest_RetrievalfromTheBottom
3. Resilient networking: pooled httpx clients with granular connect/read
   timeouts and exponential backoff on retryable failures.
   Ref: https://www.python-httpx.org/advanced/clients/
4. Automation guardrails: setup_repo.py uses subprocess.Popen only (no
   subprocess.run, no sed, no set -e), with exit codes 0 (success) and 2
   (handled failure).

2026-11 HARDENING
- The 2026-11 audit found three contract defects: the chunker could exceed
  chunk_size when overlap was re-added; the README claimed new docs were
  indexed on the next run although the REPL ingests only while the store is
  empty; and the white paper quoted unmeasured latency/ANN/thread-safety
  claims. The chunker now enforces the bound; the docs state the real behavior;
  the white paper labels its numbers as design notes.
- Added the non-interactive CLI, dependency-free retrieval-only MCP server,
  stdlib contract tests, a Python 3.10-3.13 venv bootstrap, and host runbooks.
- On ws24 an EC/firmware lock held all cores at 399 MHz; an EC reset restored
  3.2-4.2 GHz, so local inference became viable again.

v1.3.1 (vs v1.3.0)
- Restored setup_repo.py, the guardrail-compliant repo automation script.
- Restored the four-pillar architecture summary.
- Corrected the white paper's "verbatim" claim; section 3 labels its excerpts
  as representative v1.2.1 snapshots.
- Bumped pyproject.toml and the pipeline banner to v1.3.1.

v1.3.0 (vs v1.2.1)
1. KNN: k = ? inside a subquery so the constraint is pushed into vec0.
   Ref: https://github.com/asg017/sqlite-vec/blob/main/site/features/knn.md
2. SQLite concurrency: WAL, NORMAL synchronous, busy_timeout.
3. Embeddings: /api/embeddings -> /api/embed (batch).
   Ref: https://docs.ollama.com/api/embed
4. nomic prefixes: search_document / search_query applied automatically.
   Ref: https://huggingface.co/nomic-ai/nomic-embed-text-v1.5#usage
5. Chunker size guarantee: recursive sentence/word/character fallback.
6. HTTP resilience: ConnectError / ReadTimeout / ConnectTimeout handled.
7. Lifecycle safety: init failures close DB/HTTP clients; REPL handles
   KeyboardInterrupt and EOFError.
8. Dimension safety: embedding_dim configurable and validated per row.

BEST NEXT STEPS
1. Ingest custom documentation deliberately: add .md files, then decide between
   append (may duplicate) and `ingest --reset` (clean rebuild).
2. Hybrid search: FTS5 + BM25 alongside dense vectors, fused with Reciprocal
   Rank Fusion.
3. Cross-encoder re-ranking: add a reranker to refine top-K before the LLM.

PYTHON VERSION
Use Python 3.10-3.13. Python 3.14 fails because the pinned pydantic-core does
not build (PyO3 supports at most 3.13). setup-rag-venv.sh picks a compatible
interpreter and installs the pinned requirements.
