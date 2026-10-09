#!/bin/sh
# Maybe rewritten later into a typesafe starter instead of shell script
# start-services.sh — declaratively start (or stop) every self-hosted service
# in this repo with OpenTofu.
#
# Every module owns its own state and a `service_state` variable, so this is a
# thin ordered wrapper around `tofu apply`:
#
#   start: model-setup -> sut-setup -> agent-setup -> odysseus-setup
#   stop : the exact reverse (odysseus-setup -> agent-setup -> sut-setup -> model-setup)
#
# Stopping keeps all state: podman images, GGUF weights, the Postgres data dir
# and the Odysseus/agent volumes are untouched. `tofu destroy` is a separate,
# destructive operation and is intentionally not wrapped here.
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
#
# POSIX sh only (no bashisms) so it runs under busybox/dash/ash too.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# Startup order (dependencies first: the model and DB before the agents).
ALL_MODULES="model-setup sut-setup agent-setup odysseus-setup"
# Shutdown order = reverse of the above.
REVERSE_MODULES="odysseus-setup agent-setup sut-setup model-setup"

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
  model-setup  sut-setup  agent-setup  odysseus-setup

With no module arguments every module is touched; pass module names to target a
subset. Stopping keeps images, model weights and data directories intact.

Environment:
  TOFU        path to the OpenTofu/Terraform binary (default: tofu, else terraform)
  TOFU_ARGS   extra flags appended to every apply (e.g. -compact-warnings)
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

# --- run ----------------------------------------------------------------------
for module in $MODULES; do
  dir="$SCRIPT_DIR/$module"
  if [ ! -d "$dir" ]; then
    echo "start-services: no such module '$module' under $SCRIPT_DIR" >&2
    exit 1
  fi

  case "$action" in
    start)
      echo ">>> [$module] apply service_state=running"
      # shellcheck disable=SC2086  # TOFU_ARGS is intentionally word-split
      "$TOFU_BIN" -chdir="$dir" apply \
        -input=false -auto-approve \
        -var service_state=running $TOFU_ARGS
      ;;
    stop)
      echo ">>> [$module] apply service_state=stopped"
      # shellcheck disable=SC2086
      "$TOFU_BIN" -chdir="$dir" apply \
        -input=false -auto-approve \
        -var service_state=stopped $TOFU_ARGS
      ;;
    status)
      echo ">>> [$module] outputs"
      "$TOFU_BIN" -chdir="$dir" output || true
      ;;
  esac
done

echo "start-services: done ($action)."
