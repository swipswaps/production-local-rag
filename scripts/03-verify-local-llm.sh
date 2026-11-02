#!/usr/bin/env bash
#
# 03-verify-local-llm.sh
# Time a short local generation to decide whether local inference is viable.
# Read-only: it warms and runs the model, then reports the elapsed time.
#
# Guardrails: no sed, no 2>/dev/null, no set -e, no rm -rf, exits 0 or 2.
#
# Usage:
#   ./scripts/03-verify-local-llm.sh
#   ./scripts/03-verify-local-llm.sh --model qwen2.5:3b-instruct
#   ./scripts/03-verify-local-llm.sh --warm --max-seconds 60
#   ./scripts/03-verify-local-llm.sh --help

SCRIPT_NAME="03-verify-local-llm.sh"
MODEL="qwen2.5:3b-instruct"
MAX_SECONDS=60
RUN_TIMEOUT=180
WARM=0

usage() {
  printf '%s\n' "Usage: $SCRIPT_NAME [--model NAME] [--warm] [--max-seconds N] [--timeout N]"
  printf '%s\n' ""
  printf '%s\n' "  --model NAME       model to test (default: $MODEL)"
  printf '%s\n' "  --warm             run once to load the model, then time the second run"
  printf '%s\n' "  --max-seconds N    fail if the run takes longer (default: $MAX_SECONDS)"
  printf '%s\n' "  --timeout N        hard kill after N seconds (default: $RUN_TIMEOUT)"
  printf '%s\n' "  --help             this text"
}

log() { printf '%s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; }
die() { err "$*"; exit 2; }

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --model) shift; MODEL="$1" ;;
      --warm) WARM=1 ;;
      --max-seconds) shift; MAX_SECONDS="$1" ;;
      --timeout) shift; RUN_TIMEOUT="$1" ;;
      --help|-h) usage; exit 0 ;;
      *) die "unknown option: $1 (try --help)" ;;
    esac
    shift
  done
}

main() {
  parse_args "$@"
  command -v ollama >/dev/null || die "ollama CLI not found"

  log "=== ollama ==="
  ollama list 2>&1
  if ! ollama list 2>&1 | grep -q "$MODEL"; then
    die "model '$MODEL' not pulled; run: ollama pull $MODEL"
  fi
  log ""
  log "=== loaded models ==="
  ollama ps 2>&1

  if [ "$WARM" -eq 1 ]; then
    log ""
    log "warming $MODEL ..."
    timeout "$RUN_TIMEOUT" ollama run "$MODEL" "hi" >/tmp/rag-warm.out 2>&1
    tail -5 /tmp/rag-warm.out
  fi

  out=$(mktemp)
  start=$(date +%s)
  timeout "$RUN_TIMEOUT" ollama run "$MODEL" "Say OK" >"$out" 2>&1
  rc=$?
  end=$(date +%s)
  elapsed=$((end - start))

  log ""
  log "=== result ==="
  log "model:   $MODEL"
  log "elapsed: ${elapsed}s"
  log "exit:    $rc"
  log "output:"
  cat "$out"
  rm -f "$out"

  if [ "$rc" -eq 124 ]; then
    err "hard timeout after ${RUN_TIMEOUT}s; local generation is not viable"
    return 2
  fi
  if [ "$elapsed" -gt "$MAX_SECONDS" ]; then
    err "generation took ${elapsed}s (> ${MAX_SECONDS}s); use retrieval-only or a smaller model"
    log "try: ollama pull qwen2.5:0.5b-instruct"
    log "     RAG_CHAT_MODEL=qwen2.5:0.5b-instruct ./scripts/rag-cli.sh query \"...\" --answer"
    return 2
  fi

  log "generation is viable (${elapsed}s <= ${MAX_SECONDS}s)"
  return 0
}

main "$@"
exit $?
