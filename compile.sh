#!/usr/bin/env bash
# Compile the Dhall configuration into per-PI JSON crews for crewAI.
#
# The Dhall sources in .dhall/ are the source of truth; the compiled
# JSON under build/ is what crewAI reads on each Raspberry Pi.
#
# Layout produced:
#   build/pi1-e2e/       crew.json + agents/e2e_test_agent.json
#   build/pi2-pentester/ crew.json + agents/pentester_agent.json
#   build/pi3-manager/   crew.json + agents/test_manager_agent.json
#
# Each build/piN-* directory is self-contained so it can be rsync'd to a
# Raspberry Pi and run with `crewai run` for quick experiments. For the
# real deployment, NixOS rebuilds these same configs from the Dhall
# sources (see nix/modules/crew-worker.nix).
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# (role_dir, agent_source, crew_source)
PIS=(
  "pi1-e2e:e2e_test_agent.dhall:crews/pi1_e2e.dhall"
  "pi2-pentester:pentester_agent.dhall:crews/pi2_pentester.dhall"
  "pi3-manager:test_manager_agent.dhall:crews/pi3_manager.dhall"
)

cat_crew_pyproject() {
  # $1 = crew directory name (e.g. pi1-e2e)
  cat > "$DIR/build/$1/pyproject.toml" <<EOF
[project]
name = "$1"
version = "0.1.0"
description = "crewAI worker for $1 (one agent per Raspberry Pi)"
requires-python = ">=3.10,<3.14"

[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[tool.crewai]
type = "crew"
definition = "crew.json"
EOF
}

for spec in "${PIS[@]}"; do
  role_dir="${spec%%:*}"
  rest="${spec#*:}"
  agent_src="${rest%%:*}"
  crew_src="${rest#*:}"

  out_dir="$DIR/build/$role_dir"

  mkdir -p "$out_dir/agents"

  dhall-to-json --omit-empty --file "$DIR/.dhall/$agent_src" \
    --output "$out_dir/agents/$(basename "$agent_src" .dhall).json"

  dhall-to-json --omit-empty --file "$DIR/.dhall/$crew_src" \
    --output "$out_dir/crew.json"

  cat_crew_pyproject "$role_dir"

  cp -f "$DIR/nix/secrets.env.example"   "$out_dir/.env.example"

  echo "  build/$role_dir/"
done

echo "Compiled Dhall -> JSON for 3 Raspberry Pi crews under build/"