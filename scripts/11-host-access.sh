#!/usr/bin/env bash
#
# 11-host-access.sh
# Container -> host SSH access, command execution, and terminal capture.
#
# Bootstraps a local ssh client (apt download + extract, no root), a dedicated
# container key, and the host-side authorization. The private key stays in
# ~/.ssh and is never printed.
#
# Usage:
#   ./scripts/11-host-access.sh --check
#   ./scripts/11-host-access.sh --install --yes
#   ./scripts/11-host-access.sh --cmd 'hostname; uptime'
#   ./scripts/11-host-access.sh --screen [--out PATH]

SCRIPT_NAME="11-host-access.sh"
HOST="${HOST:-192.168.4.24}"
REMOTE_USER="${REMOTE_USER:-owner}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/opencode_container_ed25519}"
SSH_BIN="${SSH_BIN:-$HOME/.local/openssh/bin/ssh}"
SSH_KEYGEN="${SSH_KEYGEN:-$(dirname "$SSH_BIN")/ssh-keygen}"
AUTH_KEYS="${AUTH_KEYS:-/home/owner/.ssh/authorized_keys}"
KNOWN_HOSTS_FILE="${KNOWN_HOSTS_FILE:-/home/owner/.ssh/known_hosts}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-5}"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/openssh-client"
DISPLAY_NUM="${DISPLAY_NUM:-:0}"
XAUTH="${XAUTH:-/home/owner/.Xauthority}"
OUT="${OUT:-/tmp/opencode-term.png}"
REMOTE_SHOT="${REMOTE_SHOT:-/tmp/opencode-term.png}"
ASSUME_YES=0
MODE="check"
CMD=""
WINDOW=""
TMUX_SESSION="${TMUX_SESSION:-rag-recovery}"
TMUX_LINES="${TMUX_LINES:-200}"

log() { printf '%s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; }
pass() { printf 'GATE PASS  %s\n' "$*"; }
fail() { printf 'GATE FAIL  %s\n' "$*" >&2; return 1; }
die() { err "$*"; exit 2; }

usage() {
  printf '%s\n' "Usage: $SCRIPT_NAME [--check|--install|--cmd CMD|--screen] [--yes] [--out PATH]"
  printf '%s\n' ""
  printf '%s\n' "  --check    verify ssh client, key, and host login"
  printf '%s\n' "  --install  fetch ssh client, create the key, authorize it (needs --yes)"
  printf '%s\n' "  --cmd CMD  run CMD on the host and stream its output"
  printf '%s\n' "  --list     list host windows (id, desktop, title)"
  printf '%s\n' "  --screen   capture the host Terminal window and OCR it"
  printf '%s\n' "  --window ID capture this window id instead of the first Terminal"
  printf '%s\n' "  --tmux-list            list host tmux sessions"
  printf '%s\n' "  --tmux-new NAME        create a detached session (remain-on-exit)"
  printf '%s\n' "  --tmux-exec NAME CMD   run CMD inside the session"
  printf '%s\n' "  --tmux-capture NAME    print the session pane as text"
  printf '%s\n' "  --tmux-send NAME TEXT  paste TEXT + Enter (literal, no key parsing)"
  printf '%s\n' "  --tmux-kill NAME       kill the session"
  printf '%s\n' "  --lines N              capture scrollback lines (default $TMUX_LINES)"
  printf '%s\n' "  --out PATH local PNG path for --screen (default $OUT)"
  printf '%s\n' "  --yes      allow appending the public key to authorized_keys"
  printf '%s\n' ""
  printf '%s\n' "  HOST=$HOST REMOTE_USER=$REMOTE_USER SSH_KEY=$SSH_KEY"
  printf '%s\n' "  SSH_CONNECT_TIMEOUT=$SSH_CONNECT_TIMEOUT"
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --check) MODE="check" ;;
      --install) MODE="install" ;;
      --cmd) MODE="cmd"; shift; CMD="$1" ;;
      --list) MODE="list" ;;
      --screen) MODE="screen" ;;
      --window) shift; WINDOW="$1" ;;
      --tmux-list) MODE="tmux_list" ;;
      --tmux-new) MODE="tmux_new"; shift; TMUX_SESSION="$1" ;;
      --tmux-exec) MODE="tmux_exec"; shift; TMUX_SESSION="$1"; shift; CMD="$1" ;;
      --tmux-capture) MODE="tmux_capture"; shift; TMUX_SESSION="$1" ;;
      --tmux-send) MODE="tmux_send"; shift; TMUX_SESSION="$1"; shift; CMD="$1" ;;
      --tmux-kill) MODE="tmux_kill"; shift; TMUX_SESSION="$1" ;;
      --lines) shift; TMUX_LINES="$1" ;;
      --out) shift; OUT="$1" ;;
      --yes) ASSUME_YES=1 ;;
      --help|-h) usage; exit 0 ;;
      *) die "unknown option: $1 (try --help)" ;;
    esac
    shift
  done
}

