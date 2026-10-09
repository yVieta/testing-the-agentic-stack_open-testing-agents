#!/bin/sh
# Maybe rewritten later into a typesafe starter instead of shell script
# start-services.sh — declaratively start (or stop) every self-hosted service
# in this repo with OpenTofu.
#
# Every module owns its own state and a `service_state` variable, so this is a
# thin ordered wrapper around `tofu apply`:
#
#   start: model-setup -> sut-setup -> mcp-setup -> agent-setup -> odysseus-setup
#   stop : the exact reverse (odysseus-setup -> agent-setup -> mcp-setup -> sut-setup -> model-setup)
#
# Stopping keeps all state: podman images, GGUF weights, the Postgres data dir
# and the Odysseus/agent volumes are untouched. `tofu destroy` is a separate,
# destructive operation and is intentionally not wrapped here.
#
# `start` draws a live status bar (when stderr is a TTY) showing the elapsed
# time, an ETA until every service is up, and the module currently applying.
# Each module's `tofu apply` output is captured to a log file under
# $START_LOG_DIR (default /tmp/aigents-start-logs) and printed only on failure.
# ETA seeds come from per-module defaults and are refined from previous runs, so
# the estimate improves over time; override them in seconds with START_ETA_*.
#
# Usage:
#   ./start-services.sh                 # start every service (default)
#   ./start-services.sh start           # same
#   ./start-services.sh stop            # stop every service, reverse order
#   ./start-services.sh restart         # stop then start
#   ./start-services.sh status          # show tofu outputs for each module
#   ./start-services.sh start model-setup agent-setup   # a subset, in order
#
# Environment:
#   TOFU=/usr/bin/tofu        # override the binary (defaults to tofu, else terraform)
#   TOFU_ARGS="-compact-warnings"   # extra flags appended to every apply
#   START_BAR=auto|always|never     # status bar (default: auto = when stderr is a TTY)
#   START_ETA_*=<seconds>           # per-module ETA seeds
#   START_LOG_DIR=<dir>             # where apply logs are written
#   START_TIMES_FILE=<file>         # where observed durations are cached
#
# POSIX sh only (no bashisms) so it runs under busybox/dash/ash too.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# Startup order (dependencies first: the model and DB before the agents).
ALL_MODULES="model-setup sut-setup mcp-setup agent-setup odysseus-setup"
# Shutdown order = reverse of the above.
REVERSE_MODULES="odysseus-setup agent-setup mcp-setup sut-setup model-setup"

# --- pick a binary ------------------------------------------------------------
if [ -n "${TOFU:-}" ]; then
  TOFU_BIN=$TOFU
elif command -v tofu >/dev/null 2>&1; then
  TOFU_BIN=tofu
elif command -v terraform >/dev/null 2>&1; then
  TOFU_BIN=terraform
else
  echo "start-services: neither 'tofu' nor 'terraform' found on PATH" >&2
  exit 1
fi

TOFU_ARGS=${TOFU_ARGS:-}
SELF=$SCRIPT_DIR/$(basename -- "$0")

usage() {
  cat <<'EOF'
start-services.sh — declaratively start (or stop) every self-hosted service.

Usage:
  ./start-services.sh [start|stop|restart|status] [module ...]

Actions:
  start     apply service_state=running to every module (default)
  stop      apply service_state=stopped, in reverse startup order
  restart   stop, then start
  status    print the tofu outputs for each module

Modules (startup order):
  model-setup  sut-setup  mcp-setup  agent-setup  odysseus-setup

With no module arguments every module is touched; pass module names to target a
subset. Stopping keeps images, model weights and data directories intact.

During `start` a status bar shows the elapsed time and an ETA until all
services are up. Per-module apply logs go to $START_LOG_DIR
(default /tmp/aigents-start-logs) and are printed if a module fails.

Environment:
  TOFU               path to the OpenTofu/Terraform binary (default: tofu, else terraform)
  TOFU_ARGS          extra flags appended to every apply (e.g. -compact-warnings)
  START_BAR          auto (default) | always | never — status bar control
  START_ETA_MODEL    seed seconds for model-setup
  START_ETA_SUT      seed seconds for sut-setup
  START_ETA_MCP      seed seconds for mcp-setup
  START_ETA_AGENT    seed seconds for agent-setup
  START_ETA_ODYSSEUS seed seconds for odysseus-setup
  START_ETA_DEFAULT  seed seconds for any other module
  START_LOG_DIR      directory for per-module apply logs
  START_TIMES_FILE   file caching observed durations (refines the ETA)
EOF
}

# --- parse the action ---------------------------------------------------------
action=${1:-start}
if [ "$#" -gt 0 ]; then
  shift
fi

case "$action" in
  start|up|running)  action=start ;;
  stop|down|stopped) action=stop ;;
  restart)
    "$SELF" stop "$@"
    exec "$SELF" start "$@"
    ;;
  status|state)      action=status ;;
  -h|--help|help)    usage; exit 0 ;;
  *)
    echo "start-services: unknown action '$action' (try --help)" >&2
    exit 2
    ;;
