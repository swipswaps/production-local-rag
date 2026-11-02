#!/usr/bin/env bash
#
# rag-cli.sh
# Run the non-interactive RAG CLI using the repository virtualenv.
#
# Usage:
#   ./scripts/rag-cli.sh status
#   ./scripts/rag-cli.sh ingest docs/ --reset
#   ./scripts/rag-cli.sh query "What is the pet policy?" --top-k 3

VENV_DIR="${VENV_DIR:-.venv}"
PY="$VENV_DIR/bin/python"

if [ ! -x "$PY" ]; then
  printf 'ERROR: %s not found; run ./scripts/setup-rag-venv.sh first\n' "$PY" >&2
  exit 2
fi

exec "$PY" -m src.cli "$@"
