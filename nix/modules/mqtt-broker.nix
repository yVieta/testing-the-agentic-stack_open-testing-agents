# NixOS module for the MQTT broker (Mosquitto) used by the crew network.
#
# Match the current nixpkgs services.mosquitto API (>= 2.1): authentication is
# configured per listener via `users`; each user's password hash and ACL are
# declarative. The hashes are secrets written once on the broker into
# /etc/dhallcrew/passwd/<user> - one hash per file, without the "<user>:"
# prefix - e.g. `mosquitto_passwd -b <tmp> <user> <pass> && cut -d: -f2 <tmp>`.
# They must NOT live in the nix store.
#
# Two listeners are provided by default: a TLS one on 8883 (used by the
# workers) and a plaintext one on 1883 for debugging. Remove the 1883
# listener in production.

{ config, lib, pkgs, ... }:
let
  inherit (lib) mkIf mkOption types;

  cfg = config.mqttBroker;

  # Restrictive ACLs - one identity per worker plus a read-only monitor.
  # `read` = subscribe, `write` = publish.
  acls = {
    pi1-e2e = [
      "read crew/start"
      "write crew/pentester/input"
      "write crew/status/pi1-e2e"
    ];
    pi2-pentester = [
      "read crew/pentester/input"
      "write crew/manager/input"
      "write crew/status/pi2-pentester"
    ];
    pi3-manager = [
      "read crew/manager/input"
      "write crew/final"
      "write crew/status/pi3-manager"
    ];
    trigger = [ "write crew/start" ];
    monitor = [ "read crew/status/#" "read crew/final" ];
  };

  # Each user authenticates against its hash file under /etc/dhallcrew/passwd;
  # the hash is passed to mosquitto via systemd credentials (LoadCredential)
  # so it never ends up in the store.
  users = lib.mapAttrs (name: acl: {
    hashedPasswordFile = "${cfg.passwordsDir}/${name}";
    inherit acl;
  }) acls;
in
{
  options.mqttBroker = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Run the crew MQTT broker on this host.";
    };
    passwordsDir = mkOption {
      type = types.str;
      default = "/etc/dhallcrew/passwd";
      description = ''
        Directory with one mosquitto password-hash file per MQTT user
        (created manually, see module header). Each file holds a single hash
        without the "<user>:" prefix - the module adds the user name itself.
      '';
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
        lib.optional cfg.allowPlaintext
          {
            address = "0.0.0.0";
            port = 1883;
            inherit users;
            settings.allow_anonymous = false;
          }
        ++ [{
          address = "0.0.0.0";
          port = 8883;
          inherit users;
          settings = {
            allow_anonymous = false;
            cafile = "${cfg.certsDir}/ca.crt";
            certfile = "${cfg.certsDir}/server.crt";
            keyfile = "${cfg.certsDir}/server.key";
          };
        }];
      settings = {
        message_size_limit = 10485760;
        max_inflight_messages = 20;
      };
    };

    networking.firewall.allowedTCPPorts =
      [ 8883 ] ++ lib.optional cfg.allowPlaintext 1883;
  };
}