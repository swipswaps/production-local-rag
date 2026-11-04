#!/usr/bin/env bash
#
# 08-gated-recovery.sh
# Gated orchestration of the final recovery steps:
#   1. diagnose I/O, stop updatedb/plocate if present, re-measure PSI
#   2. require I/O pressure to fall below the threshold
#   3. lower dashboard I/O (append DASH_* to .env.local; optional restart)
#   4. run RAG phase 2, local-LLM verification, phase 4
#   5. push both repos and assert no local commits remain ahead
#
# Every assert fails closed with exit 2. Host-only (docker/pgrep/pkill/ollama).
# Guardrails: no sed, no 2>/dev/null, no set -e, no rm -rf.
#
# Usage:
#   ./scripts/08-gated-recovery.sh --diagnose
#   ./scripts/08-gated-recovery.sh --all --yes
#   ./scripts/08-gated-recovery.sh --all --yes --restart-web
#   ./scripts/08-gated-recovery.sh --stop-updatedb --yes
#   ./scripts/08-gated-recovery.sh --dashboard-low-io
#   ./scripts/08-gated-recovery.sh --rag
#   ./scripts/08-gated-recovery.sh --push
#   ./scripts/08-gated-recovery.sh --all --yes --dry-run

SCRIPT_NAME="08-gated-recovery.sh"
HARNESS_DIR="${HARNESS_DIR:-/home/owner/Documents/9e3e0363-0237-4c38-93dc-ce25e2f1ec37/repo}"
RAG_DIR="${RAG_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
PUSH_SCRIPT="${PUSH_SCRIPT:-/home/owner/.local/bin/push-opencode-repos.sh}"
IO_THRESHOLD="${IO_THRESHOLD:-20}"
WAIT_SECONDS="${WAIT_SECONDS:-60}"
MODEL="${MODEL:-qwen2.5:3b-instruct}"
EMBED_MODEL="${EMBED_MODEL:-nomic-embed-text}"

MODE="diagnose"
DO_STOP=0
DO_DASH=0
DO_RAG=0
DO_PUSH=0
RESTART_WEB=0
ASSUME_YES=0
DRY_RUN=0
ALLOW_HIGH_IO=0

log() { printf '%s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; }
pass() { printf 'GATE PASS  %s\n' "$*"; }
fail() { printf 'GATE FAIL  %s\n' "$*" >&2; return 1; }
die() { err "$*"; exit 2; }

confirm() {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  [ -t 0 ] || { err "not a terminal; pass --yes"; return 1; }
  printf '%s\n' "$1"
  printf 'Type YES to continue: '
  read -r answer
  [ "$answer" = "YES" ]
}

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] %s\n' "$*"
    return 0
  fi
  "$@"
}

usage() {
  printf '%s\n' "Usage: $SCRIPT_NAME [--diagnose|--all|--stop-updatedb|--dashboard-low-io|--rag|--push]"
  printf '%s\n' ""
  printf '%s\n' "  --diagnose          run 07-io-triage and the gates (default)"
  printf '%s\n' "  --all               stop indexers, wait for I/O, dashboard, RAG, push"
  printf '%s\n' "  --stop-updatedb     stop updatedb/plocate-updatedb (requires --yes)"
  printf '%s\n' "  --dashboard-low-io  append DASH_SSE_MS/DASH_SEGMENTS/DASH_AUTO_SHED"
  printf '%s\n' "  --restart-web       with dashboard: restart the web container"
  printf '%s\n' "  --rag               phase 2 + 03 local-LLM + phase 4"
  printf '%s\n' "  --push              push both repos and assert no ahead commits"
  printf '%s\n' "  --yes               skip typed confirmation"
  printf '%s\n' "  --dry-run           print actions, do not apply"
  printf '%s\n' "  --allow-high-io     do not fail if I/O pressure stays high"
  printf '%s\n' "  IO_THRESHOLD=N      io.full avg10 fail threshold (default $IO_THRESHOLD)"
  printf '%s\n' "  WAIT_SECONDS=N      wait bound for I/O drop (default $WAIT_SECONDS)"
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --diagnose) MODE="diagnose" ;;
      --all) MODE="all"; DO_STOP=1; DO_DASH=1; DO_RAG=1; DO_PUSH=1 ;;
      --stop-updatedb) DO_STOP=1 ;;
      --dashboard-low-io) DO_DASH=1 ;;
      --restart-web) RESTART_WEB=1 ;;
      --rag) DO_RAG=1 ;;
      --push) DO_PUSH=1 ;;
      --yes) ASSUME_YES=1 ;;
      --dry-run) DRY_RUN=1 ;;
      --allow-high-io) ALLOW_HIGH_IO=1 ;;
      --help|-h) usage; exit 0 ;;
      *) die "unknown option: $1 (try --help)" ;;
    esac
    shift
  done
}

