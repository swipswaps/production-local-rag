#!/usr/bin/env bash
#
# 04-retrieval-only.sh
# Use the RAG engine for retrieval only. Returns JSON chunks so a remote model
# (opencode / DeepSeek / Gemini) can synthesize the answer.
#
# Guardrails: no sed, no 2>/dev/null, no set -e, no rm -rf, exits 0 or 2.
#
# Usage:
#   ./scripts/04-retrieval-only.sh --query "What is the pet policy?"
#   ./scripts/04-retrieval-only.sh --query "..." --top-k 5
#   ./scripts/04-retrieval-only.sh --status
#   ./scripts/04-retrieval-only.sh --help

SCRIPT_NAME="04-retrieval-only.sh"
QUERY=""
TOP_K=3
STATUS=0

usage() {
  printf '%s\n' "Usage: $SCRIPT_NAME --query TEXT [--top-k N]"
  printf '%s\n' "       $SCRIPT_NAME --status"
  printf '%s\n' ""
  printf '%s\n' "  --query TEXT   retrieval query"
  printf '%s\n' "  --top-k N      number of chunks (default: 3)"
  printf '%s\n' "  --status       print store/config status instead of searching"
  printf '%s\n' "  --help         this text"
}

log() { printf '%s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; }
die() { err "$*"; exit 2; }

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --query) shift; QUERY="$1" ;;
      --top-k) shift; TOP_K="$1" ;;
      --status) STATUS=1 ;;
      --help|-h) usage; exit 0 ;;
      *) die "unknown option: $1 (try --help)" ;;
    esac
    shift
  done
}

main() {
  parse_args "$@"
  [ -x ./scripts/rag-cli.sh ] || die "run from the repo root (scripts/rag-cli.sh not found)"

  if [ "$STATUS" -eq 1 ]; then
    exec ./scripts/rag-cli.sh status
  fi

  [ -n "$QUERY" ] || die "--query is required (or use --status)"
  exec ./scripts/rag-cli.sh query "$QUERY" --top-k "$TOP_K" --json
}

main "$@"
exit $?
