#!/bin/sh
# Maybe rewritten later into a typesafe starter instead of shell script
# start-services.sh — declaratively start (or stop) every self-hosted service
# in this repo with OpenTofu.
#
# Every module owns its own state and a `service_state` variable, so this is a
# thin ordered wrapper around `tofu apply`:
#
#   start: model-setup -> sut-setup -> mcp-setup -> agent-setup -> 
#   stop : the exact reverse ( -> agent-setup -> mcp-setup -> sut-setup -> model-setup)
#
# `--parallel` (or `-P`) rearranges `start` into dependency waves applied
# concurrently, which is faster when several modules were changed at once:
#
#   wave 1: model-setup, sut-setup, mcp-setup   (independent)
#   wave 2: agent-setup,          (both need the model up)
#
# A subset given with `--parallel` is grouped the same way; modules whose
# dependencies fall outside the selection are treated as already satisfied.
#
# `tofu apply` only restarts a module whose triggers changed (rendered units and
# content hashes of the worker scripts/bus server). So a plain `start` already
# skips the model and SUT when only agent/bus code changed — a "code
# round-trip" restart of just those three is ~9 min (parallel: ~5 min) instead
# of the ~22-25 min a full `restart` (stop + start) takes.
#
# Stopping keeps all state: podman images, GGUF weights, the Postgres data dir
# and the agent volumes are untouched. `tofu destroy` is a separate,
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
#   ./start-services.sh --parallel start                 # apply in waves, concurrently
#   ./start-services.sh -P start mcp-setup agent-setup 
#
# With --parallel, `start` runs the modules in dependency waves (see the header
# comment) and reports each module's own duration; `stop` always stays in the
# safe reverse order.
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
  ./start-services.sh [--parallel] [start|stop|restart|status] [module ...]

Actions:
  start     apply service_state=running to every module (default)
  stop      apply service_state=stopped, in reverse startup order
  restart   stop, then start
  status    print the tofu outputs for each module

Options:
  --parallel  apply the start modules in dependency waves, concurrently
              (wave 1: model+sut+mcp; wave 2: agents+odysseus). Restart/stop
              still stop in reverse startup order. Faster than the sequential
              loop when several modules changed at once.

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

# --- parse the flags and the action ------------------------------------------
# --parallel / -P switches `start` into dependency-wave mode (see header).
FLAG_PARALLEL=0
_rest=""
for _a in "$@"; do
  case "$_a" in
    --parallel|-P) FLAG_PARALLEL=1 ;;
    *) _rest="$_rest $_a" ;;
  esac
done
# shellcheck disable=SC2086  # module names are plain words
set -- $_rest

action=${1:-start}
if [ "$#" -gt 0 ]; then
  shift
fi

case "$action" in
  start|up|running)  action=start ;;
  stop|down|stopped) action=stop ;;
  restart)
    _pf=""
    [ "$FLAG_PARALLEL" = 1 ] && _pf="--parallel"
    # shellcheck disable=SC2086
    "$SELF" $_pf stop "$@"
    # shellcheck disable=SC2086
    exec "$SELF" $_pf start "$@"
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
    *)              echo "${START_ETA_DEFAULT:-60}" ;;
  esac
}

_eta_override() { # module -> env override (or empty)
  case "$1" in
    model-setup)    echo "${START_ETA_MODEL:-}" ;;
    sut-setup)      echo "${START_ETA_SUT:-}" ;;
    mcp-setup)      echo "${START_ETA_MCP:-}" ;;
    agent-setup)    echo "${START_ETA_AGENT:-}" ;;
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
# Parallel start: apply the selected modules in dependency waves, running the
# modules of each wave concurrently. Wave 1 always holds the independent
# modules (model-setup, sut-setup, mcp-setup); wave 2 holds agent-setup and
# , which both expect the model stack to be up. For subset runs,
# a dependency outside the selection counts as already satisfied.
# =============================================================================

_module_deps() { # module -> space separated dependencies (or empty)
  case "$1" in
    agent-setup) echo "model-setup" ;;
    *) echo "" ;;
  esac
}

