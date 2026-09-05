#!/usr/bin/env bash
# Create the secrets the NixOS configuration references (NOT stored in the
# nix store):
#   /etc/dhallcrew/mosquitto.passwd   - broker user hashes
#   /etc/dhallcrew/certs/*            - private CA + broker TLS server cert
#   /etc/dhallcrew/<role>.env         - per-worker secrets (broker credentials)
#
# Run this ON THE BROKER HOST once, then copy the resulting files to the
# worker Pis where the .env files live. The NixOS config in this repo only
# supplies the non-secret defaults; these files carry the credentials.
#
#   sudo ./nix/gen-credentials.sh [BROKER_IP_OR_HOSTNAME]
set -euo pipefail

BROKER_HOST="${1:-local-broker.lan}"
DEST=/etc/dhallcrew
mkdir -p "$DEST/certs"

command -v mosquitto_passwd >/dev/null || { echo "install mosquitto first (nixos: services.mosquitto or pkgs.mosquitto)" >&2; exit 1; }

# --- 1. broker users --------------------------------------------------------
USERS="pi1-e2e pi2-pentester pi3-manager trigger monitor"
: > "$DEST/mosquitto.passwd"
for u in $USERS; do
  read -rsp "broker password for '$u': " PASS; echo
  read -rsp "repeat               : " PASS2; echo
  [ "$PASS" = "$PASS2" ] || { echo "mismatch - aborting"; exit 1; }
  mosquitto_passwd -b "$DEST/mosquitto.passwd" "$u" "$PASS"
done
chmod 0640 "$DEST/mosquitto.passwd"

# --- 2. TLS: private CA + server certificate --------------------------------
if [ ! -f "$DEST/certs/ca.crt" ]; then
  echo ">> generating local private CA + broker server certificate"
  openssl genrsa -out "$DEST/certs/ca.key" 2048
  openssl req -x509 -new -nodes -key "$DEST/certs/ca.key" -sha256 -days 3650 \
    -subj "/CN=dhallcrew CA" -out "$DEST/certs/ca.crt"

  openssl genrsa -out "$DEST/certs/server.key" 2048
  openssl req -new -key "$DEST/certs/server.key" \
    -subj "/CN=$BROKER_HOST" -out "$DEST/certs/server.csr"
  cat > "$DEST/certs/server.ext" <<EOF
subjectAltName = DNS:$BROKER_HOST, IP:$BROKER_HOST
extendedKeyUsage = serverAuth
EOF
  openssl x509 -req -in "$DEST/certs/server.csr" -CA "$DEST/certs/ca.crt" \
    -CAkey "$DEST/certs/ca.key" -CAcreateserial -days 825 -sha256 \
    -extfile "$DEST/certs/server.ext" -out "$DEST/certs/server.crt"
  rm -f "$DEST/certs/server.csr" "$DEST/certs/server.ext" "$DEST/certs/ca.srl"
  chmod 0640 "$DEST/certs/ca.key" "$DEST/certs/server.key"
fi

# --- 3. per-worker secret env files -----------------------------------------
# The worker service EnvironmentFile= points here; it must contain the MQTT
# credentials the module cannot know. Non-secret settings are supplied by the
# NixOS module itself. Only generate what the NixOS host needs.
mk_env() { # role user
  local role="$1" user="$2"
  if [ ! -f "$DEST/$role.env" ]; then
    cat > "$DEST/$role.env" <<EOF
BROKER_USERNAME=$user
# BROKER_PASSWORD=change-me
EOF
  fi
}
mk_env pi1-e2e pi1-e2e
mk_env pi2-pentester pi2-pentester
mk_env pi3-manager pi3-manager

echo
echo "OK. Secrets created under $DEST"
echo
echo "Next:"
echo "  * copy the whole dir to the Pis:"
echo "      scp -r $DEST  piN:/etc/"
echo "    (or just the ca.crt to each worker: scp $DEST/certs/ca.crt piN:/etc/dhallcrew/certs/)"
echo "  * fill in BROKER_PASSWORD in each worker .env (or use systemd-importd/age)"
echo "  * nixos-rebuild switch --flake .#broker  (on the broker)"
echo "  * nixos-rebuild switch --flake .#pi1-e2e  (on each worker)"