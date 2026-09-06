# Joins the host to the crew's WPA2 wireless network.
#
# Stack (systemd-networkd, no NetworkManager):
#   - systemd.network.enable (set in hosts/common.nix) drives IP config; the
#     explicit .network files there do DHCP (wired preferred via metric).
#   - wpa_supplicant (networking.wireless) handles the 802.11 auth.
#
# Secrets are read at *build* time by the flake (see flake.nix): the WiFi
# SSID and the derived 64-hex WPA2 PSK live in the hidden, gitignored file
# nix/network-secrets.nix (copy nix/network-secrets.example.nix to create it;
# the example shows how to derive the PSK with wpa_passphrase /
# PBKDF2-HMAC-SHA1 over ssid + passphrase). Only the hash ever reaches the
# Nix store - never the clear passphrase. Building an image or evaluating the
# flake reads that file and injects the values here.
#
# Ethernet-only machines just leave psk empty in network-secrets.nix:
# ssid/psk stay null and wifi is simply not configured.
{ config, lib, pkgs, ... }:
let
  cfg = config.crewNetwork;
  inherit (lib) mkEnableOption mkIf mkOption types;
in
{
  options.crewNetwork = {
    enable = mkEnableOption "crew WPA2 wireless network (wpa_supplicant + systemd-networkd)";

    ssid = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        The WPA2 SSID, injected from the hidden nix/network-secrets.nix at
        build time (see nix/network-secrets.example.nix).
      '';
    };

    psk = mkOption {
      type = types.nullOr (types.strMatching "[[:xdigit:]]{64}");
      default = null;
      description = ''
        The derived 64-hex WPA2 pre-shared key (PBKDF2-HMAC-SHA1 output of
        the passphrase + ssid). Only this hash - never the clear passphrase -
        enters the Nix store. Injected from nix/network-secrets.nix.
      '';
    };

    hidden = mkOption {
      type = types.bool;
      default = false;
      description = "Set to true if the SSID is not broadcast.";
    };

    interface = mkOption {
      type = types.str;
      default = "wlan0";
      description = "Wireless interface used by wpa_supplicant.";
    };
  };

  config = mkIf (cfg.enable && cfg.ssid != null && cfg.psk != null) {
    networking.wireless = {
      enable = true;
      interfaces = [ cfg.interface ];
      networks.${cfg.ssid} = {
        pskRaw = cfg.psk;
        hidden = cfg.hidden;
      };
    };
  };
}