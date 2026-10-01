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
          agda
          just
          go-task
          python3
          python3Packages.pip
          dhall # .dhall/ sources
          dhall-json # dhall-to-json / json-to-dhall (used by `just`)
          jq
          mosquitto
          pipenv
          opentofu
          elan # the end of agda for this case?
        ];
      };
  in {
    devShells = nixpkgs.lib.genAttrs systems (system: {
      default = devShell nixpkgs.legacyPackages.${system};
    });
  };
}
