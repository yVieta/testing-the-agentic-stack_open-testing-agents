#   nixosConfigurations:  deployable system configuration
#     nixos-rebuild switch --flake .#pi1-e2e       (on each Raspberry Pi)
#     nixos-rebuild switch --flake .#broker        (on the broker host)
#
#   packages:             flashable / bootable image for first install
#     aarch64-linux:      SD card image  (*-sd-image)    -- make images
#     x86_64-linux:       installer ISO  (*-iso)         -- make iso
{
  description = "dhallcrew: MQTT-coordinated testing crew on 3 Raspberry Pis + amd64 broker (NixOS)";

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
      url = "./network-secrets.example.nix";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      network-secrets,
    }:
    let
      lib = nixpkgs.lib;

      # The crew's two architectures: Raspberry Pis are aarch64, the broker is
      # x86_64. Same modules, different boot media.
      aarch64 = "aarch64-linux";
      x86_64 = "x86_64-linux";

      # Every host declares its architecture.  The image/installer kind is
      # derived from it: aarch64 -> flashable SD card image, x86_64 (amd64)
      # -> bootable installer ISO.
      hosts = [
        {
          name = "pi1-e2e";
          system = aarch64;
        }
        {
          name = "pi2-pentester";
          system = aarch64;
        }
        {
          name = "pi3-manager";
          system = aarch64;
        }
        {
          name = "broker";
          system = x86_64;
        }
      ];

      # The generic image builders: SD card (aarch64) and ISO (x86_64).
      sdImageModule = "${nixpkgs}/nixos/modules/installer/sd-card/sd-image.nix";
      isoImageModule = "${nixpkgs}/nixos/modules/installer/cd-dvd/iso-image.nix";
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

      mkHost =
        host:
        nixpkgs.lib.nixosSystem {
          inherit (host) system;
          modules = baseModules ++ [
            ./hosts/${host.name}.nix
            wifiSecretModule
          ];
        };

      # Same host module, but bootstrapped into the right image builder:
      #   aarch64 -> sd-image (modules/sd-image-systemd-boot.nix + sd-image.nix)
      #   x86_64  -> ISO     (installer/cd-dvd/iso-image.nix)
      mkImage =
        host:
        nixpkgs.lib.nixosSystem {
          inherit (host) system;
          modules =
            baseModules
            ++ [
              ./hosts/${host.name}.nix
              wifiSecretModule
              baseModule
            ]
            ++ (
              if host.system == x86_64 then
                [ isoImageModule ]
              else
                [
                  ./modules/sd-image-systemd-boot.nix
                  sdImageModule
                ]
            );
        };

      # Return { name, value } for the correct image attribute.
      imageFor =
        host:
        if host.system == x86_64 then
          {
            name = "${host.name}-iso";
            value = (mkImage host).config.system.build.isoImage;
          }
        else
          {
            name = "${host.name}-sd-image";
            value = (mkImage host).config.system.build.sdImage;
          };

      # Aggregate per-system: packages.aarch64-linux.{pi1-e2e-sd-image ...},
      # packages.x86_64-linux.broker-iso.
      packages = lib.foldl' (
        acc: host:
        let
          img = imageFor host;
        in
        acc
        // {
          ${host.system} = (acc.${host.system} or { }) // {
            ${img.name} = img.value;
          };
        }
      ) { } hosts;

      # for running: `nix develop` too use the tools from here...
      devShellFor =
        system: pkgs:
        pkgs.mkShell {
          packages = with pkgs; [
            python3
            dhall
            pipenv
          ];
        };
      pkgsFor = system: nixpkgs.legacyPackages.${system};
      systems = [
        aarch64
        x86_64
      ];
    in
    {
      nixosConfigurations = lib.listToAttrs (map (h: lib.nameValuePair h.name (mkHost h)) hosts);

      packages = packages;

      devShells = lib.genAttrs systems (system: {
        default = devShellFor system (pkgsFor system);
      });
    };
}
