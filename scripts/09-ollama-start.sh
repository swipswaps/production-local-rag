#!/usr/bin/env bash
#
# 09-ollama-start.sh
# Start the local Ollama server, wait for the API, and verify the RAG model.
#
# Prefers the systemd unit when one exists; otherwise starts `ollama serve`
# with the runbook residency limits. Idempotent: does nothing if the API is up.
#
# Host-only. Exits 0 when ready, 2 on failure.
#
# Usage:
#   ./scripts/09-ollama-start.sh
#   ./scripts/09-ollama-start.sh --pull
#   ./scripts/09-ollama-start.sh --status

SCRIPT_NAME="09-ollama-start.sh"
API="${OLLAMA_API:-http://127.0.0.1:11434}"
MODEL="${MODEL:-qwen2.5:3b-instruct}"
EMBED_MODEL="${EMBED_MODEL:-nomic-embed-text}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-5}"
WAIT_SECONDS="${WAIT_SECONDS:-30}"
LOG="${OLLAMA_LOG:-/tmp/ollama-serve.log}"
DO_PULL=0
STATUS_ONLY=0

log() { printf '%s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; }
pass() { printf 'GATE PASS  %s\n' "$*"; }
fail() { printf 'GATE FAIL  %s\n' "$*" >&2; return 1; }
die() { err "$*"; exit 2; }

usage() {
  printf '%s\n' "Usage: $SCRIPT_NAME [--pull] [--status]"
  printf '%s\n' ""
  printf '%s\n' "  --pull     pull MODEL and EMBED_MODEL if missing"
  printf '%s\n' "  --status   show state only; do not start anything"
  printf '%s\n' "  --help     this text"
  printf '%s\n' ""
  printf '%s\n' "  OLLAMA_API=$API"
  printf '%s\n' "  MODEL=$MODEL"
  printf '%s\n' "  EMBED_MODEL=$EMBED_MODEL"
  printf '%s\n' "  WAIT_SECONDS=$WAIT_SECONDS"
  printf '%s\n' "  PROBE_TIMEOUT=$PROBE_TIMEOUT"
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --pull) DO_PULL=1 ;;
      --status) STATUS_ONLY=1 ;;
      --help|-h) usage; exit 0 ;;
      *) die "unknown option: $1 (try --help)" ;;
    esac
    shift
  done
}

api_up() {
  curl -s --max-time 3 "$API/api/tags" >/dev/null
}

with_timeout() {
  local t="$PROBE_TIMEOUT" rc
  if command -v timeout >/dev/null; then
    timeout "$t" "$@"
    rc=$?
    if [ "$rc" -eq 124 ]; then
      err "probe timed out after ${t}s: $* (set PROBE_TIMEOUT to extend; last line above is the last sample)"
    fi
    return "$rc"
  fi
  "$@"
}

model_present() {
  ollama list 2>&1 | grep -Fq "$1"
}

show_status() {
  log "=== telemetry: ollama ==="
  if command -v systemctl >/dev/null; then
    printf 'systemd ollama: %s\n' "$(with_timeout systemctl is-active ollama 2>&1)"
    with_timeout systemctl show ollama --no-pager \
      -p ActiveState -p SubState -p ExecMainStatus -p NRestarts 2>&1
    with_timeout journalctl -u ollama -n 10 --no-pager 2>&1
  else
    log "systemd: unavailable"
  fi
  if command -v ss >/dev/null; then
    log "--- listener :11434 ---"
    ss -ltnp 2>&1 | grep -F ':11434' || log "  port 11434 not listening"
  fi
  log "--- api $API/api/tags ---"
  curl -sS --max-time 3 "$API/api/tags" 2>&1 | head -c 400
  printf '\n'
  if command -v ollama >/dev/null; then
    log "--- models ---"
    with_timeout ollama list 2>&1
  fi
}

start_via_systemd() {
  systemctl list-unit-files --type=service 2>&1 | grep -q '^ollama\.service' || return 1
  sudo -n true || { err "systemd unit found but sudo needs a password; run: sudo systemctl start ollama"; return 1; }
  log "starting systemd unit ollama"
  sudo systemctl start ollama || return 1
}

start_manual() {
  command -v ollama >/dev/null || { err "ollama CLI not found"; return 1; }
  log "starting: OLLAMA_MAX_LOADED_MODELS=1 OLLAMA_NUM_PARALLEL=1 OLLAMA_KEEP_ALIVE=5m ollama serve"
  OLLAMA_MAX_LOADED_MODELS=1 OLLAMA_NUM_PARALLEL=1 OLLAMA_KEEP_ALIVE=5m \
    nohup ollama serve >"$LOG" 2>&1 &
  log "serve pid: $! (log: $LOG)"
}

wait_for_api() {
  local i
  i=0
  while [ "$i" -lt "$WAIT_SECONDS" ]; do
    if api_up; then
      pass "ollama API ready"
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done
  fail "ollama API did not come up within ${WAIT_SECONDS}s"
  if [ -f "$LOG" ]; then
    log "--- last lines of $LOG ---"
    tail -n 20 "$LOG"
  fi
  return 1
}

ensure_model() {
  local name="$1"
  if model_present "$name"; then
    pass "model $name present"
    return 0
  fi
  if [ "$DO_PULL" -eq 1 ]; then
    log "pulling $name"
    ollama pull "$name" || { fail "ollama pull $name failed"; return 1; }
    pass "model $name pulled"
    return 0
  fi
  fail "model $name not pulled; run: ollama pull $name (or rerun with --pull)"
}

main() {
  parse_args "$@"
  command -v curl >/dev/null || die "curl not found"
  if [ "$STATUS_ONLY" -eq 1 ]; then
    show_status
    return 0
  fi

  show_status

  if api_up; then
    pass "ollama API already up"
  else
    start_via_systemd || start_manual || die "could not start ollama"
    wait_for_api || return 2
  fi

  ensure_model "$MODEL" || return 2
  ensure_model "$EMBED_MODEL" || return 2

  show_status
  return 0
}

main "$@"
exit $?
