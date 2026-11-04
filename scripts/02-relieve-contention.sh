#!/usr/bin/env bash
#
# 02-relieve-contention.sh
# Measure host contention, then optionally lower the dashboard's priority,
# cap non-essential containers, or stop named containers. The dashboard is
# never killed; it is only de-prioritised on request.
#
# Guardrails: no sed, no 2>/dev/null, no set -e, no rm -rf, exits 0 or 2.
#
# Usage:
#   ./scripts/02-relieve-contention.sh
#   ./scripts/02-relieve-contention.sh --dashboard-low
#   ./scripts/02-relieve-contention.sh --cap opencode-grafana:0.5 --cap dockge:0.5
#   ./scripts/02-relieve-contention.sh --stop paypal-saas-mvp_fail-web-1
#   ./scripts/02-relieve-contention.sh --dry-run --dashboard-low

SCRIPT_NAME="02-relieve-contention.sh"
DASHBOARD_LOW=0
DRY_RUN=0
CAPS=()
STOPS=()

usage() {
  printf '%s\n' "Usage: $SCRIPT_NAME [--dashboard-low] [--cap NAME:CPUS] [--stop NAME] [--dry-run]"
  printf '%s\n' ""
  printf '%s\n' "  --dashboard-low     renice/ionice the dashboard sidecar (keeps it running)"
  printf '%s\n' "  --cap NAME:CPUS     docker update --cpus for a container (repeatable)"
  printf '%s\n' "  --stop NAME         docker stop a container (repeatable)"
  printf '%s\n' "  --dry-run           print actions without applying them"
  printf '%s\n' "  --help              this text"
}

log() { printf '%s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; }
die() { err "$*"; exit 2; }

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] %s\n' "$*"
    return 0
  fi
  "$@"
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dashboard-low) DASHBOARD_LOW=1 ;;
      --cap)
        shift
        [ -n "$1" ] || die "--cap needs NAME:CPUS"
        case "$1" in
          *:*) CAPS+=("$1") ;;
          *) die "--cap needs NAME:CPUS (got: $1)" ;;
        esac
        ;;
      --stop)
        shift
        [ -n "$1" ] || die "--stop needs a container name"
        STOPS+=("$1")
        ;;
      --dry-run) DRY_RUN=1 ;;
      --help|-h) usage; exit 0 ;;
      *) die "unknown option: $1 (try --help)" ;;
    esac
    shift
  done
}

require_docker() {
  command -v docker >/dev/null || die "docker CLI not found; run on the Docker host"
}

find_web() {
  local name image
  docker ps --format '{{.Names}}|{{.Image}}' | while IFS='|' read -r name image; do
    case "$name" in
      *opencode*web*|*web*opencode*) printf '%s\n' "$name"; return 0 ;;
    esac
    case "$image" in
      *opencode*) case "$name" in *caddy*) ;; *) printf '%s\n' "$name"; return 0 ;; esac ;;
    esac
  done
}

telemetry() {
  log "================================================================================"
  log "CONTENTION TELEMETRY"
  log "================================================================================"
  log "host: $(hostname)"
  log "load: $(cat /proc/loadavg)"
  log "mem:"
  grep -E 'MemTotal|MemAvailable|SwapTotal|SwapFree' /proc/meminfo
  log "psi:"
  for f in /proc/pressure/cpu /proc/pressure/memory /proc/pressure/io; do
    printf '  %s: ' "${f##*/}"
    cat "$f"
  done
  log ""
  log "containers:"
  docker stats --no-stream --format '  {{.Name}} cpu={{.CPUPerc}} mem={{.MemUsage}}'
}

dashboard_low() {
  local web
  web=$(find_web)
  [ -n "$web" ] || die "opencode web container not found"
  log ""
  log "lowering dashboard priority inside $web (dashboard stays online)"
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] docker exec %s sh -c %s\n' "$web" "'renice +10 and ionice -c3 for dashboard.mjs'"
    return 0
  fi
  docker exec "$web" sh -c '
    for d in /proc/[0-9]*; do
      [ -r "$d/cmdline" ] || continue
      cmd=$(tr "\000" " " < "$d/cmdline")
      case "$cmd" in
        *dashboard.mjs*)
          p=${d#/proc/}
          renice 10 -p "$p" || true
          if command -v ionice >/dev/null; then ionice -c3 -p "$p" || true; fi
          ;;
      esac
    done
  ' || die "could not lower dashboard priority"
}

apply_changes() {
  local spec name cpus
  for spec in "${CAPS[@]}"; do
    name="${spec%%:*}"
    cpus="${spec##*:}"
    log "cap $name at ${cpus} CPU"
    run docker update --cpus "$cpus" "$name" || die "docker update failed for $name"
  done
  for name in "${STOPS[@]}"; do
    log "stop $name"
    run docker stop "$name" || die "docker stop failed for $name"
  done
}

main() {
  parse_args "$@"
  require_docker
  telemetry

  if [ "$DASHBOARD_LOW" -eq 1 ] || [ "${#CAPS[@]}" -gt 0 ] || [ "${#STOPS[@]}" -gt 0 ]; then
    dashboard_low
    apply_changes
    log ""
    log "after:"
    telemetry
  else
    log ""
    log "No changes requested. Suggested:"
    log "  --dashboard-low                      keep dashboard, lower its CPU priority"
    log "  --cap opencode-grafana:0.5          cap a noisy container"
    log "  --stop <container>                   stop an unused container"
    log ""
    log "Also free interactive CPU: close Chrome tabs (chrome://discards) or view"
    log "opencode from another device through Caddy."
  fi
  return 0
}

main "$@"
exit $?