require_cmd() {
  if command -v "$1" >/dev/null; then
    pass "command $1"
    return 0
  fi
  fail "missing command: $1"
}

host_preflight() {
  log "=== gate: host preflight ==="
  require_cmd docker || return 1
  require_cmd git || return 1
  require_cmd pgrep || return 1
  require_cmd pkill || return 1
  require_cmd curl || return 1
  require_cmd python3 || return 1
  if [ "$DO_RAG" -eq 1 ]; then require_cmd ollama || return 1; fi
  if [ "$DO_PUSH" -eq 1 ]; then
    [ -x "$PUSH_SCRIPT" ] || { fail "missing $PUSH_SCRIPT"; return 1; }
    pass "push helper $PUSH_SCRIPT"
  fi
}

assert_repo() {
  local name="$1" dir="$2"
  [ -d "$dir/.git" ] || { fail "$name is not a git repo: $dir"; return 1; }
  pass "$name repo: $dir"
  local branch
  branch=$(git -C "$dir" branch --show-current 2>&1)
  [ "$branch" = "main" ] || { fail "$name branch is '$branch', expected main"; return 1; }
  pass "$name branch main"
  git -C "$dir" remote get-url origin >/dev/null \
    || { fail "$name has no origin"; return 1; }
  pass "$name origin present"
}

assert_repos() {
  log "=== gate: repositories ==="
  assert_repo harness "$HARNESS_DIR" || return 1
  assert_repo rag "$RAG_DIR" || return 1
}

psi_io_full10() {
  awk '/^full/ { for (i=1;i<=NF;i++) if ($i ~ /^avg10=/) { split($i,a,"="); print a[2]; exit } }' /proc/pressure/io
}

measure_io() {
  log "=== io telemetry ==="
  cat /proc/loadavg
  cat /proc/pressure/io
  if command -v vmstat >/dev/null; then vmstat 1 2; fi
  local v
  v=$(psi_io_full10)
  printf 'io.full avg10: %s (threshold %s)\n' "${v:-unknown}" "$IO_THRESHOLD"
}

assert_dashboard() {
  log "=== gate: dashboard /api/resources ==="
  local body url
  for url in "https://127.0.0.1:5099/api/resources" "http://127.0.0.1:5099/api/resources"; do
    body=$(curl -k -sS --max-time 5 "$url" 2>&1)
    case "$body" in
      \{*) break ;;
    esac
  done
  case "$body" in
    \{*) ;;
    *) fail "dashboard not reachable: $body"; return 1 ;;
  esac
  printf '%s\n' "$body" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert "segments" in d, "segments missing"
assert "psi" in d, "psi missing"
print("  cpu_psi_10:", d.get("cpu_psi_10"))
print("  io:", (d.get("psi") or {}).get("io"))
print("  sse_clients:", d.get("sse_clients"))
print("  segments:", d.get("segments"))
print("  auto_shed:", d.get("auto_shed"))
' || { fail "dashboard JSON invalid"; return 1; }
  pass "dashboard /api/resources"
}

