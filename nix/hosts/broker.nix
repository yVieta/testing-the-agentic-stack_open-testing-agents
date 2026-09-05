# The MQTT broker host (a 4th Pi, or any low-power LAN machine).
#
# Exposes:
#   - 8883  TLS   (used by the three workers)
#   - 1883  plain (debugging only, drop in production)
{ config, lib, ... }:
{
  imports = [ ./common.nix ../modules/mqtt-broker.nix ];

  networking.hostName = "pi4-broker";

  mqttBroker.enable = true;

  networking.firewall.allowPing = true;
  # using flake 
  # system.stateVersion = "24.11";
}
