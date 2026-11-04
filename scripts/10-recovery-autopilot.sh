#!/usr/bin/env bash
#
# 10-recovery-autopilot.sh
# Run 08 --all --yes under a watchdog that self-corrects known stalls:
#   - Ollama down or a model missing -> 09 --pull, then retry
#   - I/O still above threshold      -> wait, then retry
#   - sudo password / push auth      -> stop with the exact manual step
#
# Host-only. Exits 0 when recovery completes, 2 when it cannot self-correct.
#
# Usage:
#   ./scripts/10-recovery-autopilot.sh
#   ./scripts/10-recovery-autopilot.sh --max-attempts 4
#   ./scripts/10-recovery-autopilot.sh --log /tmp/recovery.log
#   ./scripts/10-recovery-autopilot.sh --retry-sleep 30

SCRIPT_NAME="10-recovery-autopilot.sh"
RAG_DIR="${RAG_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"
RETRY_SLEEP="${RETRY_SLEEP:-20}"
LOG="${LOG:-/tmp/recovery-autopilot.log}"
DRY_RUN=0

log() { printf '%s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; }
pass() { printf 'GATE PASS  %s\n' "$*"; }
die() { err "$*"; exit 2; }

usage() {
  printf '%s\n' "Usage: $SCRIPT_NAME [--max-attempts N] [--retry-sleep N] [--log PATH] [--dry-run]"
  printf '%s\n' ""
  printf '%s\n' "  --max-attempts N   stop after N attempts (default $MAX_ATTEMPTS)"
  printf '%s\n' "  --retry-sleep N    seconds to wait after an I/O failure (default $RETRY_SLEEP)"
  printf '%s\n' "  --log PATH         tee the run to PATH (default $LOG)"
  printf '%s\n' "  --dry-run          print the plan, run nothing"
  printf '%s\n' "  --help             this text"
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --max-attempts) shift; MAX_ATTEMPTS="$1" ;;
      --retry-sleep) shift; RETRY_SLEEP="$1" ;;
      --log) shift; LOG="$1" ;;
      --dry-run) DRY_RUN=1 ;;
      --help|-h) usage; exit 0 ;;
      *) die "unknown option: $1 (try --help)" ;;
    esac
    shift
  done
}

classify() {
  local f="$1"
  [ -f "$f" ] || { printf 'unknown'; return 0; }
  if grep -q "ollama API unreachable" "$f" || grep -qE "model .* not pulled" "$f" \
    || grep -q "Embedding request failed" "$f"; then
    printf 'ollama'
    return 0
  fi
  if grep -q "I/O pressure still above" "$f"; then
    printf 'io'
    return 0
  fi
  if grep -q "sudo needs a password" "$f"; then
    printf 'sudo'
    return 0
  fi
  if grep -qE "push failed|push helper failed|still ahead" "$f"; then
    printf 'push'
    return 0
  fi
  printf 'unknown'
}

run_recovery() {
  ( cd "$RAG_DIR" && ./scripts/08-gated-recovery.sh --all --yes ) 2>&1 | tee "$LOG"
  return "${PIPESTATUS[0]}"
}

main() {
  parse_args "$@"
  [ -x "$RAG_DIR/scripts/08-gated-recovery.sh" ] || die "08-gated-recovery.sh not executable in $RAG_DIR"
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] %s/scripts/08-gated-recovery.sh --all --yes | tee %s\n' "$RAG_DIR" "$LOG"
    printf '[dry-run] on failure: pull models via 09 --pull; retry I/O; stop on sudo/push auth\n'
    return 0
  fi

  local attempt cause rc
  attempt=1
  while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
    log "=== autopilot attempt $attempt/$MAX_ATTEMPTS (log: $LOG) ==="
    run_recovery
    rc=$?
    if [ "$rc" -eq 0 ]; then
      pass "recovery complete on attempt $attempt"
      return 0
    fi
    cause=$(classify "$LOG")
    err "attempt $attempt failed (rc=$rc, cause=$cause)"
    case "$cause" in
      ollama)
        [ "$attempt" -lt "$MAX_ATTEMPTS" ] || break
        log "remedy: start ollama and pull chat + embedding models"
        "$RAG_DIR/scripts/09-ollama-start.sh" --pull || die "could not start/pull ollama models"
        ;;
      io)
        [ "$attempt" -lt "$MAX_ATTEMPTS" ] || break
        log "remedy: I/O still high; waiting ${RETRY_SLEEP}s before retry"
        sleep "$RETRY_SLEEP"
        ;;
      sudo)
        err "sudo needs a password; run manually: sudo pkill -TERM -x updatedb; sudo pkill -TERM -x plocate-updated"
        return 2
        ;;
      push)
        err "push needs host auth; run: gh auth login -h github.com -s repo"
        return 2
        ;;
      *)
        err "unclassified failure; last 20 lines of $LOG:"
        tail -n 20 "$LOG" >&2
        return 2
        ;;
    esac
    attempt=$((attempt + 1))
  done
  die "not recovered after $MAX_ATTEMPTS attempt(s); log: $LOG"
}

main "$@"
exit $?
