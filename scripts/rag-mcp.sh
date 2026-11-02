#!/usr/bin/env bash
#
# rag-mcp.sh
# Run the retrieval-only MCP server from the repository virtualenv.
#
# Usage:
#   ./scripts/rag-mcp.sh --self-test
#   ./scripts/rag-mcp.sh            # stdio MCP server

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$REPO_ROOT" || {
  printf 'ERROR: cannot enter %s\n' "$REPO_ROOT" >&2
  exit 2
}

VENV_DIR="${VENV_DIR:-.venv}"
PY="$VENV_DIR/bin/python"

if [ ! -x "$PY" ]; then
  printf 'ERROR: %s not found; run ./scripts/setup-rag-venv.sh first\n' "$PY" >&2
  exit 2
fi

exec "$PY" -m src.mcp_server "$@"
