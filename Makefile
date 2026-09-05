# Makefile -- compile the Dhall crew configs into per-PI JSON for crewAI.
#
# The build plan lives in Dhall, like the configs themselves:
#   .dhall/Manifest.dhall   which crews exist, and their agent/crew sources
#   .dhall/Pyproject.dhall  renders each crew's pyproject.toml
# `make` (or `make all`) drives that plan and replaces the old compile.sh.
#
# Layout produced:
#   build/pi1-e2e/       crew.json + agents/e2e_test_agent.json
#   build/pi2-pentester/ crew.json + agents/pentester_agent.json
#   build/pi3-manager/   crew.json + agents/test_manager_agent.json
#
# Each build/piN-* directory is self-contained so it can be rsync'd to a
# Raspberry Pi and run with `crewai run` for quick experiments. For the
# real deployment, NixOS rebuilds the same Dhall sources (see
# nix/modules/crew-worker.nix).

DHALL    = .dhall
MANIFEST = build/.manifest.json

.PHONY: all clean
all: crews

build:
	mkdir -p build

# JSON view of .dhall/Manifest.dhall that the crews recipe iterates over.
$(MANIFEST): $(DHALL)/Manifest.dhall | build
	dhall-to-json --file $< --output $@

# Crunch every role in the manifest: crew.json, agents/<agent>.json,
# pyproject.toml and the .env.example template. Always re-runs, like
# compile.sh did.
crews: $(MANIFEST)
	@jq -r '.[] | [.role, .agent, .crew] | @tsv' "$<" | while read -r role agent crew; do \
	  dir="build/$$role"; \
	  echo "  $$dir/"; \
	  mkdir -p "$$dir/agents"; \
	  dhall-to-json --omit-empty --file "$(DHALL)/$$crew.dhall" --output "$$dir/crew.json"; \
	  dhall-to-json --omit-empty --file "$(DHALL)/$$agent.dhall" --output "$$dir/agents/$$agent.json"; \
	  printf '%s\n' "$$(echo "./$(DHALL)/Pyproject.dhall \"$$role\"" | dhall-to-json --omit-empty | jq -r .)" > "$$dir/pyproject.toml"; \
	  cp -f nix/secrets.env.example "$$dir/.env.example"; \
	done
	@printf 'Compiled Dhall -> JSON for %d Raspberry Pi crews under build/\n' "$$(jq 'length' "$<")"

clean:
	rm -rf build