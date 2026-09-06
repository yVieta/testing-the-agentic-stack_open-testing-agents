# dhallcrew - 3 MQTT-coordinated crewAI agents on 3 Raspberry Pis running NixOS
#
# The flake declares four NixOS machines: three worker Pis (one crewAI agent
# each) plus an MQTT broker. The crew & agent JSON configs are *built from
# the Dhall sources* (see modules/crew-worker.nix) by this flake - Nix and
# Dhall together are the source of truth.
#
#   nixos-rebuild switch --flake .#pi1-e2e        (on each Raspberry Pi)
#   nixos-rebuild switch --flake .#broker         (on the broker host)
#   make images                                   (build the SD card images)
{
  description = "dhallcrew: MQTT-coordinated testing crew on 3 Raspberry Pis (NixOS)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable"; # let it rolling
    # WiFi SSID + derived WPA2 PSK (64 hex) - see nix/network-secrets.example.nix.
    # The converted file nix/network-secrets.nix is gitignored, so it cannot be
    # part of a `git+file:` or relative `path:./...` flake source (those resolve
    # against the git snapshot); an ABSOLUTE path input is required. Keep this
    # pointing at the repo's network-secrets.nix. The image build reads the
    # secret from here; only the derived hash ever reaches the nix store, never
    # the plain passphrase.
    network-secrets = {
      url = "path:/home/vieta/Projects/agents/crews/dhallcrew/nix/network-secrets.nix";
      flake = false;
    };
    # Optional: add nixos-hardware for tuned Raspberry Pi defaults:
    #   nixos-hardware.url = "github:NixOS/nixos-hardware";
  };

  outputs = { self, nixpkgs, network-secrets }: let
    lib = nixpkgs.lib;
    system = "aarch64-linux";
    # Every host can be built two ways: as a deployable system configuration
    # (nixosConfigurations) or as a raw SD card image for first flashing
    # (packages.*-sd-image).
    hosts = [ "pi1-e2e" "pi2-pentester" "pi3-manager" "broker" ];
    # The generic image builder; our modules/sd-image-systemd-boot.nix turns
    # its FIRMWARE partition into a systemd-boot ESP (U-Boot chainloads it).
    sdImageModule = "${nixpkgs}/nixos/modules/installer/sd-card/sd-image.nix";
    baseModule = "${nixpkgs}/nixos/modules/profiles/base.nix";

    # The WiFi values, read from the hidden file at build time. null when the
    # import yields no psk/ssid (ethernet-only setup) - wifi is simply off.
    secrets = import "${network-secrets}";

    # Modules shared by every host / image.
    baseModules = [ ./modules/network.nix ];
    # Injects the build-time secret values from nix/network-secrets.nix.
    wifiSecretModule = {
      crewNetwork.enable = true;
      crewNetwork.ssid = secrets.ssid or null;
      crewNetwork.psk = secrets.psk or null;
    };

    mkHost = name: nixpkgs.lib.nixosSystem {
      inherit system;
      modules = baseModules ++ [ ./hosts/${name}.nix wifiSecretModule ];
    };

    # Same host module, but bootstrapped into the sd-image builder so
    # `config.system.build.sdImage` produces a flashable `.img.zst`.
    mkImage = name: nixpkgs.lib.nixosSystem {
      inherit system;
      modules = baseModules ++ [ ./hosts/${name}.nix wifiSecretModule baseModule ./modules/sd-image-systemd-boot.nix sdImageModule ];
    };
  in
    {
      nixosConfigurations =
        lib.listToAttrs (map (n: lib.nameValuePair n (mkHost n)) hosts);

      packages.${system} =
        lib.listToAttrs (map (n: lib.nameValuePair "${n}-sd-image" (mkImage n).config.system.build.sdImage) hosts);
    };
}