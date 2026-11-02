#!/usr/bin/env bash
#
# 01-audit-cpu-lock.sh
# Diagnose a Ryzen low-frequency lock (for example all cores at ~400 MHz) and
# verify whether the clock rises under load. Read-only by default.
#
# Guardrails: no sed, no 2>/dev/null, no set -e, no rm -rf, exits 0 or 2.
#
# Usage:
#   ./scripts/01-audit-cpu-lock.sh
#   ./scripts/01-audit-cpu-lock.sh --stress 10
#   ./scripts/01-audit-cpu-lock.sh --firmware
#   ./scripts/01-audit-cpu-lock.sh --apply-firmware --yes
#   ./scripts/01-audit-cpu-lock.sh --help

SCRIPT_NAME="01-audit-cpu-lock.sh"
STRESS_SECONDS=0
CHECK_FIRMWARE=0
APPLY_FIRMWARE=0
ASSUME_YES=0
MAX_FREQ=0

usage() {
  printf '%s\n' "Usage: $SCRIPT_NAME [--stress SECONDS] [--firmware] [--apply-firmware --yes]"
  printf '%s\n' ""
  printf '%s\n' "  --stress SECONDS   run N busy loops, sample the clock under load"
  printf '%s\n' "  --firmware         show fwupdmgr devices/updates (read-only)"
  printf '%s\n' "  --apply-firmware   run fwupdmgr update -y (requires --yes)"
  printf '%s\n' "  --yes              confirm firmware update"
  printf '%s\n' "  --help             this text"
}

log() { printf '%s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; }
die() { err "$*"; exit 2; }

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --stress)
        shift
        STRESS_SECONDS="$1"
        case "$STRESS_SECONDS" in
          ''|*[!0-9]*) die "--stress needs a whole number of seconds" ;;
        esac
        ;;
      --firmware) CHECK_FIRMWARE=1 ;;
      --apply-firmware) APPLY_FIRMWARE=1; CHECK_FIRMWARE=1 ;;
      --yes) ASSUME_YES=1 ;;
      --help|-h) usage; exit 0 ;;
      *) die "unknown option: $1 (try --help)" ;;
    esac
    shift
  done
}

cpu_field() {
  local path="/sys/devices/system/cpu/cpu0/cpufreq/$1"
  if [ -r "$path" ]; then
    cat "$path"
  else
    printf 'unavailable'
  fi
}

sample_freq() {
  local c v n sum
  n=0
  sum=0
  MAX_FREQ=0
  for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do
    [ -r "$c" ] || continue
    v=$(cat "$c")
    n=$((n + 1))
    sum=$((sum + v))
    if [ "$v" -gt "$MAX_FREQ" ]; then
      MAX_FREQ="$v"
    fi
  done
  if [ "$n" -gt 0 ]; then
    printf '  max=%d MHz avg=%d MHz cores=%d\n' \
      "$((MAX_FREQ / 1000))" "$((sum / n / 1000))" "$n"
  else
    log "  cpufreq sysfs unavailable"
  fi
}