diagnose() {
  if [ -x "$RAG_DIR/scripts/07-io-triage.sh" ]; then
    "$RAG_DIR/scripts/07-io-triage.sh" || fail "07-io-triage returned nonzero"
  else
    fail "07-io-triage.sh missing"
  fi
  measure_io
}

stop_indexers() {
  log "=== gate: indexers ==="
  local pids_u pids_p
  pids_u=$(pgrep -x updatedb)
  pids_p=$(pgrep -x plocate-updated)
  if [ -z "$pids_u" ] && [ -z "$pids_p" ]; then
    pass "no updatedb/plocate-updatedb running"
    return 0
  fi
  log "running: updatedb=[$pids_u] plocate=[$pids_p]"
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] sudo pkill -TERM -x updatedb; sudo pkill -TERM -x plocate-updatedb\n'
    return 0
  fi
  [ "$ASSUME_YES" -eq 1 ] || { fail "indexer running; pass --yes to stop it"; return 1; }
  sudo -n true || { fail "sudo needs a password; stop it manually: sudo pkill -TERM -x updatedb; sudo pkill -TERM -x plocate-updated"; return 1; }
  if [ -n "$pids_u" ]; then sudo pkill -TERM -x updatedb || fail "could not stop updatedb"; fi
  if [ -n "$pids_p" ]; then sudo pkill -TERM -x plocate-updated || fail "could not stop plocate-updatedb"; fi
  local i
  i=0
  while [ "$i" -lt 30 ]; do
    if [ -z "$(pgrep -x updatedb)" ] && [ -z "$(pgrep -x plocate-updated)" ]; then
      pass "indexers stopped"
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done
  fail "indexers still running after 30s"
}

wait_io_drop() {
  log "=== gate: I/O pressure ==="
  local v i samples
  i=0
  samples=0
  while [ "$i" -lt "$WAIT_SECONDS" ]; do
    v=$(psi_io_full10)
    samples=$((samples + 1))
    printf '  sample=%s io.full avg10=%s (threshold %s)\n' "$samples" "${v:-unknown}" "$IO_THRESHOLD"
    case "$v" in
      ''|*[!0-9.]*) break ;;
    esac
    if awk -v v="$v" -v t="$IO_THRESHOLD" 'BEGIN { exit !(v + 0 <= t + 0) }'; then
      pass "I/O pressure <= ${IO_THRESHOLD}% after ${i}s (${samples} samples)"
      return 0
    fi
    i=$((i + 2))
    sleep 2
  done
  if [ "$ALLOW_HIGH_IO" -eq 1 ]; then
    pass "I/O pressure ${v:-unknown}% > ${IO_THRESHOLD}% after ${i}s (${samples} samples) but --allow-high-io set"
    return 0
  fi
  fail "I/O pressure ${v:-unknown}% still above ${IO_THRESHOLD}% after ${i}s (${samples} samples, last sample above); use --allow-high-io to override"
}

dashboard_low_io() {
  log "=== gate: dashboard I/O knobs ==="
  local envfile="$HARNESS_DIR/.env.local"
  [ -f "$envfile" ] || { fail "missing $envfile"; return 1; }
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] append DASH_SSE_MS=30000 DASH_SEGMENTS=cost,activity,todos DASH_AUTO_SHED=1 to %s\n' "$envfile"
    return 0
  fi
  for kv in "DASH_SSE_MS=30000" "DASH_SEGMENTS=cost,activity,todos" "DASH_AUTO_SHED=1"; do
    key="${kv%%=*}"
    if grep -q "^${key}=" "$envfile"; then
      pass "$key already set"
    else
      printf '%s\n' "$kv" >> "$envfile" || { fail "could not append $key"; return 1; }
      pass "$key appended"
    fi
  done
  if [ "$RESTART_WEB" -eq 1 ]; then
    confirm "Restart the opencode web container? This drops the current session." || { fail "restart not confirmed"; return 1; }
    run "$HARNESS_DIR/scripts/web-restart.sh" || { fail "web-restart.sh failed"; return 1; }
    local i
    i=0
    while [ "$i" -lt 60 ]; do
      body=$(curl -k -sS --max-time 5 https://127.0.0.1:5099/api/resources 2>&1)
      case "$body" in \{*) pass "dashboard back after restart"; return 0 ;; esac
      i=$((i + 2))
      sleep 2
    done
    fail "dashboard did not return after restart"
  else
    log "restart required to apply: $HARNESS_DIR/scripts/web-restart.sh"
  fi
}

