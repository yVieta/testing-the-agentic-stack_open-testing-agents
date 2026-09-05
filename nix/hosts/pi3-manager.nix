# PI 3 - the test manager (reviews results, writes the final report).
{ config, lib, pkgs, ... }:
{
  imports = [ ./common.nix ../modules/crew-worker.nix ];

  networking.hostName = "pi3-manager";

  crewWorker.enable = true;
  crewWorker.role = "pi3-manager";
  crewWorker.brokerHost = "10.0.0.10";
  crewWorker.targetUrl = "http://10.0.0.20";

  # Lightweight tools for tracking the crew's progress and producing the
  # final report. No heavy dashboards - just CLI utilities the manager agent
  # can drive and an operator can inspect over SSH.
  environment.systemPackages = with pkgs; [
    jq                  # parse crew/status/<role> JSON lifecycle messages
    mosquitto           # mosquitto_sub to watch status/final topics
    glow                # render the final markdown report in a terminal
    bat                 # pretty-print JSON/logs alongside glow
    taskwarrior         # track outstanding work/findings as structured tasks
    timewarrior         # time-tracking to see how long phases take per run
    gnuplot             # generate simple charts from per-run metrics
  ];

  # Useful shell aliases for the operator (root/admin) to inspect a run.
  # Requires the monitor password from nix/gen-credentials.sh in
  # /etc/dhallcrew/monitor.env (export MQTT_MONITOR_PASS first).
  environment.shellAliases = {
    crew-status = "mosquitto_sub -h ${config.crewWorker.brokerHost} -p 8883 --cafile /etc/dhallcrew/certs/ca.crt -u monitor -P $MQTT_MONITOR_PASS -t 'crew/status/#' -v";
    crew-final = "mosquitto_sub -h ${config.crewWorker.brokerHost} -p 8883 --cafile /etc/dhallcrew/certs/ca.crt -u monitor -P $MQTT_MONITOR_PASS -t 'crew/final' -v";
  };

  system.stateVersion = "26.11";
}