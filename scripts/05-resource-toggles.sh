#!/usr/bin/env bash
#
# 05-resource-toggles.sh
# Interactive, recoverable pause/stop/restart toggles for host resource hogs.
# Records every pause/stop/low action so --restore can undo it.
#
# Guardrails: no sed, no 2>/dev/null, no set -e, no rm -rf, exits 0 or 2.
#
# Usage:
#   ./scripts/05-resource-toggles.sh                 # interactive menu
#   ./scripts/05-resource-toggles.sh --list
#   ./scripts/05-resource-toggles.sh --status
#   ./scripts/05-resource-toggles.sh --target grafana --action pause
#   ./scripts/05-resource-toggles.sh --target dashboard --action low
#   ./scripts/05-resource-toggles.sh --target web --action stop
#   ./scripts/05-resource-toggles.sh --restore
#
# Targets: web, dashboard, grafana, dockge, mesh, paypal, caddy, litellm,
#          chrome, ollama, or any explicit container name.
# Actions: pause, resume (unpause), stop, start, restart, low, status,
#          unload (ollama only).
#
# The dashboard is never killed by the bundled scripts; "pause" is an
# explicit, recoverable SIGSTOP that "resume" (or --restore) undoes.

SCRIPT_NAME="05-resource-toggles.sh"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/opencode-resource-toggles"
STATE="$STATE_DIR/state.tsv"
ASSUME_YES=0
DRY_RUN=0
TARGET=""
ACTION=""
MODE="interactive"

usage() {
  printf '%s\n' "Usage: $SCRIPT_NAME [--list|--status|--restore]"
  printf '%s\n' "       $SCRIPT_NAME --target NAME --action ACTION [--yes] [--dry-run]"
  printf '%s\n' ""
  printf '%s\n' "Targets: web dashboard grafana dockge mesh paypal caddy litellm chrome ollama"
  printf '%s\n' "Actions: pause resume stop start restart low status unload"
  printf '%s\n' ""
  printf '%s\n' "  --list       list targets and actions"
  printf '%s\n' "  --status     show load, PSI, containers, ollama, chrome, state"
  printf '%s\n' "  --restore    undo recorded pause/stop/low actions"
  printf '%s\n' "  --yes        skip typed confirmation"
  printf '%s\n' "  --dry-run    print commands instead of running them"
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

confirm() {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  [ -t 0 ] || { err "not a terminal; pass --yes"; return 1; }
  printf '%s\n' "$1"
  printf 'Type YES to continue: '
  read -r answer
  [ "$answer" = "YES" ]
}

ensure_state() {
  mkdir -p "$STATE_DIR" || die "cannot create $STATE_DIR"
  [ -f "$STATE" ] || : > "$STATE"
}

record() {
  # kind, name, detail, state
  ensure_state
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$STATE"
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --list) MODE="list" ;;
      --status) MODE="status" ;;
      --restore) MODE="restore" ;;
      --target) shift; TARGET="$1"; MODE="action" ;;
      --action) shift; ACTION="$1" ;;
      --yes) ASSUME_YES=1 ;;
      --dry-run) DRY_RUN=1 ;;
      --help|-h) usage; exit 0 ;;
      *) die "unknown option: $1 (try --help)" ;;
    esac
    shift
  done
}

have_docker() { command -v docker >/dev/null; }

resolve_container() {
  local target="$1" pattern name
  case "$target" in
    web) pattern="*opencode*web*" ;;
    grafana) pattern="*grafana*" ;;
    dockge) pattern="*dockge*" ;;
    mesh) pattern="*mesh-console*" ;;
    paypal) pattern="*paypal*" ;;
    caddy) pattern="*caddy*" ;;
    litellm) pattern="*litellm*" ;;
    *) printf '%s\n' "$target"; return 0 ;;
  esac
  have_docker || return 1
  for name in $(docker ps --format '{{.Names}}'); do
    case "$name" in
      $pattern) printf '%s\n' "$name"; return 0 ;;
    esac
  done
  return 1
}

