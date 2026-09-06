# Shared settings for all the crew hosts (3 worker Pis + the broker).
#
# Hardy defaults: firewall on, SSH with keys only, flakes enabled, sane
# timezone. Adjust users/keys for your own hardware.
{ config, lib, pkgs, ... }:
{
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Boot chain on the Raspberry Pis: the video-core firmware -> U-Boot ->
  # systemd-boot, which reads its ESP from the mounted FIRMWARE partition and
  # loads kernel + initrd + device tree from there. The SD image builder
  # (modules/sd-image-systemd-boot.nix) pre-populates that same ESP, and once
  # `nixos-rebuild switch` runs on a machine, installBootLoader manages the
  # ESP (generations) exactly like on any other systemd-boot NixOS.
  # mkDefault: the image builder and per-host configs override these freely.
  boot.loader.grub.enable = lib.mkDefault false;
  boot.loader.generic-extlinux-compatible.enable = lib.mkDefault false;
  boot.loader.systemd-boot.enable = lib.mkDefault true;
  # The RPi's U-Boot session has no persistent EFI NVRAM - do not touch it.
  boot.loader.efi.canTouchEfiVariables = lib.mkDefault false;
  # The systemd-boot ESP is the FAT FIRMWARE partition (also the official
  # NixOS Pi image layout: FAT "FIRMWARE" + ext4 "NIXOS_SD").
  boot.loader.efi.efiSysMountPoint = lib.mkDefault "/boot/firmware";
  # Pass the device tree to the kernel via systemd-boot. bcm2711-rpi-4-b.dtb
  # is the Pi 4 / 400; override per host for other models.
  hardware.deviceTree.enable = lib.mkDefault true;
  hardware.deviceTree.name = lib.mkDefault "broadcom/bcm2711-rpi-4-b.dtb";

  fileSystems."/boot/firmware" = lib.mkDefault {
    device = "/dev/disk/by-label/FIRMWARE";
    fsType = "vfat";
    # Mounted at runtime: systemd-boot's generation-switch writes to it.
    options = [ "nofail" ];
  };
  fileSystems."/" = lib.mkDefault {
    device = "/dev/disk/by-label/NIXOS_SD";
    fsType = "ext4";
  };

  # systemd-networkd drives all interfaces (NetworkManager is gone; the
  # networking.useNetworkd convenience wrapper is deliberately not used - we
  # enable networkd via systemd.network.enable and manage the .network files
  # ourselves). DHCP via the explicit profiles below, wired preferred over
  # wifi by route metric.
  systemd.network.enable = true;
  networking.useDHCP = false;        # no nixos-generated generic DHCP / scripting networks
  networking.dhcpcd.enable = false;  # networkd is the DHCP client now
  systemd.network.networks."10-wired" = {
    matchConfig.Type = "ether";
    networkConfig.DHCP = "yes"; # IPv4 + IPv6 addressing, DNS + NTP from DHCP
    dhcpV4Config.RouteMetric = 100;
  };
  systemd.network.networks."11-wireless" = {
    matchConfig.WLANInterfaceType = "station";
    networkConfig.DHCP = "yes";
    dhcpV4Config.RouteMetric = 1025; # ethernet preferred over wifi
  };

  # WPA2 wireless: SSID + derived PSK are read from the hidden file
  # nix/network-secrets.nix at build time (see flake.nix + modules/network.nix,
  # copy nix/network-secrets.example.nix to create it). Only the 64-hex PSK
  # hash enters the Nix store. Ethernet-only hosts can set crewNetwork.enable
  # = false here, or leave psk empty in network-secrets.nix.
  crewNetwork.enable = true;

  # Best practice: key-only SSH, no password login.
  services.openssh.enable = true;
  services.openssh.settings = {
    PasswordAuthentication = false;
    KbdInteractiveAuthentication = false;
    PermitRootLogin = "no";
  };

  # Replace with your own admin user + keys.
  users.users.admin = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      # Well-formed but dummy key (private half discarded/unusable) so the
      # locked-out assertion passes. REPLACE with your real key before
      # deploying to hardware, otherwise you will be locked out of the machine.
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO2qAV9xQD1AvzPa34jpMX8zvaKVrWytSf1WrTIF3oS9 placeholder@dhallcrew"
    ];
  };

  users.mutableUsers = false;
  security.sudo.wheelNeedsPassword = false;

  environment.systemPackages = with pkgs; [
    mosquitto     # mosquitto_pub / mosquitto_sub for manual testing
    tmux
    htop
  ];

  time.timeZone = "UTC";
  # Deactivate annoying swap chatter on SD cards.
  zramSwap.enable = false;

  system.stateVersion = "26.11";
}