run_parallel_start() {
  # Preserve the canonical startup order for whatever was selected.
  _selected=""
  for _m in $ALL_MODULES; do
    for _s in $MODULES; do
      if [ "$_m" = "$_s" ]; then
        _selected="$_selected $_m"
        break
      fi
    done
  done
  if [ -z "$_selected" ]; then
    echo "start-services: nothing to start" >&2
    return 0
  fi

  _logdir=${START_LOG_DIR:-${TMPDIR:-/tmp}/aigents-start-logs}
  mkdir -p "$_logdir" 2>/dev/null || true
  printf '  parallel waves; apply logs: %s\n' "$_logdir" >&2

  _start_ts=$(date +%s)
  _done=""
  _wave=0
  while :; do
    # Which selected, not-yet-done modules have all their deps satisfied?
    _wave_mods=""
    for _m in $_selected; do
      case " $_done " in
        *" $_m "*) continue ;;
      esac
      _sat=1
      for _d in $(_module_deps "$_m"); do
        case " $_done " in
          *" $_d "*) ;;
          *) _sat=0 ;;
        esac
      done
      [ "$_sat" = 1 ] && _wave_mods="$_wave_mods $_m"
    done
    [ -n "$_wave_mods" ] || break
    _wave=$((_wave + 1))

    printf '  wave %d: %s\n' "$_wave" "$(printf '%s' "$_wave_mods" | sed 's/^ //')" >&2

    for _m in $_wave_mods; do
      _dir="$SCRIPT_DIR/$_m"
      if [ ! -d "$_dir" ]; then
        echo "start-services: no such module '$_m' under $SCRIPT_DIR" >&2
        exit 1
      fi
      _log="$_logdir/$_m.log"
      _rcfile="$_logdir/$_m.rc"
      rm -f "$_rcfile"
      date +%s >"$_logdir/$_m.ts"
      (
        _rc=0
        # shellcheck disable=SC2086  # TOFU_ARGS is intentionally word-split
        "$TOFU_BIN" -chdir="$_dir" apply \
          -input=false -auto-approve \
          -var service_state=running $TOFU_ARGS >"$_log" 2>&1 || _rc=$?
        echo "$_rc" >"$_rcfile"
      ) &
    done

    # Poll the per-module rc markers until this wave has finished. Snapshot a
    # module's own end time the moment its apply exits so durations stay
    # per-module even though the wave runs concurrently.
    while :; do
      _still=""
      for _m in $_wave_mods; do
        if [ -s "$_logdir/$_m.rc" ]; then
          [ -f "$_logdir/$_m.done_ts" ] || date +%s >"$_logdir/$_m.done_ts"
        else
          _still="$_still $_m"
        fi
      done
      [ -z "$_still" ] && break
      if [ "$_use_bar" = 1 ]; then
        _el=$(( $(date +%s) - _start_ts ))
        printf '\r  wave %d  running:%-22s elapsed %s  ' "$_wave" \
          "$(printf '%s' "$_still" | sed 's/^ //')" "$(_fmt_dur "$_el")" >&2
      fi
      sleep 1
    done
    wait 2>/dev/null || true

    _wave_failed=0
    for _m in $_wave_mods; do
      _rc=$(sed -n '1p' "$_logdir/$_m.rc" 2>/dev/null || echo 1)
      _ts=$(sed -n '1p' "$_logdir/$_m.ts" 2>/dev/null)
      [ -n "$_ts" ] || _ts=$_start_ts
      _done_ts=$(sed -n '1p' "$_logdir/$_m.done_ts" 2>/dev/null)
      [ -n "$_done_ts" ] || _done_ts=$(date +%s)
      _obs=$(( _done_ts - _ts ))
      _eta_store "$_m" "$_obs"
      if [ "$_rc" = 0 ]; then
        printf '\r%-100s\n' "  [done] $_m in $(_fmt_dur "$_obs")" >&2
      else
        _wave_failed=1
        printf '\r%-100s\n' "  [failed] $_m (exit $_rc) - log: $_logdir/$_m.log" >&2
        cat "$_logdir/$_m.log" >&2
      fi
    done
    [ "$_wave_failed" = 1 ] && exit 1
    _done="$_done$_wave_mods"
  done

  _dur=$(( $(date +%s) - _start_ts ))
  printf '\r%-100s\n' "  all modules started in $(_fmt_dur "$_dur")" >&2
}

# =============================================================================
# Main
# =============================================================================
case "$action" in
  start)
    if [ "$FLAG_PARALLEL" = 1 ]; then
      run_parallel_start
    else
      run_start
    fi
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
