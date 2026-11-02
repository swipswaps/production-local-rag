#!/usr/bin/env bash
#
# 06-runbook.sh
# Guided steps 1-6: prove/fix the CPU lock, relieve contention, unload models,
# verify retrieval-only, reload the dashboard, and print the feedback plan.
#
# Guardrails: no sed, no 2>/dev/null, no set -e, no rm -rf, exits 0 or 2.
#
# Usage:
#   ./scripts/06-runbook.sh --phase 1                 # baseline + EC reset guide
#   ./scripts/06-runbook.sh --phase 1 --stress 10
#   ./scripts/06-runbook.sh --phase 1 --after-reboot   # compare after reboot
#   ./scripts/06-runbook.sh --phase 2                 # dashboard low / pause extras
#   ./scripts/06-runbook.sh --phase 3                 # unload ollama + env
#   ./scripts/06-runbook.sh --phase 4                 # retrieval-only proof
#   ./scripts/06-runbook.sh --phase 5                 # dashboard reload guidance
#   ./scripts/06-runbook.sh --phase 5 --restart-web --yes
#   ./scripts/06-runbook.sh --phase 6                 # feedback-loop plan
#   ./scripts/06-runbook.sh --all
#   ./scripts/06-runbook.sh --status

SCRIPT_NAME="06-runbook.sh"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/opencode-runbook"
BASELINE="$STATE_DIR/cpu-before.tsv"
PHASE=""
AFTER_REBOOT=0
RESTART_WEB=0
ASSUME_YES=0
STRESS=10
MODE=""

usage() {
  printf '%s\n' "Usage: $SCRIPT_NAME --phase N [options] | --all | --status"
  printf '%s\n' ""
  printf '%s\n' "  1  baseline CPU audit + EC reset guide (--after-reboot to compare)"
  printf '%s\n' "  2  lower dashboard priority; optionally pause optional containers"
  printf '%s\n' "  3  unload ollama models; write RAG_CHAT_TIMEOUT"
  printf '%s\n' "  4  retrieval-only proof (JSON chunks)"
  printf '%s\n' "  5  dashboard reload guidance (--restart-web --yes to apply)"
  printf '%s\n' "  6  feedback-loop plan"
  printf '%s\n' ""
  printf '%s\n' "  --stress N     seconds for the phase-1 stress test (default 10)"
  printf '%s\n' "  --yes          skip typed confirmation"
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
      --phase)
        shift
        PHASE="$1"
        MODE="phase"
        ;;
      --all) MODE="all" ;;
      --status) MODE="status" ;;
      --after-reboot) AFTER_REBOOT=1 ;;
      --restart-web) RESTART_WEB=1 ;;
      --stress)
        shift
        STRESS="$1"
        case "$STRESS" in ''|*[!0-9]*) die "--stress needs seconds" ;; esac
        ;;
      --yes) ASSUME_YES=1 ;;
      --help|-h) usage; exit 0 ;;
      *) die "unknown option: $1 (try --help)" ;;
    esac
    shift
  done
}

max_freq_from() {
  grep -o 'max=[0-9]*' "$1" | tail -n1 | cut -d= -f2
}

resolve_web() {
  local name
  command -v docker >/dev/null || return 1
  for name in $(docker ps --format '{{.Names}}'); do
    case "$name" in
      *opencode*web*) printf '%s\n' "$name"; return 0 ;;
    esac
  done
  return 1
}

phase1() {
  local out rc max governor baseline_max
  mkdir -p "$STATE_DIR"
  out=$(mktemp)
  log "=== phase 1: CPU audit (stress ${STRESS}s) ==="
  ./scripts/01-audit-cpu-lock.sh --stress "$STRESS" >"$out" 2>&1
  rc=$?
  max=$(max_freq_from "$out")
  governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>&1)
  log "stress max: ${max:-unknown} MHz (governor: $governor)"
  grep -E 'stress:|max=|cur:|thermal|capacity|online' "$out" | tail -12

  if [ "$AFTER_REBOOT" -eq 1 ]; then
    if [ ! -f "$BASELINE" ]; then
      rm -f "$out"
      die "no baseline; run --phase 1 first"
    fi
    baseline_max=$(awk -F'\t' 'NR==1{print $2}' "$BASELINE")
    log "baseline: ${baseline_max} MHz   after: ${max} MHz"
    rm -f "$out"
    if [ -n "$max" ] && [ "$max" -ge 1000 ]; then
      log "clock recovered (>= 1000 MHz); continue with phase 2"
      return 0
    fi
    err "clock still below 1 GHz after reboot"
    log "next: ./scripts/01-audit-cpu-lock.sh --firmware"
    log "      sudo fwupdmgr update"
    log "      verify AC adapter wattage; try processor.ignore_ppc=1"
    return 2
  fi

  printf '%s\t%s\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${max:-0}" "$governor" > "$BASELINE"
  rm -f "$out"
  log "baseline written: $BASELINE"

  if [ -n "$max" ] && [ "$max" -ge 1000 ]; then
    log "clock is healthy under load; EC reset not needed"
    return 0
  fi

  log ""
  log "=== EC reset (physical; this ends the session) ==="
  log "1. Save work and shut down completely."
  log "2. Unplug AC."
  log "3. ThinkPad: use the pinhole reset (paperclip ~10-15s) if present;"
  log "   otherwise hold power 15-30s. Remove the battery if removable."
  log "4. Plug AC, boot, wait for the desktop and Docker."
  log "5. Rerun: ./scripts/06-runbook.sh --phase 1 --after-reboot"
  log ""
  log "If still 399 MHz after the EC reset: firmware/BIOS update, AC adapter"
  log "wattage check, then processor.ignore_ppc=1 as a last workaround."
  return 2
}