telemetry() {
  log "================================================================================"
  log "CPU LOCK AUDIT"
  log "================================================================================"
  log "host:    $(hostname)"
  log "date:    $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  log "kernel:  $(uname -r)"
  if command -v systemd-detect-virt >/dev/null; then
    log "virt:    $(systemd-detect-virt)"
  fi

  log ""
  log "--- cpu ---"
  if command -v lscpu >/dev/null; then
    lscpu | grep -E 'Model name|^CPU\(s\)|Thread\(s\)|Core\(s\)|MHz'
  fi
  log "driver:  $(cpu_field scaling_driver)"
  log "governor:$(cpu_field scaling_governor)"
  log "cur:     $(cpu_field scaling_cur_freq) kHz"
  log "min:     $(cpu_field scaling_min_freq) kHz"
  log "max:     $(cpu_field scaling_max_freq) kHz"
  log "steps:   $(cpu_field scaling_available_frequencies)"
  if [ -r /sys/devices/system/cpu/cpufreq/boost ]; then
    log "boost:   $(cat /sys/devices/system/cpu/cpufreq/boost)"
  fi
  if [ -r /sys/devices/system/cpu/amd_pstate/status ]; then
    log "pstate:  $(cat /sys/devices/system/cpu/amd_pstate/status)"
  else
    log "pstate:  unavailable (driver is acpi-cpufreq?)"
  fi

  log ""
  log "--- clock now ---"
  sample_freq

  log ""
  log "--- thermal / power ---"
  for h in /sys/class/hwmon/hwmon*; do
    [ -r "$h/name" ] || continue
    name=$(cat "$h/name")
    for t in "$h"/temp*_input; do
      [ -r "$t" ] || continue
      printf '  %s %s=%dC\n' "$name" "${t##*/}" "$(( $(cat "$t") / 1000 ))"
    done
  done
  for p in /sys/class/power_supply/*; do
    [ -d "$p" ] || continue
    printf '  %s:' "${p##*/}"
    for f in online status capacity charge_control_end_threshold; do
      [ -r "$p/$f" ] && printf ' %s=%s' "$f" "$(cat "$p/$f")"
    done
    printf '\n'
  done

  log ""
  log "--- pressure / load ---"
  cat /proc/loadavg
  for f in /proc/pressure/cpu /proc/pressure/memory /proc/pressure/io; do
    printf '  %s: ' "${f##*/}"
    cat "$f"
  done

  if command -v journalctl >/dev/null; then
    log ""
    log "--- kernel power/frequency messages ---"
    journalctl -k --no-pager 2>&1 | grep -iE 'cpc|pstate|ppc|throttl|prochot|power limit' | tail -20 || log "  none found (or permission denied)"
  fi
}

stress_test() {
  local seconds="$1" n i
  n=$(nproc)
  log ""
  log "--- stress: $n busy loops for ${seconds}s ---"
  i=0
  while [ "$i" -lt "$n" ]; do
    timeout "$seconds" sh -c 'while :; do :; done' &
    i=$((i + 1))
  done
  sleep $((seconds / 2))
  sample_freq
  wait
}

firmware_check() {
  command -v fwupdmgr >/dev/null || die "fwupdmgr not found; install fwupd (Fedora: dnf install fwupd)"
  log ""
  log "--- firmware ---"
  fwupdmgr refresh --force 2>&1 | tail -20
  fwupdmgr get-devices 2>&1 | tail -60
  if [ "$APPLY_FIRMWARE" -eq 1 ]; then
    [ "$ASSUME_YES" -eq 1 ] || die "--apply-firmware requires --yes"
    log "applying firmware updates..."
    fwupdmgr update -y 2>&1 | tail -60
  fi
}

guide() {
  log ""
  log "================================================================================"
  log "IF THE CLOCK STAYS LOW UNDER LOAD"
  log "================================================================================"
  log "1. EC reset: shut down, unplug AC, hold power 15-30s (or BIOS"
  log "   'Disconnect Battery'), plug AC, boot, rerun with --stress 10."
  log "2. Update BIOS/EC: ./scripts/01-audit-cpu-lock.sh --firmware"
  log "   then: sudo fwupdmgr update"
  log "3. Try the EC power-cap bypass at boot (temporary): add"
  log "   processor.ignore_ppc=1 to the kernel command line."
  log "4. Verify the AC adapter is the correct OEM wattage; try another adapter."
  log "5. Check for _CPC: sudo journalctl -k | grep -i cpc"
  log "   if absent, amd_pstate cannot load; firmware/BIOS is the fix."
  log ""
  log "A 399 MHz reading on every core with governor=performance is a platform"
  log "lock, not a Docker/Ollama tuning problem."
}

main() {
  parse_args "$@"
  telemetry

  if [ "$CHECK_FIRMWARE" -eq 1 ]; then
    firmware_check
  fi

  if [ "$STRESS_SECONDS" -gt 0 ]; then
    stress_test "$STRESS_SECONDS"
    if [ "$MAX_FREQ" -lt 1000000 ]; then
      err "all cores stayed below 1 GHz under load: platform/EC frequency lock"
      guide
      return 2
    fi
    log "clock rises under load (max ${MAX_FREQ} kHz)"
  fi

  guide
  return 0
}

main "$@"
exit $?
