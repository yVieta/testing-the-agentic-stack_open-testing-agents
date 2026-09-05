# PI 3 - the test manager (reviews results, writes the final report).
{ config, lib, ... }:
{
  imports = [ ./common.nix ../modules/crew-worker.nix ];

  networking.hostName = "pi3-manager";

  crewWorker.enable = true;
  crewWorker.role = "pi3-manager";
  crewWorker.brokerHost = "10.0.0.10";
  crewWorker.targetUrl = "http://10.0.0.20";

  system.stateVersion = "24.11";
}