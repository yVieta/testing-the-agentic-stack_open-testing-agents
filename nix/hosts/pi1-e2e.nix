# PI 1 - the e2e test engineer (playwright).
{ config, lib, pkgs, ... }:
{
  imports = [ ./common.nix ../modules/crew-worker.nix ];

  networking.hostName = "pi1-e2e";

  crewWorker.enable = true;
  crewWorker.role = "pi1-e2e";
  # IPs below are examples - match your own LAN.
  crewWorker.brokerHost = "10.0.0.10";
  crewWorker.targetUrl = "http://10.0.0.20";

  # Pin the pip playwright to the same version nixpkgs ships its browsers
  # for, so python playwright finds the browser binaries on first run.
  crewWorker.crewaiDeps = [
    "crewai[tools]>=1.15.20,<2.0.0"
    "paho-mqtt>=2.0,<3.0"
    "playwright==${pkgs.playwright.version}"
  ];

  # Browsers + drivers the e2e agent uses to drive the target UI.
  environment.systemPackages = with pkgs; [
    chromium            # only needed for playwright extras
    playwright          # official browser-automation CLI (test runner)
    playwright-driver   # driver binaries; .browsers provides the webkit/chromium builds
    nodejs              # runtime for playwright tests
    jq                  # parse JSON test output / MQTT payloads
    curl                # quick HTTP smoke checks before launching a browser
  ];

  # Let pip & the CLI find the nixpkgs-packaged browsers. NixOS browsers are
  # self-contained; skip playwright's own "validate host requirements" pass
  # which relies on Ubuntu-style system libs that NixOS does not have.
  crewWorker.extraEnvironment = {
    PLAYWRIGHT_BROWSERS_PATH = "${pkgs.playwright-driver.browsers}";
    PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS = "true";
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1";
  };

  system.stateVersion = "26.11";
}