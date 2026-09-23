# Two build jobs live here: the Dhall -> JSON crew configs (the workers that
# run on the Raspberry Pis) and the ISO for the optional NixOS broker host.
#
# The Pis run Raspberry Pi OS (Raspbian); every tool below is provided by
# `nix develop` (see flake.nix) - no NixOS needed.
#
#   make               compile Dhall crews      -> build/<role>/
#   make check         nix flake check (lint the NixOS flake, no build)
#   make broker-iso    build the optional broker installer ISO
#   make clean         remove build/ + result/

# --- Dhall -> JSON crews ----------------------------------------------------
#
# The build plan lives in Dhall, like the configs themselves:
#   .dhall/Manifest.dhall   which crews exist, and their agent/crew sources
#   .dhall/Pyproject.dhall  renders each crew's pyproject.toml
# Produces build/pi1-e2e/, build/pi2-pentester/, build/pi3-manager/.

DHALL    = .dhall
MANIFEST = build/.manifest.json

.PHONY: all clean
all: crews

build:
	mkdir -p build

# JSON view of .dhall/Manifest.dhall that the crews recipe iterates over.
$(MANIFEST): $(DHALL)/Manifest.dhall | build
	dhall-to-json --file $< --output $@

# Crunch every role in the manifest: crew.json, agents/<agent>.json and the
# per-role pyproject.toml. Always re-runs, like compile.sh did.
crews: $(MANIFEST)
	@jq -r '.[] | [.role, .agent, .crew] | @tsv' "$<" | while read -r role agent crew; do \
	  dir="build/$$role"; \
	  echo "  $$dir/"; \
	  mkdir -p "$$dir/agents"; \
	  dhall-to-json --omit-empty --file "$(DHALL)/$$crew.dhall" --output "$$dir/crew.json"; \
	  dhall-to-json --omit-empty --file "$(DHALL)/$$agent.dhall" --output "$$dir/agents/$$agent.json"; \
	  printf '%s\n' "$$(echo "./$(DHALL)/Pyproject.dhall \"$$role\"" | dhall-to-json --omit-empty | jq -r .)" > "$$dir/pyproject.toml"; \
	done
	@printf 'Compiled Dhall -> JSON for %d Raspberry Pi crews under build/\n' "$$(jq 'length' "$<")"

# --- Optional NixOS broker ISO ---------------------------------------------

.PHONY: check
check:
	nix flake check

broker-iso:
	nix build -L .#broker-iso
	@echo "iso ready: ./result/iso/"

daemonize:
	@nix daemon >/dev/null 2>&1 & echo "nix daemon started"

clean: clean-crews
	rm -rf result

.PHONY: clean-crews
clean-crews:
	rm -rf build