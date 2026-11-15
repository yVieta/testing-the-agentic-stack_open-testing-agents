#!/bin/sh
# Generates the MQTT broker's TLS material: a private CA, a server certificate
# for the broker, and one client certificate per crewAI role.
#
# Written by broker-setup/terraform; run by null_resource.certificates.
#
# Arguments (all optional, defaults suit this deployment):
#   $1 output directory for the CA and server key/cert
#   $2 output directory for the client key/certs
#   $3 comma-separated extra SANs (DNS names and IPs) for the server certificate
#   $4 username whose certificate is also written into $1, for a probe that runs
#      inside the container and can only read the mounted CA directory
#
# Client identities arrive on stdin, one MQTT username per line. The certificate's
# common name is that username, which is what mosquitto's use_identity_as_username
# maps back to the account, so no password has to travel over the wire.
#
# Deliberately not done in HCL: OpenTofu has no x509 or certificate-signing
# function, so the work belongs in openssl. Passwords are not accepted on the
# command line: these keys are long-lived and shared with the Pis, so an
# interactive prompt keeps them out of ps output and shell history.
set -eu

cert_dir=${1:?output directory for the CA and server certificate required}
client_dir=${2:?output directory for the client certificates required}
extra_sans=${3:-}
probe_user=${4:-}

umask 077
mkdir -p "$cert_dir" "$client_dir"

subject=/CN=aigents-mqtt-ca
days=825

lan_ips=$(ip -4 -o addr show scope global 2>/dev/null \
  | awk '$2 !~ /^(lo|docker|veth|virbr|cni|flannel)/ {split($4, a, "/"); print a[1]}')
[ -n "$lan_ips" ] || lan_ips=127.0.0.1

san_list="DNS:localhost,IP:127.0.0.1"
for ip in $lan_ips; do
  san_list="$san_list,IP:$ip"
done
if [ -n "$extra_sans" ]; then
  # Accept both bare names and ready-made DNS:/IP: entries.
  old_ifs=$IFS
  IFS=,
  for san in $extra_sans; do
    case "$san" in
      DNS:* | IP:*) san_list="$san_list,$san" ;;
      *) san_list="$san_list,DNS:$san" ;;
    esac
  done
  IFS=$old_ifs
fi

echo "generating CA and server certificate for: $san_list"

if [ ! -f "$cert_dir/ca.crt" ] || [ ! -f "$cert_dir/ca.key" ]; then
  openssl req -x509 -newkey rsa:4096 -sha256 -days $((days * 4)) -nodes \
    -keyout "$cert_dir/ca.key" -out "$cert_dir/ca.crt" \
    -subj "$subject" -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    >/dev/null 2>&1
  chmod 0600 "$cert_dir/ca.key"
  chmod 0644 "$cert_dir/ca.crt"
fi

# openssl's -CAcreateserial creates ca.srl and picks a fresh random serial when
# the file is absent. Without it, and with no ca.srl present, x509 fails with
# "Unable to load number from .../ca.srl".

extfile=$(mktemp)
trap 'rm -f "$extfile"' EXIT
cat >"$extfile" <<EOF
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = $san_list
subjectKeyIdentifier = hash
EOF

openssl req -newkey rsa:2048 -nodes -keyout "$cert_dir/server.key" \
  -out "$cert_dir/server.csr" -subj "/CN=adora.local" >/dev/null 2>&1
# -extfile supplies the extensions directly; there is no named section to select.
if ! openssl x509 -req -in "$cert_dir/server.csr" -CA "$cert_dir/ca.crt" \
  -CAkey "$cert_dir/ca.key" -CAserial "$cert_dir/ca.srl" -CAcreateserial \
  -out "$cert_dir/server.crt" -days $days -sha256 \
  -extfile "$extfile" >/dev/null 2>&1; then
  # Retry without -CAcreateserial: if an earlier run was interrupted between
  # creating ca.srl and filling it, the empty file breaks serial parsing.
  echo "openssl failed to sign the server certificate; retrying without -CAcreateserial:" >&2
  openssl x509 -req -in "$cert_dir/server.csr" -CA "$cert_dir/ca.crt" \
    -CAkey "$cert_dir/ca.key" -CAserial "$cert_dir/ca.srl" \
    -out "$cert_dir/server.crt" -days $days -sha256 -extfile "$extfile" >&2 || true
  exit 1
fi
rm -f "$cert_dir/server.csr"
chmod 0600 "$cert_dir/server.key"
chmod 0644 "$cert_dir/server.crt"

client_ext=$(mktemp)
cat >"$client_ext" <<EOF
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
subjectKeyIdentifier = hash
EOF

# Identities arrive on stdin, one MQTT username per line. Blank lines and #comments
# are ignored so the caller can format the list readably.
while read -r username; do
  # `tr` rather than ${var%$'\r'}: this is dash, where $'...' is not supported.
  username=$(printf '%s' "$username" | tr -d '\r')
  case "$username" in
    "" | \#*) continue ;;
  esac
  echo "generating client certificate for $username"

  openssl req -newkey rsa:2048 -nodes \
    -keyout "$client_dir/$username.key" -out "$client_dir/$username.csr" \
    -subj "/CN=$username" >/dev/null 2>&1
  # No -CAcreateserial here: it would reset ca.srl to a fresh value on every call
  if ! openssl x509 -req -in "$client_dir/$username.csr" -CA "$cert_dir/ca.crt" \
    -CAkey "$cert_dir/ca.key" -CAserial "$cert_dir/ca.srl" \
    -out "$client_dir/$username.crt" -days $days -sha256 \
    -extfile "$client_ext" >/dev/null 2>&1; then
    echo "failed to sign the client certificate for $username:" >&2
    openssl x509 -req -in "$client_dir/$username.csr" -CA "$cert_dir/ca.crt" \
      -CAkey "$cert_dir/ca.key" -CAserial "$cert_dir/ca.srl" \
      -out "$client_dir/$username.crt" -days $days -sha256 \
      -extfile "$client_ext" >&2 || true
    exit 1
  fi
  rm -f "$client_dir/$username.csr"
  chmod 0600 "$client_dir/$username.key"
  chmod 0644 "$client_dir/$username.crt"

 if [ -n "$probe_user" ] && [ "$username" = "$probe_user" ]; then
    cp "$client_dir/$username.crt" "$cert_dir/$username.crt"
    cp "$client_dir/$username.key" "$cert_dir/$username.key"
    chmod 0644 "$cert_dir/$username.crt"
    chmod 0600 "$cert_dir/$username.key"
  fi

  : >"$client_dir/$username.stamp"
  chmod 0600 "$client_dir/$username.stamp"
done

rm -f "$client_ext"
echo "TLS material written to $cert_dir and $client_dir"
