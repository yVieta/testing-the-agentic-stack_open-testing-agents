#!/bin/sh
# Imperative shutdown of deployed services: 
# stop-services.sh — stop every self-hosted service via OpenTofu.
#
# Thin wrapper around `start-services.sh stop`, which applies
# `service_state=stopped` to each module in reverse startup order
# (odysseus-setup -> agent-setup -> sut-setup -> model-setup) so dependents are
# torn down before what they rely on. All state is kept on disk (podman images,
# GGUF weights, Postgres data dir, workspace volumes), so `./start-services.sh`
# brings everything back later.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

usage() {
  cat <<'EOF'
stop-services.sh — stop every self-hosted service.

Usage:
  ./stop-services.sh [module ...]

By default every module is stopped in reverse startup order
(odysseus-setup -> agent-setup -> sut-setup -> model-setup). Pass module names
to stop only those, in the order given. Nothing is deleted: images, model
weights and data directories stay on disk.

Run `./start-services.sh` again to bring everything back; or use
`./start-services.sh restart` for a one-liner stop-then-start.
EOF
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

exec "$SCRIPT_DIR/start-services.sh" stop "$@"
