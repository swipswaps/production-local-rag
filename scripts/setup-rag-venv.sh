#!/usr/bin/env bash
#
# setup-rag-venv.sh
# Create a compatible virtualenv and install the RAG engine dependencies.
# The pinned pydantic-core does not build on Python 3.14, so this picks a
# 3.10-3.13 interpreter.
#
# Guardrails: no sed, no 2>/dev/null, no set -e, no rm -rf, exits 0 or 2.
#
# Usage:
#   ./scripts/setup-rag-venv.sh
#   ./scripts/setup-rag-venv.sh --dry-run
#   ./scripts/setup-rag-venv.sh --venv /path/to/venv

SCRIPT_NAME="setup-rag-venv.sh"
VENV_DIR=".venv"
DRY_RUN=0
PYTHON=""
PYVER=""

usage() {
  printf '%s\n' "Usage: $SCRIPT_NAME [--venv DIR] [--dry-run] [--help]"
  printf '%s\n' ""
  printf '%s\n' "  --venv DIR   virtualenv location (default: .venv)"
  printf '%s\n' "  --dry-run    print commands without running them"
  printf '%s\n' "  --help       this text"
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
      --dry-run) DRY_RUN=1 ;;
      --venv)
        shift
        [ -n "$1" ] || die "--venv needs a path"
        VENV_DIR="$1"
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown option: $1 (try --help)"
        ;;
    esac
    shift
  done
}

pick_python() {
  local cand ver
  for cand in python3.13 python3.12 python3.11 python3.10; do
    if command -v "$cand" >/dev/null; then
      ver=$("$cand" -c 'import sys; print("%d.%d" % sys.version_info[:2])')
      case "$ver" in
        3.10|3.11|3.12|3.13)
          PYTHON="$cand"
          PYVER="$ver"
          return 0
          ;;
      esac
    fi
  done
  if command -v python3 >/dev/null; then
    ver=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')
    case "$ver" in
      3.10|3.11|3.12|3.13)
        PYTHON="python3"
        PYVER="$ver"
        return 0
        ;;
    esac
  fi
  return 1
}

main() {
  parse_args "$@"

  [ -f requirements.txt ] || die "requirements.txt not found; run from the repo root"

  if ! pick_python; then
    err "no supported Python found (need 3.10-3.13)."
    err "the pinned pydantic-core does not build on Python 3.14."
    printf '%s\n' "options:" >&2
    printf '%s\n' "  1. install python3.12 with your package manager" >&2
    printf '%s\n' "  2. use uv: uv venv --python 3.12 $VENV_DIR" >&2
    printf '%s\n' "  3. last resort: PYO3_USE_ABI3_FORWARD_COMPATIBILITY=1 python3 -m pip install -r requirements.txt" >&2
    return 2
  fi

  log "interpreter: $PYTHON ($PYVER)"
  log "venv:        $VENV_DIR"

  if [ -d "$VENV_DIR" ]; then
    log "existing venv found; refreshing with --clear"
    run "$PYTHON" -m venv --clear "$VENV_DIR" || die "venv creation failed; install the venv package for $PYTHON (Fedora: dnf install $PYTHON; Debian: apt install $PYTHON-venv)"
  else
    run "$PYTHON" -m venv "$VENV_DIR" || die "venv creation failed; install the venv package for $PYTHON (Fedora: dnf install $PYTHON; Debian: apt install $PYTHON-venv)"
  fi

  if [ "$DRY_RUN" -eq 0 ]; then
    if ! "$VENV_DIR/bin/python" -m pip --version >/dev/null; then
      die "pip is missing in $VENV_DIR; install it (Fedora: dnf install $PYTHON-pip; Debian: apt install $PYTHON-venv) and rerun"
    fi
  fi

  run "$VENV_DIR/bin/python" -m pip install --upgrade pip || die "pip upgrade failed"
  run "$VENV_DIR/bin/python" -m pip install -r requirements.txt || die "dependency install failed"
  run "$VENV_DIR/bin/python" -c 'import httpx, pydantic, pydantic_settings, numpy, sqlite_vec, rich; print("imports OK")' || die "import check failed"

  log ""
  log "ready. next:"
  log "  . $VENV_DIR/bin/activate"
  log "  python -m src.cli status"
  log "  python -m src.cli ingest docs/ --reset"
  log "  python -m src.cli query \"What is the pet policy?\""
  return 0
}

main "$@"
exit $?