install_client() {
  if [ -x "$SSH_BIN" ] && [ -x "$SSH_KEYGEN" ]; then
    pass "ssh client: $SSH_BIN"
    return 0
  fi
  command -v apt-get >/dev/null || die "apt-get not found; cannot fetch openssh-client"
  command -v dpkg-deb >/dev/null || die "dpkg-deb not found; cannot extract the package"
  mkdir -p "$CACHE" || die "cannot create $CACHE"
  ( cd "$CACHE" && apt-get download openssh-client ) || die "apt-get download failed"
  local deb
  deb=$(ls "$CACHE"/openssh-client_*.deb 2>&1 | head -n 1)
  [ -n "$deb" ] && [ -f "$deb" ] || die "openssh-client .deb not found in $CACHE"
  dpkg-deb -x "$deb" "$CACHE/root" || die "dpkg-deb extract failed"
  mkdir -p "$(dirname "$SSH_BIN")" || die "cannot create $(dirname "$SSH_BIN")"
  cp "$CACHE/root/usr/bin/ssh" "$CACHE/root/usr/bin/ssh-keygen" "$(dirname "$SSH_BIN")/" \
    || die "could not install ssh binaries"
  chmod 755 "$SSH_BIN" "$SSH_KEYGEN"
  pass "installed ssh client: $SSH_BIN"
}

ensure_key() {
  mkdir -p "$HOME/.ssh" || die "cannot create $HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  if [ ! -f "$SSH_KEY" ]; then
    "$SSH_KEYGEN" -t ed25519 -N '' -C opencode-container -f "$SSH_KEY" \
      || die "key generation failed"
  fi
  chmod 600 "$SSH_KEY"
  chmod 644 "$SSH_KEY.pub"
  pass "key: $("$SSH_KEYGEN" -lf "$SSH_KEY.pub" 2>&1)"
}

authorize_key() {
  [ -f "$AUTH_KEYS" ] || die "missing $AUTH_KEYS (is the host home mounted?)"
  local pub
  pub=$(cat "$SSH_KEY.pub") || die "cannot read $SSH_KEY.pub"
  if grep -qF "$pub" "$AUTH_KEYS"; then
    pass "key already authorized in $AUTH_KEYS"
    return 0
  fi
  if [ "$ASSUME_YES" -ne 1 ]; then
    fail "key not authorized; rerun with --install --yes to append the public key"
    return 1
  fi
  printf '%s\n' "$pub" >> "$AUTH_KEYS" || die "could not write $AUTH_KEYS"
  pass "appended public key to $AUTH_KEYS"
}

ssh_run() {
  "$SSH_BIN" -F /dev/null -i "$SSH_KEY" \
    -o BatchMode=yes -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS_FILE" \
    -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" "$REMOTE_USER@$HOST" "$@"
}

check_host() {
  [ -x "$SSH_BIN" ] || { fail "ssh client missing; run --install"; return 1; }
  [ -f "$SSH_KEY" ] || { fail "ssh key missing; run --install"; return 1; }
  local out
  out=$(ssh_run 'hostname; id -un; uptime -p' 2>&1) || { fail "ssh login failed after ConnectTimeout=${SSH_CONNECT_TIMEOUT}s: $out"; return 1; }
  printf '%s\n' "$out"
  pass "host login $REMOTE_USER@$HOST"
}

run_cmd() {
  [ -n "$CMD" ] || die "--cmd needs a command string"
  [ -x "$SSH_BIN" ] || die "ssh client missing; run --install"
  ssh_run "$CMD"
}