rag_preflight() {
  log "=== gate: RAG prerequisites ==="
  [ -x "$RAG_DIR/.venv/bin/python" ] || { fail "missing $RAG_DIR/.venv"; return 1; }
  pass "venv present"
  "$RAG_DIR/.venv/bin/python" -c 'import httpx, pydantic_settings, numpy, sqlite_vec, rich' \
    || { fail "venv imports failed"; return 1; }
  pass "venv imports"
  curl -sS --max-time 5 http://127.0.0.1:11434/api/tags >/dev/null \
    || { fail "ollama API unreachable; run: ./scripts/09-ollama-start.sh (or sudo systemctl start ollama)"; return 1; }
  pass "ollama API"
  ollama list 2>&1 | grep -Fq "$MODEL" || { fail "model $MODEL not pulled; run: ollama pull $MODEL"; return 1; }
  pass "model $MODEL"
  ollama list 2>&1 | grep -Fq "$EMBED_MODEL" || { fail "embedding model $EMBED_MODEL not pulled; run: ollama pull $EMBED_MODEL"; return 1; }
  pass "embedding model $EMBED_MODEL"
  ( cd "$RAG_DIR" && ./scripts/rag-cli.sh status ) \
    || { fail "rag-cli status failed"; return 1; }
  pass "rag-cli status"
}

run_rag() {
  log "=== gate: RAG runbook ==="
  local -a yes=()
  [ "$ASSUME_YES" -eq 1 ] && yes=(--yes)
  ( cd "$RAG_DIR" && ./scripts/06-runbook.sh --phase 2 "${yes[@]}" ) \
    || { fail "06 --phase 2 failed"; return 1; }
  pass "06 --phase 2"
  ( cd "$RAG_DIR" && ./scripts/03-verify-local-llm.sh --model "$MODEL" --warm --max-seconds 120 ) \
    || { fail "03 local-LLM verification failed"; return 1; }
  pass "03 local-LLM verification"
  ( cd "$RAG_DIR" && ./scripts/06-runbook.sh --phase 4 "${yes[@]}" ) \
    || { fail "06 --phase 4 failed"; return 1; }
  pass "06 --phase 4"
}

push_repos() {
  log "=== gate: push ==="
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] %s\n' "$PUSH_SCRIPT"
    return 0
  fi
  "$PUSH_SCRIPT" || { fail "push helper failed (host auth?)"; return 1; }
  local repo ahead
  for repo in "$HARNESS_DIR" "$RAG_DIR"; do
    ahead=$(git -C "$repo" rev-list --count origin/main..HEAD 2>&1)
    if [ "$ahead" != "0" ]; then
      fail "$repo still ahead by $ahead commit(s)"
      return 1
    fi
    pass "$repo is up to date with origin/main"
  done
}

main() {
  parse_args "$@"
  host_preflight || return 2
  assert_repos || return 2
  assert_dashboard || return 2

  if [ "$MODE" = "diagnose" ] && [ "$DO_STOP$DO_DASH$DO_RAG$DO_PUSH" = "0000" ]; then
    diagnose
    measure_io
    return 0
  fi

  diagnose
  if [ "$DO_STOP" -eq 1 ]; then stop_indexers || return 2; fi
  wait_io_drop || return 2
  if [ "$DO_DASH" -eq 1 ]; then dashboard_low_io || return 2; fi
  if [ "$DO_RAG" -eq 1 ]; then rag_preflight || return 2; run_rag || return 2; fi
  if [ "$DO_PUSH" -eq 1 ]; then push_repos || return 2; fi
  measure_io
  return 0
}

main "$@"
exit $?
