# The MQTT broker host 
#
# Exposes:
#   - 8883  TLS   (used by the three workers)
#   - 1883  plain (debugging only, drop in production)
{ config, lib, ... }:
{
  imports = [ ./arch-amd64.nix ../modules/mqtt-broker.nix ];

  networking.hostName = "broker";

  mqttBroker.enable = true;

  networking.firewall.allowPing = true;
  # even with flake it is needed to add version to avoid warnings
  system.stateVersion = "26.11";
}