list_windows() {
  [ -x "$SSH_BIN" ] || die "ssh client missing; run --install"
  ssh_run "DISPLAY=$DISPLAY_NUM XAUTHORITY=$XAUTH wmctrl -l"
}

screen_terminal() {
  [ -x "$SSH_BIN" ] || die "ssh client missing; run --install"
  command -v tesseract >/dev/null || die "tesseract not installed in the container"
  local wid="$WINDOW"
  if [ -z "$wid" ]; then
    wid=$(ssh_run "DISPLAY=$DISPLAY_NUM XAUTHORITY=$XAUTH wmctrl -l | awk '/Terminal/ {print \$1; exit}'" 2>&1) \
      || die "wmctrl failed on host: $wid"
  fi
  [ -n "$wid" ] || die "no Terminal window found on $DISPLAY_NUM"
  log "terminal window: $wid"
  ssh_run "DISPLAY=$DISPLAY_NUM XAUTHORITY=$XAUTH import -window $wid $REMOTE_SHOT" \
    || die "window capture failed"
  ssh_run "cat $REMOTE_SHOT" > "$OUT" || die "could not transfer screenshot"
  ssh_run "rm -f $REMOTE_SHOT"
  log "screenshot: $OUT"
  tesseract "$OUT" stdout 2>&1
}

tmux_list() {
  ssh_run "tmux list-sessions"
}

tmux_new() {
  if ssh_run "tmux has-session -t $TMUX_SESSION" >/dev/null; then
    pass "session $TMUX_SESSION exists"
    return 0
  fi
  ssh_run "tmux new-session -d -s $TMUX_SESSION" || die "could not create $TMUX_SESSION"
  ssh_run "tmux set-option -t $TMUX_SESSION remain-on-exit on" || die "could not set remain-on-exit"
  ssh_run "sleep 0.5"
  pass "session $TMUX_SESSION created"
}

tmux_exec() {
  [ -n "$CMD" ] || die "--tmux-exec needs a command"
  local b64
  b64=$(printf '%s' "$CMD" | base64 -w0) || die "base64 encode failed"
  ssh_run "printf %s $b64 | base64 -d > /tmp/opencode-tmux-cmd.sh && chmod 700 /tmp/opencode-tmux-cmd.sh" \
    || die "could not stage the command"
  ssh_run "tmux send-keys -t $TMUX_SESSION -l 'bash /tmp/opencode-tmux-cmd.sh'" \
    || die "send-keys failed (missing session?)"
  ssh_run "tmux send-keys -t $TMUX_SESSION Enter" || die "Enter failed"
  pass "sent to $TMUX_SESSION"
}

tmux_capture() {
  ssh_run "tmux capture-pane -p -t $TMUX_SESSION -S -$TMUX_LINES" || die "capture failed"
}

tmux_send() {
  [ -n "$CMD" ] || die "--tmux-send needs text"
  local b64
  b64=$(printf '%s' "$CMD" | base64 -w0) || die "base64 encode failed"
  ssh_run "printf %s $b64 | base64 -d > /tmp/opencode-tmux-keys.txt && tmux load-buffer -b oc /tmp/opencode-tmux-keys.txt && tmux paste-buffer -b oc -t $TMUX_SESSION" \
    || die "paste failed"
  ssh_run "tmux send-keys -t $TMUX_SESSION Enter" || die "Enter failed"
  pass "sent text to $TMUX_SESSION"
}

tmux_kill() {
  ssh_run "tmux kill-session -t $TMUX_SESSION" || die "kill failed"
  pass "killed $TMUX_SESSION"
}

main() {
  parse_args "$@"
  case "$MODE" in
    install)
      install_client || return 2
      ensure_key || return 2
      authorize_key || return 2
      check_host || return 2
      ;;
    check) check_host || return 2 ;;
    cmd) run_cmd || return 2 ;;
    list) list_windows || return 2 ;;
    screen) screen_terminal || return 2 ;;
    tmux_list) tmux_list || return 2 ;;
    tmux_new) tmux_new || return 2 ;;
    tmux_exec) tmux_exec || return 2 ;;
    tmux_capture) tmux_capture || return 2 ;;
    tmux_send) tmux_send || return 2 ;;
    tmux_kill) tmux_kill || return 2 ;;
    *) usage; return 2 ;;
  esac
  return 0
}

main "$@"
exit $?