phase2() {
  log "=== phase 2: relieve contention (dashboard stays enabled) ==="
  ./scripts/02-relieve-contention.sh --dashboard-low || log "dashboard low skipped (docker unavailable?)"
  ./scripts/05-resource-toggles.sh --status | head -30
  if confirm "Pause optional containers (grafana, dockge, mesh, paypal)?"; then
    for target in grafana dockge mesh paypal; do
      ./scripts/05-resource-toggles.sh --target "$target" --action pause --yes \
        || log "$target not paused (not running?)"
    done
  fi
  log "Chrome: close tabs or use chrome://discards; optional:"
  log "  ./scripts/05-resource-toggles.sh --target chrome --action low"
  log "Undo later: ./scripts/05-resource-toggles.sh --restore"
  return 0
}

phase3() {
  log "=== phase 3: unload models + timeouts ==="
  if command -v ollama >/dev/null; then
    ./scripts/05-resource-toggles.sh --target ollama --action unload --yes \
      || log "ollama unload skipped"
  else
    log "ollama CLI not found"
  fi
  log ""
  log "Restart the server with residency limits (takes effect on restart):"
  log "  OLLAMA_MAX_LOADED_MODELS=1 OLLAMA_NUM_PARALLEL=1 OLLAMA_KEEP_ALIVE=5m ollama serve"
  log ""
  if [ -f .env ]; then
    if ! grep -q '^RAG_CHAT_TIMEOUT=' .env; then
      printf 'RAG_CHAT_TIMEOUT=300\n' >> .env
      log "appended RAG_CHAT_TIMEOUT=300 to .env"
    else
      log ".env already has RAG_CHAT_TIMEOUT"
    fi
  else
    printf 'RAG_CHAT_TIMEOUT=300\n' > .env
    log "created .env with RAG_CHAT_TIMEOUT=300"
  fi
  return 0
}

phase4() {
  log "=== phase 4: retrieval-only proof ==="
  ./scripts/04-retrieval-only.sh --query "What is the pet policy?" --top-k 3 \
    || {
      err "retrieval failed; run ./scripts/setup-rag-venv.sh and pull nomic-embed-text"
      return 2
    }
  log ""
  log "Feed these chunks to opencode/DeepSeek. Do not use --answer on this host."
  return 0
}

phase5() {
  local web
  log "=== phase 5: dashboard reload ==="
  log "Set these in the web container environment (compose) before restart:"
  log "  DASH_SEGMENTS=cost,activity,todos"
  log "  DASH_SSE_MS=5000"
  log "  DASH_AUTO_SHED=1"
  if [ "$RESTART_WEB" -eq 1 ]; then
    confirm "Restart the opencode web container? This drops the current session." || return 2
    web=$(resolve_web) || die "opencode web container not found"
    docker restart "$web" || die "docker restart failed"
    log "restarted $web; reopen the web UI and resume the session"
  else
    log "Apply later with: ./scripts/06-runbook.sh --phase 5 --restart-web --yes"
  fi
  return 0
}

phase6() {
  log "=== phase 6: feedback loop (next increment) ==="
  log "1. Add a feedback table: session_id, part_id, rating, note, ts."
  log "2. Add GET/POST /api/feedback in dashboard.mjs (read/write, local only)."
  log "3. Add a dashboard panel: thumbs up/down per answer + note."
  log "4. Feed ratings into the health/signals report and the runbook."
  log "5. Keep segment toggles: DASH_SEGMENTS, DASH_SSE_MS, DASH_AUTO_SHED."
  log ""
  log "This closes the loop: DB telemetry + user feedback -> health -> toggles."
  return 0
}

show_status() {
  log "=== runbook status ==="
  if [ -f "$BASELINE" ]; then
    log "baseline: $(cat "$BASELINE")"
  else
    log "baseline: none (run --phase 1)"
  fi
  log "clock now: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>&1) kHz"
  log "load: $(cat /proc/loadavg)"
  log "psi cpu: $(cat /proc/pressure/cpu)"
  ./scripts/05-resource-toggles.sh --status | tail -20
}

run_phase() {
  case "$1" in
    1) phase1 ;;
    2) phase2 ;;
    3) phase3 ;;
    4) phase4 ;;
    5) phase5 ;;
    6) phase6 ;;
    *) die "phase must be 1-6" ;;
  esac
}

main() {
  parse_args "$@"
  case "$MODE" in
    status) show_status; return 0 ;;
    phase) run_phase "$PHASE"; return $? ;;
    all)
      run_phase 1 || return 2
      run_phase 2
      run_phase 3
      run_phase 4
      if [ "$RESTART_WEB" -eq 1 ]; then run_phase 5; else phase5; fi
      run_phase 6
      return 0
      ;;
    *) usage; return 2 ;;
  esac
}

main "$@"
exit $?
