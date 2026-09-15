{ config, lib, pkgs, ... }:
{
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  boot.loader.grub = {
    enable = lib.mkDefault true;
    device = lib.mkDefault "/dev/sda";
  };

  fileSystems."/" = lib.mkDefault {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

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

  system.stateVersion = "26.11";
}
