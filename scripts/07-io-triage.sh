#!/usr/bin/env bash
#
# 07-io-triage.sh
# Diagnose the post-EC-reset I/O bottleneck, optionally stop an updatedb scan,
# lower dashboard I/O, and run the RAG runbook phases.
#
# Guardrails: no sed, no 2>/dev/null, no set -e, no rm -rf, exits 0 or 2.
#
# Usage:
#   ./scripts/07-io-triage.sh
#   ./scripts/07-io-triage.sh --stop-updatedb --yes
#   ./scripts/07-io-triage.sh --dashboard-low-io
#   ./scripts/07-io-triage.sh --dashboard-low-io --restart-web --yes
#   ./scripts/07-io-triage.sh --rag
#   ./scripts/07-io-triage.sh --help

SCRIPT_NAME="07-io-triage.sh"
HARNESS_DIR="${HARNESS_DIR:-/home/owner/Documents/9e3e0363-0237-4c38-93dc-ce25e2f1ec37/repo}"
RAG_DIR="${RAG_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
DASH_URL="${DASH_URL:-https://127.0.0.1:5099/api/resources}"
DASH_URL_FALLBACK="${DASH_URL_FALLBACK:-http://127.0.0.1:5099/api/resources}"
STOP_UPDATEDB=0
DASH_LOW_IO=0
RESTART_WEB=0
RUN_RAG=0
ASSUME_YES=0

usage() {
  printf '%s\n' "Usage: $SCRIPT_NAME [--stop-updatedb] [--dashboard-low-io] [--rag]"
  printf '%s\n' ""
  printf '%s\n' "  --stop-updatedb     stop updatedb/plocate-updatedb (requires --yes)"
  printf '%s\n' "  --dashboard-low-io  append DASH_SSE_MS/DASH_SEGMENTS/DASH_AUTO_SHED to .env.local"
  printf '%s\n' "  --restart-web       with --dashboard-low-io, run web-restart.sh (drops session)"
  printf '%s\n' "  --rag               run 06 --phase 2, 03 local-LLM, 06 --phase 4"
  printf '%s\n' "  --yes               skip typed confirmation"
  printf '%s\n' "  --help              this text"
}

log() { printf '%s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; }
die() { err "$*"; exit 2; }

confirm() {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  [ -t 0 ] || { err "not a terminal; pass --yes"; return 1; }
  printf '%s\n' "$1"
  printf 'Type YES to continue: '
  read -r answer
  [ "$answer" = "YES" ]
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --stop-updatedb) STOP_UPDATEDB=1 ;;
      --dashboard-low-io) DASH_LOW_IO=1 ;;
      --restart-web) RESTART_WEB=1 ;;
      --rag) RUN_RAG=1 ;;
      --yes) ASSUME_YES=1 ;;
      --help|-h) usage; exit 0 ;;
      *) die "unknown option: $1 (try --help)" ;;
    esac
    shift
  done
}

show_io() {
  log "=== load / pressure ==="
  cat /proc/loadavg
  for f in /proc/pressure/cpu /proc/pressure/memory /proc/pressure/io; do
    printf '  %s: ' "${f##*/}"
    cat "$f"
  done
  if command -v vmstat >/dev/null; then
    log "=== vmstat (watch wa) ==="
    vmstat 1 2
  fi
}

show_updatedb() {
  log "=== updatedb / plocate / indexers ==="
  if command -v pgrep >/dev/null; then
    pgrep -a -x updatedb || log "  updatedb: not running"
    pgrep -a -x plocate-updated || log "  plocate-updatedb: not running"
    pgrep -a -x tracker-miner-f || log "  tracker-miner-fs: not running"
    pgrep -a -x baloo_file || log "  baloo_file: not running"
  else
    log "  pgrep unavailable"
  fi
}

show_io_top() {
  log "=== top I/O ==="
  if command -v iotop >/dev/null; then
    if sudo -n true 2>&1; then
      sudo iotop -bo -n1 | head -20
    else
      log "  iotop present; run: sudo iotop -bo -n1"
    fi
  elif command -v pidstat >/dev/null; then
    pidstat -d 1 1 | head -20
  else
    log "  iotop/pidstat unavailable; install sysstat/iotop for per-process I/O"
  fi
}

show_docker() {
  log "=== docker ==="
  if ! command -v docker >/dev/null; then
    log "  docker CLI unavailable"
    return 0
  fi
  docker stats --no-stream --format '  {{.Name}} cpu={{.CPUPerc}} mem={{.MemUsage}} block={{.BlockIO}}'
  printf '  logging driver: '
  docker info --format '{{.LoggingDriver}}' 2>&1
  docker system df 2>&1 | head -10
}