list_targets() {
  log "Targets and actions"
  log "  web        pause resume stop start restart status"
  log "  dashboard  pause resume low status"
  log "  grafana    pause resume stop start restart status"
  log "  dockge     pause resume stop start restart status"
  log "  mesh       pause resume stop start restart status"
  log "  paypal     pause resume stop start restart status"
  log "  caddy      pause resume stop start restart status  (cuts web access)"
  log "  litellm    pause resume stop start restart status  (may cut model access)"
  log "  chrome     pause resume low status                (pause freezes the browser)"
  log "  ollama     status unload stop start"
  log "  <name>     any running container name"
  log ""
  log "State file: $STATE"
  log "Undo everything recorded: --restore"
}

show_status() {
  log "================================================================================"
  log "RESOURCE STATUS"
  log "================================================================================"
  log "host: $(hostname)"
  log "load: $(cat /proc/loadavg)"
  grep -E 'MemTotal|MemAvailable|SwapTotal|SwapFree' /proc/meminfo
  for f in /proc/pressure/cpu /proc/pressure/memory /proc/pressure/io; do
    printf '  %s: ' "${f##*/}"
    cat "$f"
  done
  if have_docker; then
    log ""
    log "containers:"
    docker stats --no-stream --format '  {{.Name}} cpu={{.CPUPerc}} mem={{.MemUsage}}'
  else
    log ""
    log "containers: docker CLI unavailable here (run on the Docker host)"
  fi
  if command -v ollama >/dev/null; then
    log ""
    log "ollama:"
    ollama ps 2>&1
  fi
  if command -v pgrep >/dev/null && pgrep -x chrome >/dev/null; then
    log ""
    printf 'chrome processes: '
    pgrep -x chrome | wc -l
  fi
  ensure_state
  log ""
  log "recorded actions:"
  if [ -s "$STATE" ]; then cat "$STATE"; else log "  (none)"; fi
}

dashboard_pids() {
  local web
  web=$(resolve_container web) || die "opencode web container not found"
  docker exec "$web" sh -c 'pgrep -f dashboard.mjs' 2>&1
}

container_action() {
  local action="$1" target="$2" name
  name=$(resolve_container "$target") || die "container not found for target: $target"
  case "$action" in
    pause)
      confirm "Pause container $name? (recoverable with resume)" || return 2
      if [ "$DRY_RUN" -eq 0 ] && [ "$(docker inspect -f '{{.State.Paused}}' "$name" 2>&1)" = "true" ]; then
        log "$name already paused"
        return 0
      fi
      run docker pause "$name" || die "docker pause failed"
      record container "$name" "-" paused
      ;;
    resume|unpause)
      run docker unpause "$name" || die "docker unpause failed (not paused?)"
      record container "$name" "-" running
      ;;
    stop)
      confirm "Stop container $name? (recoverable with start)" || return 2
      run docker stop "$name" || die "docker stop failed"
      record container "$name" "-" stopped
      ;;
    start)
      run docker start "$name" || die "docker start failed"
      record container "$name" "-" running
      ;;
    restart)
      confirm "Restart container $name?" || return 2
      run docker restart "$name" || die "docker restart failed"
      record container "$name" "-" running
      ;;
    status)
      docker stats --no-stream --format '{{.Name}} cpu={{.CPUPerc}} mem={{.MemUsage}}' "$name"
      ;;
    *)
      die "unsupported action for containers: $action"
      ;;
  esac
}

dashboard_action() {
  local action="$1" web pids
  web=$(resolve_container web) || die "opencode web container not found"
  pids=$(dashboard_pids) || die "dashboard process not found"
  [ -n "$pids" ] || die "dashboard process not found"
  case "$action" in
    pause)
      confirm "Pause dashboard PID(s) [$pids] inside $web? (resume restores it)" || return 2
      run docker exec "$web" sh -c "kill -STOP $pids" || die "could not pause dashboard"
      record dashboard "$web" "$pids" paused
      ;;
    resume)
      run docker exec "$web" sh -c "kill -CONT $pids" || die "could not resume dashboard"
      record dashboard "$web" "$pids" running
      ;;
    low)
      run docker exec "$web" sh -c "renice 10 -p $pids" || die "could not renice dashboard"
      run docker exec "$web" sh -c "command -v ionice >/dev/null && ionice -c3 -p $pids || true"
      record dashboard "$web" "$pids" low
      ;;
    status)
      docker exec "$web" sh -c "for p in $pids; do cat /proc/\$p/stat | awk '{print \$1, \$14, \$15}'; done"
      ;;
    *)
      die "unsupported dashboard action: $action"
      ;;
  esac
}