esac

# --- resolve the module list --------------------------------------------------
# Explicit modules are honoured in the order given; otherwise all modules in the
# direction that matches the action.
if [ "$#" -gt 0 ]; then
  MODULES="$*"
elif [ "$action" = stop ]; then
  MODULES=$REVERSE_MODULES
else
  MODULES=$ALL_MODULES
fi

# =============================================================================
# Progress bar + ETA (used by `start` only)
# =============================================================================
BAR_WIDTH=${START_BAR_WIDTH:-28}
_TIMES_FILE=${START_TIMES_FILE:-${XDG_STATE_HOME:-${HOME:-/tmp}/.local/state}/aigents/start-times}

case "${START_BAR:-auto}" in
  never|no|false|0)  _use_bar=0 ;;
  always|yes|true|1) _use_bar=1 ;;
  *) [ -t 2 ] && _use_bar=1 || _use_bar=0 ;;
esac

_fmt_dur() { # seconds -> [H:]M:SS
  _s=${1:-0}
  [ "$_s" -lt 0 ] 2>/dev/null && _s=0
  if [ "$_s" -ge 3600 ]; then
    printf '%d:%02d:%02d' "$((_s / 3600))" "$(((_s % 3600) / 60))" "$((_s % 60))"
  else
    printf '%d:%02d' "$((_s / 60))" "$((_s % 60))"
  fi
}

_eta_default() { # module -> default seed seconds
  case "$1" in
    model-setup)    echo "${START_ETA_MODEL:-180}" ;;
    sut-setup)      echo "${START_ETA_SUT:-30}" ;;
    mcp-setup)      echo "${START_ETA_MCP:-30}" ;;
    agent-setup)    echo "${START_ETA_AGENT:-180}" ;;
    odysseus-setup) echo "${START_ETA_ODYSSEUS:-120}" ;;
    *)              echo "${START_ETA_DEFAULT:-60}" ;;
  esac
}

_eta_override() { # module -> env override (or empty)
  case "$1" in
    model-setup)    echo "${START_ETA_MODEL:-}" ;;
    sut-setup)      echo "${START_ETA_SUT:-}" ;;
    mcp-setup)      echo "${START_ETA_MCP:-}" ;;
    agent-setup)    echo "${START_ETA_AGENT:-}" ;;
    odysseus-setup) echo "${START_ETA_ODYSSEUS:-}" ;;
    *)              echo "${START_ETA_DEFAULT:-}" ;;
  esac
}

_eta_cached() { # module -> cached seconds (or empty)
  [ -f "$_TIMES_FILE" ] || return 0
  sed -n "s/^$1=\([0-9][0-9]*\)$/\1/p" "$_TIMES_FILE" 2>/dev/null | tail -n 1
}

_eta_lookup() { # module -> seconds: env override, else cache, else default
  _ov=$(_eta_override "$1")
  if [ -n "$_ov" ]; then printf '%s\n' "$_ov"; return 0; fi
  _c=$(_eta_cached "$1")
  if [ -n "$_c" ]; then printf '%s\n' "$_c"; return 0; fi
  _eta_default "$1"
}

_eta_store() { # module observed_seconds -> exponentially smoothed into the cache
  _m=$1
  _obs=$2
  [ "$_obs" -lt 1 ] 2>/dev/null && _obs=1
  _old=$(_eta_cached "$_m")
  [ -n "$_old" ] || _old=$(_eta_default "$_m")
  _new=$(( (_old + _obs) / 2 ))
  _dir=$(dirname -- "$_TIMES_FILE")
  mkdir -p "$_dir" 2>/dev/null || true
  _tmp="$_TIMES_FILE.$$"
  if [ -f "$_TIMES_FILE" ]; then
    grep -v "^$_m=" "$_TIMES_FILE" >"$_tmp" 2>/dev/null || : >"$_tmp"
  else
    : >"$_tmp"
  fi
  printf '%s=%s\n' "$_m" "$_new" >>"$_tmp"
  mv "$_tmp" "$_TIMES_FILE" 2>/dev/null || true
}

_render_bar() { # pct module elapsed_seconds eta_seconds
  [ "$_use_bar" = 1 ] || return 0
  _pct=$1
  _mod=$2
  _el=$3
  _eta=$4
  [ "$_pct" -lt 0 ] && _pct=0
  [ "$_pct" -gt 100 ] && _pct=100
  _filled=$(( _pct * BAR_WIDTH / 100 ))
  _empty=$(( BAR_WIDTH - _filled ))
  _bar=$(printf '%*s' "$_filled" '' | tr ' ' '#')$(printf '%*s' "$_empty" '' | tr ' ' '.')
  printf '\r%-100s' "  [$_bar] $(printf '%3d' "$_pct")%  $_mod  elapsed $(_fmt_dur "$_el")  ETA $(_fmt_dur "$_eta")" >&2
}

