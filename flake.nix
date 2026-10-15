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
      "aarch64-linux"
      "x86_64-linux"
    ];

    # `nix develop` for the needed tools
    devShell = pkgs:
      pkgs.mkShell {
        packages = with pkgs; [
          agda
          elan
          lean4
          just
          python3
          python3Packages.pip
          python3Packages.psycopg
          dhall # .dhall/ sources
          dhall-json # dhall-to-json / json-to-dhall (used by `just`)
          jq
          pipenv
          opentofu

          # HTTP client used by a couple of provisioner health probes.
          curl
        ];

        # Container runtime: prefer the host's podman/podman-compose when
        # present (its systemd quadlet generator and container store are what
        # the host is already set up for), and fall back to the Nix-provided
        # runtime on hosts that ship none — so `nix develop` is enough to run
        # the deploy on any systemd distro.
        shellHook = ''
          if command -v podman >/dev/null 2>&1; then
            echo "aigents: host podman — $(podman --version 2>/dev/null)"
          else
            export PATH=${pkgs.podman}/bin:$PATH
            echo "aigents: no host podman — using Nix-provided podman"
          fi
          if ! command -v podman-compose >/dev/null 2>&1; then
            export PATH=${pkgs.podman-compose}/bin:$PATH
            echo "aigents: no host podman-compose — using Nix-provided podman-compose"
          fi
        '';
      };
  in {
    devShells = nixpkgs.lib.genAttrs systems (system: {
      default = devShell nixpkgs.legacyPackages.${system};
    });
  };
}
