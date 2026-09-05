# Shared settings for all the crew hosts (3 worker Pis + the broker).
#
# Hardy defaults: firewall on, SSH with keys only, flakes enabled, sane
# timezone. Adjust users/keys for your own hardware.
{ config, lib, pkgs, ... }:
{
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  networking.networkmanager.enable = true;

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
    extraGroups = [ "wheel" "networkmanager" ];
    openssh.authorizedKeys.keys = [
      # "ssh-ed25519 AAAA... your@key"
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