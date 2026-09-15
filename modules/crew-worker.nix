# NixOS module for one crewAI worker on a Raspberry Pi.
#
# Enables `crewWorker` and, when enabled, provides a systemd service that
# runs worker/worker.py for exactly one role (pi1-e2e | pi2-pentester |
# pi3-manager). The crew/agent JSON is compiled from the Dhall sources in
# ../.dhall at build time, so the NixOS configuration and the Dhall configs
# share a single source of truth.
#
# Why a venv bootstrap service? crewai's Python dependency tree (litellm &
# friends) is not curated in nixpkgs, so the worker runs from a venv in
# /opt/dhallcrew/venv. NixOS manages everything around it (service, configs,
# firewall, worker script); the venv is created once on first boot.

{ config, lib, pkgs, ... }:
let
  inherit (lib) mkIf mkOption types;

  cfg = config.crewWorker;

  # ---- compile all crews from the Dhall source of truth --------------------
  crewConfigs = pkgs.runCommand "dhallcrew-crew-configs"
    {
      nativeBuildInputs = [ pkgs.dhall-json ];
      src = ../../.dhall;
    }
    ''
      cp -r "$src" dhall
      chmod -R u+w dhall
      mkdir -p \
        "$out/pi1-e2e/agents" \
        "$out/pi2-pentester/agents" \
        "$out/pi3-manager/agents"
      dhall-to-json --omit-empty --file dhall/e2e_test_agent.dhall \
        --output "$out/pi1-e2e/agents/e2e_test_agent.json"
      dhall-to-json --omit-empty --file dhall/pentester_agent.dhall \
        --output "$out/pi2-pentester/agents/pentester_agent.json"
      dhall-to-json --omit-empty --file dhall/test_manager_agent.dhall \
        --output "$out/pi3-manager/agents/test_manager_agent.json"
      dhall-to-json --omit-empty --file dhall/crews/pi1_e2e.dhall \
        --output "$out/pi1-e2e/crew.json"
      dhall-to-json --omit-empty --file dhall/crews/pi2_pentester.dhall \
        --output "$out/pi2-pentester/crew.json"
      dhall-to-json --omit-empty --file dhall/crews/pi3_manager.dhall \
        --output "$out/pi3-manager/crew.json"
    '';

  workerPy = ../../worker/worker.py;

  # Runtime working directory; writable so previous_output.md / report.md and
  # the compiled crew.json can live there (StateDirectory below).
  stateDir = "/var/lib/dhallcrew/${cfg.role}";

  venvBootstrap = pkgs.writeShellScript "ensure-worker-venv" ''
    set -eu
    if [ ! -x "${cfg.venvPath}/bin/python" ]; then
      mkdir -p "$(dirname "${cfg.venvPath}")"
      ${pkgs.python3}/bin/python -m venv "${cfg.venvPath}"
      "${cfg.venvPath}/bin/pip" install --upgrade pip
      "${cfg.venvPath}/bin/pip" install ${builtins.concatStringsSep " " cfg.crewaiDeps}
    fi
  '';

  # Stage the compiled crew.json + agents into the writable working dir.
  stageConfig = pkgs.writeShellScript "stage-crew-config" ''
    set -eu
    mkdir -p "${stateDir}"
    cp -r "${cfg.crewConfigs}/${cfg.role}/." "${stateDir}/"
    chmod -R u+w "${stateDir}"
  '';
in
{
  options.crewWorker = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Run a crewAI MQTT worker on this host.";
    };
    role = mkOption {
      type = types.enum [ "pi1-e2e" "pi2-pentester" "pi3-manager" ];
      description = "Which crew role this host runs (maps to a compiled crew).";
    };
    crewaiDeps = mkOption {
      type = types.listOf types.str;
      default = [ "crewai[tools]>=1.15.20,<2.0.0" "paho-mqtt>=2.0,<3.0" ];
      description = "Python packages installed into the worker venv.";
    };
    venvPath = mkOption {
      type = types.str;
      default = "/opt/dhallcrew/venv";
      description = "Where the crewAI + paho-mqtt venv is created.";
    };
    envFile = mkOption {
      type = types.str;
      default = "/etc/dhallcrew/${cfg.role}.env";
      description = ''
        Secrets file (BROKER_USERNAME/BROKER_PASSWORD, ...) read by the
        worker. Create it manually under /etc/dhallcrew/<role>.env (see
        nix/secrets.env.example). Values here override the non-secret
        defaults set by this module.
      '';
    };
    brokerHost = mkOption {
      type = types.str;
      description = "MQTT broker host (IP or name on the LAN).";
    };
    extraEnvironment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = ''
        Extra environment variables for the worker service (e.g. per-role
        tooling paths like PLAYWRIGHT_BROWSERS_PATH on the e2e host).
      '';
    };
    brokerPort = mkOption {
      type = types.int;
      default = 8883;
      description = "MQTT broker port (8883 = TLS, 1883 = plaintext).";
    };
    targetUrl = mkOption {
      type = types.str;
      description = "The local web server under test (reachable from all Pis).";
    };
    crewConfigs = mkOption {
      type = types.path;
      default = crewConfigs;
      description = ''
        Derivations whose output contains one <role>/ directory per crew
        (crew.json + agents/). Defaults to a derivation that compiles the
        Dhall sources in ../.dhall with dhall-to-json. Override if your
        nixpkgs lacks pkgs.dhall-json or you want to use prebuilt outputs.
      '';
    };
    tlsRequireCert = mkOption {
      type = types.bool;
      default = true;
      description = "Verify the broker hostname/certificate (best practice).";
    };
    tlsCa = mkOption {
      type = types.str;
      default = "/etc/dhallcrew/certs/ca.crt";
      description = "CA bundle used to trust the broker's TLS certificate.";
    };
  };

  config = mkIf cfg.enable {
    # One-shot venv bootstrap; the worker waits for it.
    systemd.services.ensure-worker-venv = {
      description = "bootstrap crewAI worker venv";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = builtins.toString venvBootstrap;
      };
    };

    systemd.services."crew-worker-${cfg.role}" = {
      description = "crewAI MQTT worker for ${cfg.role}";
      after = [ "network-online.target" "ensure-worker-venv.service" ];
      wants = [ "network-online.target" "ensure-worker-venv.service" ];

      # Non-secret defaults (secrets come from cfg.envFile and win by order
      # of EnvironmentFile after Environment=).
      environment =
        {
          BROKER_HOST = cfg.brokerHost;
          BROKER_PORT = builtins.toString cfg.brokerPort;
          BROKER_TLS_CA = cfg.tlsCa;
          BROKER_TLS_REQUIRE_CERT = if cfg.tlsRequireCert then "true" else "false";
          TARGET_URL = cfg.targetUrl;
          MQTT_TOPIC_PREFIX = "crew";
        }
        // cfg.extraEnvironment;

      serviceConfig = {
        Type = "simple";
        ExecStartPre = "+${builtins.toString stageConfig}";
        ExecStart =
          "${cfg.venvPath}/bin/python ${workerPy} --dir ${stateDir}";
        WorkingDirectory = stateDir;
        StateDirectory = "dhallcrew/${cfg.role}";
        DynamicUser = true;
        EnvironmentFile = cfg.envFile;
        Restart = "on-failure";
        RestartSec = "5";
        TimeoutStopSec = "70";
      };
    };

    # Workers only ever reach out (broker, LLM, target server); do not expose
    # inbound ports beyond SSH (openssh is enabled in hosts/common.nix).
    networking.firewall.enable = true;
  };
}