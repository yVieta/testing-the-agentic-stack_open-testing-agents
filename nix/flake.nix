# dhallcrew - 3 MQTT-coordinated crewAI agents on 3 Raspberry Pis running NixOS
#
# The flake declares four NixOS machines: three worker Pis (one crewAI agent
# each) plus an MQTT broker. The crew & agent JSON configs are *built from
# the Dhall sources* (see modules/crew-worker.nix) by this flake - Nix and
# Dhall together are the source of truth.
#
#   nixos-rebuild switch --flake .#pi1-e2e        (on each Raspberry Pi)
#   nixos-rebuild switch --flake .#broker         (on the broker host)
{
  description = "dhallcrew: MQTT-coordinated testing crew on 3 Raspberry Pis (NixOS)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable"; # let it rolling 
    # Optional: add nixos-hardware for tuned Raspberry Pi defaults:
    #   nixos-hardware.url = "github:NixOS/nixos-hardware";
  };

  outputs = { self, nixpkgs }: {
    nixosConfigurations =
      let
        system = "aarch64-linux";
        mkHost = name: nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [ ./hosts/${name}.nix ];
        };
      in
      {
        pi1-e2e = mkHost "pi1-e2e";
        pi2-pentester = mkHost "pi2-pentester";
        pi3-manager = mkHost "pi3-manager";
        broker = mkHost "broker";
      };
  };
}
