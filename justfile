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
start: crews
    ./start-services.sh

# Stop every service in reverse order (Odysseus -> agents -> SUT -> model).
stop:
    ./stop-services.sh

# Stop then start everything.
restart:
    ./start-services.sh restart

# Show the tofu outputs (service URLs / state) for each module.
status:
    ./start-services.sh status

# Remove build/.
clean:
    @rm -rf "{{ build_dir }}"
