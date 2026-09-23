{
  description = "Flake to setup the basis for agents";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = {
    self,
    nixpkgs,
  }: let
    systems = [
      "aarch64-darwin"
      "aarch64-linux"
      "x86_64-linux"
    ];

    # `nix develop` for the needed tools
    devShell = pkgs:
      pkgs.mkShell {
        packages = with pkgs; [
          just
          python3
          python3Packages.pip
          dhall # .dhall/ sources
          dhall-json # dhall-to-json / json-to-dhall (used by `make`)
          jq
          mosquitto
          pipenv
          opentofu
        ];
      };
  in {
    devShells = nixpkgs.lib.genAttrs systems (system: {
      default = devShell nixpkgs.legacyPackages.${system};
    });
  };
}