chrome_action() {
  local action="$1" pids
  command -v pgrep >/dev/null || die "pgrep not found"
  pids=$(pgrep -x chrome) || die "no chrome processes found"
  case "$action" in
    pause)
      confirm "Pause ALL chrome processes? The browser will freeze; resume or --restore unfreezes it." || return 2
      run pkill -STOP -x chrome || die "could not pause chrome"
      record chrome "-" "-" paused
      ;;
    resume)
      run pkill -CONT -x chrome || die "could not resume chrome"
      record chrome "-" "-" running
      ;;
    low)
      run renice 10 -p $pids || die "could not renice chrome"
      record chrome "-" "$pids" low
      ;;
    status)
      ps -o pid,pcpu,pmem,args -p $pids
      ;;
    *)
      die "unsupported chrome action: $action"
      ;;
  esac
}

unload_ollama() {
  local line model
  command -v ollama >/dev/null || die "ollama CLI not found"
  line=$(ollama ps 2>&1 | tail -n +2 | head -n1)
  [ -n "$line" ] || { log "no loaded models"; return 0; }
  model=$(printf '%s\n' "$line" | awk '{print $1}')
  confirm "Unload ollama model $model? (reloads on the next request)" || return 2
  run curl -sS http://localhost:11434/api/generate -d "{\"model\":\"$model\",\"keep_alive\":0}" >/dev/null
  log "unloaded $model"
}

ollama_action() {
  local action="$1"
  case "$action" in
    status) ollama ps 2>&1 ;;
    unload) unload_ollama ;;
    stop)
      confirm "Stop the ollama service? RAG queries will fail until started." || return 2
      if command -v systemctl >/dev/null && systemctl is-active ollama >/dev/null; then
        run sudo systemctl stop ollama || die "systemctl stop failed"
        record service ollama "-" stopped
      else
        die "ollama is not a systemd service; stop it manually"
      fi
      ;;
    start)
      if command -v systemctl >/dev/null; then
        run sudo systemctl start ollama || die "systemctl start failed"
        record service ollama "-" running
      else
        die "start ollama manually (ollama serve)"
      fi
      ;;
    *) die "unsupported ollama action: $action" ;;
  esac
}

do_action() {
  local action="$1" target="$2"
  case "$target" in
    dashboard) dashboard_action "$action" ;;
    chrome) chrome_action "$action" ;;
    ollama) ollama_action "$action" ;;
    *) container_action "$action" "$target" ;;
  esac
}

restore_state() {
  local kind a b state
  ensure_state
  if [ ! -s "$STATE" ]; then
    log "nothing to restore"
    return 0
  fi
  confirm "Restore every recorded pause/stop/low action?" || return 2
  while IFS=$'\t' read -r kind a b state; do
    [ -n "$kind" ] || continue
    case "$kind:$state" in
      container:paused) run docker unpause "$a" ;;
      container:stopped) run docker start "$a" ;;
      dashboard:paused) run docker exec "$a" sh -c "kill -CONT $b" ;;
      dashboard:low) run docker exec "$a" sh -c "renice 0 -p $b" ;;
      chrome:paused) run pkill -CONT -x chrome ;;
      chrome:low) run renice 0 -p $b ;;
      service:stopped) run sudo systemctl start "$a" ;;
      *) : ;;
    esac
  done < "$STATE"
  : > "$STATE"
  log "state cleared"
}

interactive() {
  local line target action
  while :; do
    log ""
    show_status
    printf 'resource> target action (e.g. grafana pause, dashboard low, restore, q): '
    read -r line || break
    [ -n "$line" ] || continue
    case "$line" in
      q|quit|exit) break ;;
      restore) restore_state ;;
      *)
        set -- $line
        target="$1"
        action="$2"
        if [ -z "$action" ]; then
          err "need: target action"
          continue
        fi
        do_action "$action" "$target"
        ;;
    esac
  done
  return 0
}

main() {
  parse_args "$@"
  case "$MODE" in
    list) list_targets; return 0 ;;
    status) show_status; return 0 ;;
    restore) restore_state; return $? ;;
    action)
      [ -n "$TARGET" ] || die "--target is required"
      [ -n "$ACTION" ] || die "--action is required"
      do_action "$ACTION" "$TARGET"
      return $?
      ;;
    interactive) interactive; return $? ;;
  esac
  return 0
}

main "$@"
exit $?
