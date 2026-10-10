# Compile the Dhall crew + agent definitions to JSON for the workers.
#
# `just` itself comes from `nix develop` (see flake.nix):
#   nix develop -c just            # compile crews        -> build/<role>/
#   nix develop -c just agents     # agent instructions   -> build/agents/
#   nix develop -c just manifest   # regenerate build/.manifest.json
#   nix develop -c just clean      # remove build/
#   nix develop                    # interactive shell, then `just` directly

set working-directory := "."

dhall_dir := ".dhall"
build_dir := "build"

# Compile every crew + its agent instructions into build/<role>/.
default:
    @just crews

# JSON view of .dhall/Manifest.dhall that the crews recipe iterates over.
manifest:
    @mkdir -p "{{ build_dir }}"
    @dhall-to-json --file "{{ dhall_dir }}/Manifest.dhall" \
        --output "{{ build_dir }}/.manifest.json"

# Agent instructions: the agent JSONs (role/goal/backstory) in build/agents/.
agents: manifest
    @mkdir -p "{{ build_dir }}/agents"
    @for agent in $(jq -r '.[].agent' "{{ build_dir }}/.manifest.json" | sort -u); do \
        dhall-to-json --omit-empty --file "{{ dhall_dir }}/$agent.dhall" \
            --output "{{ build_dir }}/agents/$agent.json"; \
        echo "  {{ build_dir }}/agents/$agent.json"; \
    done

# Compile crew.json, agents/<agent>.json and pyproject.toml per manifest role.
crews: manifest agents
    @jq -r '.[] | [.role, .agent, .crew] | @tsv' "{{ build_dir }}/.manifest.json" \
    | while read -r role agent crew; do \
      dir="{{ build_dir }}/$role"; \
      echo "  $dir/"; \
      mkdir -p "$dir/agents"; \
      dhall-to-json --omit-empty --file "{{ dhall_dir }}/$crew.dhall" \
          --output "$dir/crew.json"; \
      cp "{{ build_dir }}/agents/$agent.json" "$dir/agents/$agent.json"; \
      printf '%s\n' "$(echo "./{{ dhall_dir }}/Pyproject.dhall \"$role\"" | dhall-to-json --omit-empty | jq -r .)" > "$dir/pyproject.toml"; \
    done
    @printf 'Compiled Dhall -> JSON for %d local agent crews under %s/\n' \
        "$(jq 'length' "{{ build_dir }}/.manifest.json")" "{{ build_dir }}"

# chicken egg (nix dev shell) 
shell:
    nix develop

# Interactive test-manager agent CLI: talks to the local model with the test
# manager persona (see worker/tm_cli.py). Ctrl+D to exit.
tm:
    nix develop -c python3 worker/tm_cli.py

# Compile the crews + agent persona, then start every service (model, SUT,
# MCP bus, agents, Odysseus). Run as `nix develop -c just start` so
# dhall-to-json is on PATH for the `crews` step.
#
# `tofu apply` restarts only modules whose triggers changed (rendered units and
# content hashes of the worker scripts/bus server), so on a code round-trip the
# model and SUT are skipped automatically and this converges in minutes.
start: crews
    ./start-services.sh

# Same as `start` but applies the modules in dependency waves, concurrently:
# wave 1 = model+sut+bus, wave 2 = agents+odysseus. Full clean boot in ~18 min
# instead of ~22-25 sequential.
start-fast: crews
    ./start-services.sh --parallel start

# Stop every service in reverse order (Odysseus -> agents -> SUT -> model).
stop:
    ./stop-services.sh

# Stop then start everything — the full clean cycle (~22-25 min; the model
# boots two llama.cpp servers, so most of the time is unavoidable).
restart:
    ./start-services.sh restart

# Code round-trip (default): converge only the code modules (MCP bus, agents,
# Odysseus) and keep the model + SUT running. ~9 min on this host.
redeploy:
    ./start-services.sh start mcp-setup agent-setup odysseus-setup

# Code round-trip, parallel: bus first, agents + Odysseus concurrently after.
# ~5 min on this host.
redeploy-fast:
    ./start-services.sh --parallel start mcp-setup agent-setup odysseus-setup

# Agent run cadence in seconds (`just pace 900` = quiet production, `just pace
# 60` = the team responds to a freshly assigned case within a minute). Applies
# agent-setup only; `start`/`redeploy` fall back to the 900s default again.
pace seconds:
    tofu -chdir=agent-setup apply -var service_state=running \
        -var run_interval={{ seconds }}

# Show the tofu outputs (service URLs / state) for each module.
status:
    ./start-services.sh status

# Remove build/.
clean:
    @rm -rf "{{ build_dir }}"