show_files() {
  log "=== stores / logs ==="
  for p in \
    "$HARNESS_DIR/data/opencode/opencode.db" \
    "$HARNESS_DIR/data/opencode/opencode.db-wal" \
    "$RAG_DIR/vector_store.db"; do
    if [ -e "$p" ]; then
      ls -lh "$p"
    else
      log "  absent: $p"
    fi
  done
  if [ -d "$HARNESS_DIR/logs" ]; then
    du -sh "$HARNESS_DIR/logs" 2>&1
  fi
}

show_dashboard() {
  log "=== dashboard /api/resources ==="
  if ! command -v curl >/dev/null; then
    log "  curl unavailable"
    return 0
  fi
  local body
  body=$(curl -k -sS --max-time 5 "$DASH_URL" 2>&1)
  case "$body" in
    *"wrong version number"*|*"SSL routines"*|*"error:0A"*)
      body=$(curl -sS --max-time 5 "$DASH_URL_FALLBACK" 2>&1)
      ;;
  esac
  case "$body" in
    \{*) printf '%s\n' "$body" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print("  cpu_psi_10:", d.get("cpu_psi_10"))
print("  load:", d.get("load"))
print("  sse_clients:", d.get("sse_clients"))
print("  segments:", d.get("segments"))
print("  auto_shed:", d.get("auto_shed"))
print("  io:", (d.get("psi") or {}).get("io"))
' 2>&1 ;;
    *) log "  $body" ;;
  esac
}

stop_updatedb() {
  local pids
  command -v pgrep >/dev/null || die "pgrep unavailable; run this on the host"
  command -v pkill >/dev/null || die "pkill unavailable"
  pids=$(pgrep -x updatedb)
  if [ -z "$pids" ]; then
    log "updatedb is not running; nothing to stop"
    return 0
  fi
  confirm "Stop updatedb (PIDs: $pids)? It will resume only if something restarts it." || return 2
  sudo -n true || die "sudo needs a password; stop manually: sudo pkill -TERM -x updatedb"
  sudo pkill -TERM -x updatedb || die "could not stop updatedb"
  log "sent SIGTERM to updatedb"
  return 0
}

dashboard_low_io() {
  local envfile="$HARNESS_DIR/.env.local"
  [ -f "$envfile" ] || die "missing $envfile"
  for kv in "DASH_SSE_MS=30000" "DASH_SEGMENTS=cost" "DASH_AUTO_SHED=1"; do
    key="${kv%%=*}"
    if grep -q "^${key}=" "$envfile"; then
      log "already set: $key"
    else
      printf '%s\n' "$kv" >> "$envfile"
      log "appended: $kv"
    fi
  done
  log "dashboard I/O knobs are written; restart is required to apply"
  if [ "$RESTART_WEB" -eq 1 ]; then
    [ -x "$HARNESS_DIR/scripts/web-restart.sh" ] || die "web-restart.sh missing"
    confirm "Restart the opencode web container? This drops the current session." || return 2
    "$HARNESS_DIR/scripts/web-restart.sh" || die "web-restart.sh failed"
  else
    log "apply later: $HARNESS_DIR/scripts/web-restart.sh"
  fi
  return 0
}

run_rag() {
  [ -x "$RAG_DIR/scripts/06-runbook.sh" ] || die "06-runbook.sh missing in $RAG_DIR"
  [ -x "$RAG_DIR/scripts/03-verify-local-llm.sh" ] || die "03-verify-local-llm.sh missing"
  cd "$RAG_DIR" || die "cannot enter $RAG_DIR"
  ./scripts/06-runbook.sh --phase 2 || log "phase 2 returned nonzero"
  ./scripts/03-verify-local-llm.sh --model qwen2.5:3b-instruct --warm --max-seconds 120 \
    || log "local LLM verification returned nonzero"
  ./scripts/06-runbook.sh --phase 4 || log "phase 4 returned nonzero"
  return 0
}

main() {
  parse_args "$@"
  show_io
  show_updatedb
  show_io_top
  show_docker
  show_files
  show_dashboard

  if [ "$STOP_UPDATEDB" -eq 1 ]; then
    stop_updatedb || return $?
    log ""
    log "re-measure after it exits:"
    show_io
    show_dashboard
  fi

  if [ "$DASH_LOW_IO" -eq 1 ]; then
    dashboard_low_io || return $?
  fi

  if [ "$RUN_RAG" -eq 1 ]; then
    run_rag || return $?
  fi

  return 0
}

main "$@"
exit $?
