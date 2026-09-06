# Two build jobs live here: the Dhall -> JSON crew configs (the workers that
# run on the Pis) and the NixOS SD-card images for those same Pis.
#
#   make                       compile Dhall crews      -> build/<role>/
#   make images                build all four aarch64 SD images (U-Boot + systemd-boot)
#   make pi1-e2e-sd-image      build one image
#   make check                 nix flake check (lint the NixOS flake, no build)
#   make clean                 remove build/ + nix/result

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

# --- NixOS SD-card images ---------------------------------------------------

FLAKE  := nix
HOSTS  := pi1-e2e pi2-pentester pi3-manager broker

.PHONY: check images daemonize $(HOSTS)

check:
	nix flake check $(FLAKE)

images: $(addsuffix -sd-image,$(HOSTS))

%-sd-image:
	nix build -L ./$(FLAKE)#$@
	@echo "image ready: $(FLAKE)/result/sd-image/"

daemonize:
	@nix daemon >/dev/null 2>&1 & echo "nix daemon started"

clean: clean-crews
	rm -rf $(FLAKE)/result

.PHONY: clean-crews
clean-crews:
	rm -rf build