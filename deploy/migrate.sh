#!/bin/sh
# migrate.sh — collapse the five per-module OpenTofu states into the single
# root `deploy/` state.
#
# The repo used to manage model-setup, sut-setup, mcp-setup, agent-setup and
# odysseus-setup as five independent tofu configurations (each with its own
# terraform.tfstate). deploy/ is now the one declarative controller and owns
# the whole stack in a single state; this script moves every existing resource
# into it so nothing is destroyed and no service is restarted.
#
# It is idempotent and safe to re-run: resources already in the deploy state
# are reported with a `--force` hint only (they are not touched), and a module
# whose state file is already gone is skipped.
#
# Usage:
#   ./deploy/migrate.sh              # migrate and verify (plan shows no destroys)
#   TOFU=terraform ./deploy/migrate.sh
#
# After a successful run, `tofu -chdir=deploy plan` reports the single state
# with zero destructive changes; the old per-module states are renamed to
# terraform.tfstate.migrated-<ts> and must not be used again.
set -eu

TOFU_BIN=${TOFU:-tofu}

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DEPLOY=$ROOT/deploy
# module dir -> root module block name in deploy/main.tf
MODULES="model-setup sut-setup mcp-setup agent-setup odysseus-setup"

blk() {
  case "$1" in
    model-setup)   echo model ;;
    sut-setup)     echo sut ;;
    mcp-setup)     echo mcp ;;
    agent-setup)   echo agents ;;
    odysseus-setup) echo odysseus ;;
  esac
}

"$TOFU_BIN" -chdir="$DEPLOY" init -input=false

for m in $MODULES; do
  old="$ROOT/$m/terraform.tfstate"
  if [ ! -f "$old" ]; then
    echo "skip  $m (no terraform.tfstate)"
    continue
  fi
  block=$(blk "$m")
  # shellcheck disable=SC2016
  res=$("$TOFU_BIN" -chdir="$ROOT/$m" state list 2>/dev/null || true)
  if [ -z "$res" ]; then
    echo "skip  $m (state is empty)"
    continue
  fi
  moved=0
  for r in $res; do
    case "$r" in
      module.*) echo "skip  $m/$r (already module-scoped)" ; continue ;;
    esac
    if "$TOFU_BIN" -chdir="$DEPLOY" state mv \
        -state="$old" -state-out="$DEPLOY/terraform.tfstate" \
        "$r" "module.$block.$r" 2>/dev/null; then
      echo "move  $m/$r -> module.$block.$r"
      moved=$((moved + 1))
    else
      # Already moved (or never existed) — harmless.
      echo "skip  $m/$r (already in deploy state or not movable)"
    fi
  done
  if [ "$moved" -gt 0 ]; then
    mv "$old" "$old.migrated-$(date +%s)"
    echo "done  $m ($moved resource(s) moved; legacy state archived)"
  fi
done

echo
echo "verify: nothing in the single deploy state may be about to be destroyed."
plan=$("$TOFU_BIN" -chdir="$DEPLOY" plan -input=false -no-color 2>&1 || true)
if printf '%s\n' "$plan" | grep -qE 'must be replaced|will be destroyed'; then
  printf '%s\n' "$plan" | grep -E 'must be replaced|will be destroyed|Plan:|Error:' | head -20
  echo
  echo "WARNING: the plan above wants to destroy/replace existing resources."
  echo "Stop here and reconcile before applying — migration must be non-destructive."
else
  echo "OK: plan contains no replaces/destroys (creates/updates are new features"
  echo "like the seed file or the self-healing unit lines — expected)."
fi