run_start() {
  # Non-interactive (no TTY): keep the original streaming behaviour.
  if [ "$_use_bar" = 0 ]; then
    for module in $MODULES; do
      dir="$SCRIPT_DIR/$module"
      if [ ! -d "$dir" ]; then
        echo "start-services: no such module '$module' under $SCRIPT_DIR" >&2
        exit 1
      fi
      echo ">>> [$module] apply service_state=running"
      # shellcheck disable=SC2086  # TOFU_ARGS is intentionally word-split
      "$TOFU_BIN" -chdir="$dir" apply \
        -input=false -auto-approve \
        -var service_state=running $TOFU_ARGS
    done
    return 0
  fi

  # Estimated total across the selected modules.
  _total_est=0
  for _m in $MODULES; do
    _total_est=$(( _total_est + $(_eta_lookup "$_m") ))
  done

  _logdir=${START_LOG_DIR:-${TMPDIR:-/tmp}/aigents-start-logs}
  mkdir -p "$_logdir" 2>/dev/null || true
  printf '  apply logs: %s\n' "$_logdir" >&2
  printf '  estimated %s until all services are up\n' "$(_fmt_dur "$_total_est")" >&2

  _completed=0
  _remaining_est=$_total_est
  _cur_pid=

  cleanup() {
    [ -n "$_cur_pid" ] && kill "$_cur_pid" 2>/dev/null || true
    printf '\n' >&2
    exit 130
  }
  trap cleanup INT TERM

  for module in $MODULES; do
    dir="$SCRIPT_DIR/$module"
    if [ ! -d "$dir" ]; then
      echo "start-services: no such module '$module' under $SCRIPT_DIR" >&2
      exit 1
    fi

    _est=$(_eta_lookup "$module")
    _after_est=$(( _remaining_est - _est ))
    [ "$_after_est" -lt 0 ] && _after_est=0

    _log="$_logdir/$module.log"
    _rcfile="$_logdir/$module.rc"
    rm -f "$_rcfile"
    _start_ts=$(date +%s)

    (
      _rc=0
      # shellcheck disable=SC2086  # TOFU_ARGS is intentionally word-split
      "$TOFU_BIN" -chdir="$dir" apply \
        -input=false -auto-approve \
        -var service_state=running $TOFU_ARGS >"$_log" 2>&1 || _rc=$?
      echo "$_rc" >"$_rcfile"
    ) &
    _cur_pid=$!

    while [ ! -f "$_rcfile" ]; do
      _within=$(( $(date +%s) - _start_ts ))
      _cost=$_within
      [ "$_est" -gt "$_cost" ] && _cost=$_est
      _denom=$(( _completed + _cost + _after_est ))
      [ "$_denom" -lt 1 ] && _denom=1
      _numer=$(( _completed + _within ))
      _render_bar \
        "$(( _numer * 100 / _denom ))" \
        "$module" \
        "$(( _completed + _within ))" \
        "$(( _denom - _numer ))"
      sleep 1
    done

    wait "$_cur_pid" 2>/dev/null || true
    _cur_pid=
    _rc=$(cat "$_rcfile" 2>/dev/null || echo 1)
    _dur=$(( $(date +%s) - _start_ts ))
    _completed=$(( _completed + _dur ))
    _remaining_est=$(( _remaining_est - _est ))
    [ "$_remaining_est" -lt 0 ] && _remaining_est=0
    _eta_store "$module" "$_dur"

    if [ "$_rc" = 0 ]; then
      printf '\r%-100s\n' "  [done] $module in $(_fmt_dur "$_dur")" >&2
    else
      printf '\r%-100s\n' "  [failed] $module (exit $_rc) - log: $_log" >&2
      cat "$_log" >&2
      exit "$_rc"
    fi
  done

  printf '\r%-100s' "  all services started in $(_fmt_dur "$_completed")" >&2
  printf '\n' >&2
}

# =============================================================================
# Main
# =============================================================================
case "$action" in
  start)
    run_start
    ;;
  stop)
    for module in $MODULES; do
      dir="$SCRIPT_DIR/$module"
      if [ ! -d "$dir" ]; then
        echo "start-services: no such module '$module' under $SCRIPT_DIR" >&2
        exit 1
      fi
      echo ">>> [$module] apply service_state=stopped"
      # shellcheck disable=SC2086  # TOFU_ARGS is intentionally word-split
      "$TOFU_BIN" -chdir="$dir" apply \
        -input=false -auto-approve \
        -var service_state=stopped $TOFU_ARGS
    done
    ;;
  status)
    for module in $MODULES; do
      dir="$SCRIPT_DIR/$module"
      if [ ! -d "$dir" ]; then
        echo "start-services: no such module '$module' under $SCRIPT_DIR" >&2
        exit 1
      fi
      echo ">>> [$module] outputs"
      "$TOFU_BIN" -chdir="$dir" output || true
    done
    ;;
esac

echo "start-services: done ($action)."
