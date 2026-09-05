# NixOS module for the MQTT broker (Mosquitto) used by the crew network.
#
# The ACL is generated declaratively (no secrets). The password file and the
# TLS certificates are secrets that must be created once with
# nix/gen-credentials.sh and live in /etc/dhallcrew/.
#
# Two listeners are provided by default: a TLS one on 8883 (used by the
# workers) and a plaintext one on 1883 for debugging. Remove the 1883
# listener in production.

{ config, lib, pkgs, ... }:
let
  inherit (lib) mkIf mkOption types;

  cfg = config.mqttBroker;

  # Declarative ACL - one restricted identity per worker plus a read-only
  # monitor. `read` = subscribe, `write` = publish (mirrors deploy ACL).
  acl = pkgs.writeText "dhallcrew.acl" ''
    user pi1-e2e
    topic read crew/start
    topic write crew/pentester/input
    topic write crew/status/pi1-e2e

    user pi2-pentester
    topic read crew/pentester/input
    topic write crew/manager/input
    topic write crew/status/pi2-pentester

    user pi3-manager
    topic read crew/manager/input
    topic write crew/final
    topic write crew/status/pi3-manager

    user trigger
    topic write crew/start

    user monitor
    topic read crew/status/#
    topic read crew/final
  '';
in
{
  options.mqttBroker = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Run the crew MQTT broker on this host.";
    };
    passwordFile = mkOption {
      type = types.str;
      default = "/etc/dhallcrew/mosquitto.passwd";
      description = "mosquitto_passwd file (created by nix/gen-credentials.sh).";
    };
    certsDir = mkOption {
      type = types.str;
      default = "/etc/dhallcrew/certs";
      description = "Directory with ca.crt, server.crt, server.key.";
    };
    allowPlaintext = mkOption {
      type = types.bool;
      default = true;
      description = "Expose a plaintext 1883 listener (debugging).";
    };
  };

  config = mkIf cfg.enable {
    services.mosquitto = {
      enable = true;
      listeners =
        lib.optional cfg.allowPlaintext {
          address = "0.0.0.0";
          port = 1883;
          cafile = "${cfg.certsDir}/ca.crt";
          certfile = "${cfg.certsDir}/server.crt";
          keyfile = "${cfg.certsDir}/server.key";
        }
        ++ [{
          address = "0.0.0.0";
          port = 8883;
          cafile = "${cfg.certsDir}/ca.crt";
          certfile = "${cfg.certsDir}/server.crt";
          keyfile = "${cfg.certsDir}/server.key";
        }];
      settings = {
        allow_anonymous = false;
        # acl_file is generated declaratively into the nix store...
        acl_file = acl;
        # ...while password_file is a secret outside the store.
        password_file = cfg.passwordFile;
        message_size_limit = 10485760;
        max_inflight_messages = 20;
      };
    };

    networking.firewall.allowedTCPPorts =
      [ 8883 ] ++ lib.optional cfg.allowPlaintext 1883;
  };
}