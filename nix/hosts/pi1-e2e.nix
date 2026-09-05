# PI 1 - the e2e test engineer (playwright).
{ config, lib, ... }:
{
  imports = [ ./common.nix ../modules/crew-worker.nix ];

  networking.hostName = "pi1-e2e";

  crewWorker.enable = true;
  crewWorker.role = "pi1-e2e";
  # IPs below are examples - match your own LAN.
  crewWorker.brokerHost = "10.0.0.10";
  crewWorker.targetUrl = "http://10.0.0.20";

  system.stateVersion = "24.11";
}