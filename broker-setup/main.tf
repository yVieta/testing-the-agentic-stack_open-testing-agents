locals {
  home = var.home_dir == "" ? "/root" : var.home_dir

  expanded_quadlet_dir = var.quadlet_dir == "~/.config/containers/systemd" ? format("%s/.config/containers/systemd", local.home) : var.quadlet_dir

  # Everything lives on the big aigents volume, alongside model-setup's databases.
  config_dir      = "${var.spool_root}/database/mosquitto/config"
  data_dir        = "${var.spool_root}/database/mosquitto/data"
  secret_dir      = "${var.spool_root}/database/secrets"
  credential_file = "${local.secret_dir}/mqtt.env"

  # mosquitto runs as uid/gid 1883 inside the container. Its entrypoint chowns
  # /mosquitto/data itself when started as root, but it cannot chown the host
  # bind mounts for config/ without host root, so those files have to stay
  # readable by 1883. Verified against eclipse-mosquitto:2 (2.1.2).
  container_uid = 1883

  pod_name = "aigents-broker"
  pod_file = "aigents-broker.pod"
  pod_unit = "aigents-broker-pod.service"

  cert_script = abspath("${path.module}/scripts/gen-certs.sh")

  # The health probe needs an account of its own: with an acl_file present,
  # anonymous clients may subscribe but every publish is denied, so a
  # pub+sub round-trip cannot be run anonymously. This account is confined to
  # healthcheck/# and cannot touch the crew pipeline.
  healthcheck_user     = "healthcheck"
  healthcheck_topic    = "healthcheck/probe"
  healthcheck_password = random_password.healthcheck.result

  clients = {
    for role, c in var.client_roles : role => {
      username = c.username
      env      = c.env
      password = random_password.mqtt[role].result
      acl      = lookup(var.pipeline_acl, role, { read = [], write = [] })
    }
  }

  cert_dir        = "${var.spool_root}/database/mosquitto/certs"
  client_cert_dir = "${var.spool_root}/database/mosquitto/client-certs"

  # Mosquitto 2.x reads allow_anonymous/password_file per listener and needs no
  # per_listener_settings line (that option is deprecated and warns).
  listeners = concat(
    var.enable_tls ? [{
      port          = var.mqtt_tls_port
      address       = var.bind_address
      protocol      = "mqtt"
      anonymous     = false
      authenticated = true
      tls           = true
    }] : [],
    [{
      port          = var.mqtt_port
      address       = var.bind_address
      protocol      = "mqtt"
      anonymous     = false
      authenticated = true
      tls           = false
    }],
    var.mqtt_ws_port > 0 ? [{
      port          = var.mqtt_ws_port
      address       = var.bind_address
      protocol      = "websockets"
      anonymous     = false
      authenticated = true
      tls           = false
    }] : [],
    [{
      # Loopback only, and deliberately not published. Handy for host-local
      # mosquitto_sub monitoring; it still cannot publish, because the acl_file
      # applies to every listener.
      port          = var.local_monitor_port
      address       = "127.0.0.1"
      protocol      = "mqtt"
      anonymous     = true
      authenticated = false
      tls           = false
    }],
  )

  published_ports = compact([
    var.enable_tls ? var.mqtt_tls_port : null,
    var.enable_tls && var.require_client_certificate ? null : var.mqtt_port,
    var.mqtt_ws_port,
  ])

  # The subset a mosquitto_pub/mosquitto_sub round trip can actually speak.
  # The websockets listener is excluded: it needs the websocket framing, so a
  # plain MQTT client fails against a healthy one.
  mqtt_probe_ports = compact([
    var.enable_tls ? var.mqtt_tls_port : null,
    var.enable_tls && var.require_client_certificate ? null : var.mqtt_port,
  ])

  # The trailing empty string contributes a final newline: the template markers
  # below strip whitespace, which would otherwise run the last line of one
  # listener into the first line of the next (".../passwdlistener 1882 ...").
  listener_block = {
    for l in local.listeners : l.port => join("\n", concat(flatten([
      [
        "listener ${l.port} ${l.address}",
        "protocol ${l.protocol}",
        "allow_anonymous ${l.anonymous}",
        l.authenticated ? "password_file /mosquitto/config/passwd" : "",
      ],
      l.tls ? [
        "cafile /mosquitto/certs/ca.crt",
        "certfile /mosquitto/certs/server.crt",
        "keyfile /mosquitto/certs/server.key",
        # require_client_certificate false still verifies the client when one is
        # presented, it just does not demand one.
        "require_certificate ${var.require_client_certificate}",
        # Lets a client authenticate with its certificate alone: the common name
        # becomes the MQTT username, so the per-role key replaces the password.
        var.require_client_certificate ? "use_identity_as_username true" : "",
        "tls_version tlsv1.2",
      ] : [],
    ]), [""]))
  }

  # --- acl file -------------------------------------------------------------

  # Note: no "user <name>" line appears per role below. mosquitto treats every
  # topic line as belonging to the most recent user, and a bare leading comment
  # after a user block is fine, but an extra "user" line is only needed to
  # *switch* accounts. Each role's block therefore opens with its user line and
  # the comment sits above that line, never after it.
  acl_lines = var.enable_topic_acl ? concat(
    flatten([
      for role, c in local.clients : concat(
        [
          "",
          "# ${role}: read ${join(" ", c.acl.read)}; write ${join(" ", c.acl.write)}",
          "user ${c.username}",
        ],
        [for t in c.acl.read : "topic read ${t}"],
        [for t in c.acl.write : "topic write ${t}"],
      )
    ]),
    [
      "",
      "# Broker-internal probe account, deliberately kept off the crew topics.",
      "user ${local.healthcheck_user}",
      "topic read ${local.healthcheck_topic}",
      "topic write ${local.healthcheck_topic}",
    ],
    ) : [
    "# Topic ACLs are disabled (var.enable_topic_acl = false): every authenticated",
    "# client may read and write every topic.",
  ]

  # Comments are kept flush-left on purpose: mosquitto's config parser only
  # recognises '#' at the start of a line and rejects an indented one with
  # "Unknown configuration variable '#'". Verified on 2.1.2.
  mosquitto_conf = <<-EOT
# Written by broker-setup/terraform. Do not edit; re-run tofu to change it.
#
# Verified behaviour of eclipse-mosquitto:2 (2.1.2) that this file relies on:
#   * allow_anonymous / password_file are per listener, no per_listener_settings
#     line needed (that option is deprecated and warns).
#   * acl_file is global, so it also constrains the loopback listener:
#     anonymous clients can subscribe but cannot publish.
#   * The container runs as uid ${local.container_uid} and its entrypoint only
#     chowns /mosquitto/data, so anything else it must read has to be
#     world-readable on the host. That is also why logs go to stdout rather than
#     to a file: a log file in a host-owned directory is not writable by
#     uid ${local.container_uid}.
%{if var.enable_tls}
#   * `user root` below is what lets it read the 0600 TLS keys. The Quadlet's
#     User=0 is not sufficient on its own: mosquitto re-execs itself as
#     uid ${local.container_uid} unless a user directive says otherwise, and it
#     does so before loading the listener certificates.
%{endif}
#
# The broker carries the crew pipeline: crew/final is the finished pentest
# report, so an unauthenticated LAN client could inject findings into the crew's
# chain. Anonymous access is therefore off on every published listener.

persistence true
persistence_location /mosquitto/data/
persistence_file mosquitto.db
# At most this many seconds of messages are lost if the container is killed
# rather than stopped.
autosave_interval 60
max_queued_messages 10000

# A Raspberry Pi on a laptop Wi-Fi link is a slow client; without this the broker
# disconnects it mid-run.
max_inflight_messages 20

# Logs to the journal, like the postgres and qdrant containers.
log_dest stdout
log_type error
log_type warning
log_type notice
log_type subscribe
log_type unsubscribe
connection_messages true
%{if var.enable_topic_acl}
acl_file /mosquitto/config/acl
%{endif}

%{~if var.enable_tls~}
# Stay root for the whole run. The TLS keys are 0600 on the host, and mosquitto
# re-execs itself as uid 1883 ("running mosquitto as user: mosquitto") unless a
# user directive says otherwise, which it does before it reads the listener
# certificates. Under rootless podman container root is the host user, so this
# grants no privilege the applying user did not already have. Without it the
# broker dies with "Unable to load CA certificates ... Permission denied".
user root
%{endif}

%{for l in local.listeners~}
${local.listener_block[l.port]}
%{~endfor~}
  EOT

  # `$${...}` escapes the shell's own braces so HCL emits them literally.
  healthcheck_script = <<-SH
    #!/bin/sh
    # Health probe for the mosquitto container. Runs as HealthCmd=.
    #
    # It lives in a file rather than inline in the unit for two reasons:
    #   * systemd expands $ in ExecStart, so shell variables cannot be used there.
    #   * POSIX `wait` with no operand always returns 0, so an inline
    #     `sub & pub; wait` reports healthy forever no matter what happened.
    set -u
    . /mosquitto/config/healthcheck.env
    # Optional first argument lets the apply-time check probe the published port
    # rather than the loopback one.
    port=$${1:-__PORT__}
    topic=__TOPIC__

    # One probe for both listeners. On the TLS port the client presents the probe
    # account's certificate and the broker derives the username from its common
    # name, so the password below only matters on the plaintext port.
    tls_opts=""
    if [ "$port" = "__TLS_PORT__" ]; then
      tls_opts="--cafile /mosquitto/certs/ca.crt"
      tls_opts="$tls_opts --cert /mosquitto/certs/healthcheck.crt"
      tls_opts="$tls_opts --key /mosquitto/certs/healthcheck.key"
    fi

    # shellcheck disable=SC2086
    mosquitto_sub -h 127.0.0.1 -p "$port" $tls_opts \
      -u "$HEALTHCHECK_USERNAME" -P "$HEALTHCHECK_PASSWORD" \
      -t "$topic" -C 1 -W 5 >/dev/null 2>&1 &
    sub=$!
    sleep 1
    # A denied publish still exits 0 in MQTT 3.1.1, so the publish alone proves
    # nothing; the round trip through the subscriber is the actual assertion.
    # shellcheck disable=SC2086
    if ! mosquitto_pub -h 127.0.0.1 -p "$port" $tls_opts \
      -u "$HEALTHCHECK_USERNAME" -P "$HEALTHCHECK_PASSWORD" \
      -t "$topic" -m ping >/dev/null 2>&1; then
      kill "$sub" 2>/dev/null
      echo "healthcheck: broker refused the connection on port $port" >&2
      exit 1
    fi
    if wait "$sub"; then
      exit 0
    fi
    echo "healthcheck: publish/subscribe round trip did not complete on port $port" >&2
    exit 1
  SH
}

# --- credentials ------------------------------------------------------------

resource "random_password" "mqtt" {
  for_each = var.client_roles

  length  = 32
  special = false
}

resource "random_password" "healthcheck" {
  length  = 32
  special = false
}

# Plaintext passwords for handing to the Pis. Mode 0600, never committed.
resource "local_sensitive_file" "mqtt_env" {
  filename        = local.credential_file
  file_permission = "0600"

  content = <<-EOT
    # Written by broker-setup/terraform - MQTT broker credentials, mode 0600.
    # Source it, or copy the pair you need into the Pi's .env:
    #   set -a; . ${local.credential_file}; set +a
    MQTT_HOST=${var.bind_address}
    MQTT_PORT=${var.mqtt_port}
    %{~if var.mqtt_ws_port > 0~}
    MQTT_WS_PORT=${var.mqtt_ws_port}
    %{~endif~}
    %{~for role, c in local.clients~}
    # ${role}
    MQTT_USERNAME_${c.env}=${c.username}
    MQTT_PASSWORD_${c.env}=${c.password}
    %{~endfor~}
  EOT
}

# Read by healthcheck.sh inside the container. The account behind it can only
# touch healthcheck/#, so this plaintext is close to worthless.
resource "local_file" "healthcheck_env" {
  count = var.enable_deep_healthcheck ? 1 : 0

  filename        = "${local.config_dir}/healthcheck.env"
  file_permission = "0644"

  content = <<-EOT
    HEALTHCHECK_USERNAME=${local.healthcheck_user}
    HEALTHCHECK_PASSWORD=${local.healthcheck_password}
  EOT
}

resource "local_file" "healthcheck_script" {
  count = var.enable_deep_healthcheck ? 1 : 0

  filename        = "${local.config_dir}/healthcheck.sh"
  file_permission = "0755"

  content = replace(
    replace(
      replace(local.healthcheck_script, "__TOPIC__", local.healthcheck_topic),
      "__PORT__", tostring(var.mqtt_port),
    ),
    "__TLS_PORT__", tostring(var.mqtt_tls_port),
  )
}

# --- TLS material -----------------------------------------------------------

# OpenTofu cannot sign certificates, so scripts/gen-certs.sh does it with
# openssl: a private CA, one server certificate covering every address the host
# has, and one client certificate per role. Each role's stamp file is a trigger,
# so adding a role regenerates just that certificate.
resource "null_resource" "certificates" {
  count = var.enable_tls ? 1 : 0

  triggers = {
    sans       = join(",", concat(var.tls_extra_sans, [var.broker_hostname]))
    roles      = jsonencode({ for r, c in local.clients : r => c.username })
    probe_user = var.enable_deep_healthcheck ? local.healthcheck_user : ""
    ca_finger  = var.force_reissue_certificates ? timestamp() : ""
    script_sha = filesha256(local.cert_script)
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -eu
      chmod 0755 "${local.cert_script}"
      mkdir -p "${local.client_cert_dir}"

      # Usernames on stdin. The health-probe account is included because the TLS
      # listener refuses password-only clients once client certificates are
      # mandatory, so the container's own probe needs a certificate too.
      {
      %{~for role, c in local.clients~}
        printf '%s\n' '${c.username}'
      %{~endfor~}
      %{~if var.enable_deep_healthcheck~}
        printf '%s\n' '${local.healthcheck_user}'
      %{~endif~}
      } | "${local.cert_script}" \
        "${local.cert_dir}" "${local.client_cert_dir}" \
        '${join(",", concat(var.tls_extra_sans, [var.broker_hostname]))}' \
        '%{if var.enable_deep_healthcheck}${local.healthcheck_user}%{endif}'
    EOT
  }
}

# The client certificates, ready to copy onto the Pis. Readable rather than
# 0600-owned so a Pi can be handed a single archive.
resource "local_file" "client_bundle_manifest" {
  count = var.enable_tls ? 1 : 0

  filename        = "${local.client_cert_dir}/README.txt"
  file_permission = "0644"

  content = <<-EOT
    Written by broker-setup/terraform.

    Per-role client certificates for the MQTT broker over TLS:

      ${join("\n      ", [for r, c in local.clients : "${c.username}.crt + ${c.username}.key"])}
      ca.crt   (in ${local.cert_dir}, copy this to the Pi as the trust anchor)

    Copy a role's .crt/.key plus ca.crt to that Pi. The broker maps the
    certificate's common name to the MQTT username, so the password is not needed
    when the certificate is presented. Without a certificate, the plain MQTT port
    ${var.mqtt_port} still accepts the password.
  EOT
}

# --- broker configuration ---------------------------------------------------

resource "local_file" "mosquitto_conf" {
  filename        = "${local.config_dir}/mosquitto.conf"
  file_permission = "0644"

  content = local.mosquitto_conf
}

resource "local_file" "acl" {
  count = var.enable_topic_acl ? 1 : 0

  # 0644 because uid ${local.container_uid} has to read it and, without host
  # root, nothing can chown a host bind mount into the container's uid. mosquitto
  # 2.1.2 only warns; mosquitto 3.0 plans to refuse such files. See README.md.
  filename        = "${local.config_dir}/acl"
  file_permission = "0644"

  content = join("\n", local.acl_lines)
}

# Hashed by mosquitto's own tool in a throwaway container. OpenTofu 1.13 has no
# pbkdf2/mkpasswd function, and reimplementing mosquitto's $7$ PBKDF2-SHA512
# format in HCL would risk silent breakage when it drifts.
resource "null_resource" "mosquitto_passwd" {
  triggers = {
    users = jsonencode({ for r, c in local.clients : r => c.username })
    hash = sha256(jsonencode(concat(
      [for r, c in local.clients : c.password],
      [local.healthcheck_password],
    )))
    image          = var.mosquitto_image
    hash_algorithm = var.mosquitto_hash_algorithm
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -eux
      export XDG_RUNTIME_DIR=/run/user/$(id -u)
      mkdir -p "${local.config_dir}"
      rm -f "${local.config_dir}/passwd"

      # -c creates the file, -b takes the password on the command line. It runs in
      # a temporary container so nothing lands in the repo or in shell history.
      tmpdir=$(mktemp -d)
      trap 'rm -rf "$tmpdir"' EXIT

      # -b takes each password from argv, but mosquitto_passwd has no batch mode:
      # it only ever handles one user per invocation. Adding users with -c each
      # time would discard the earlier ones, so create with the first account and
      # append the rest.
      podman run --rm -v "$tmpdir:/out:z" "${var.mosquitto_image}" \
        mosquitto_passwd -H "${var.mosquitto_hash_algorithm}" -c -b \
        /out/passwd '${local.healthcheck_user}' '${local.healthcheck_password}'
      %{for role, c in local.clients~}
      podman run --rm -v "$tmpdir:/out:z" "${var.mosquitto_image}" \
        mosquitto_passwd -H "${var.mosquitto_hash_algorithm}" -b \
        /out/passwd '${c.username}' '${c.password}'
      %{endfor~}

      install -m 0644 "$tmpdir/passwd" "${local.config_dir}/passwd"
    EOT
  }
}

# --- quadlet units ----------------------------------------------------------

resource "local_file" "pod" {
  filename        = "${local.expanded_quadlet_dir}/${local.pod_file}"
  file_permission = "0644"

  content = <<-EOT
    [Unit]
    Description=Pod for the MQTT broker

    [Pod]
    PodName=${local.pod_name}
    %{~for port in local.published_ports~}
    PublishPort=${var.bind_address}:${port}:${port}
    %{~endfor~}
    # The loopback monitor port is intentionally not published.

    [Install]
    WantedBy=default.target
  EOT
}

resource "local_file" "mosquitto_quadlet" {
  filename        = "${local.expanded_quadlet_dir}/mqtt-broker.container"
  file_permission = "0644"

  content = <<-EOT
    [Unit]
    Description=Mosquitto MQTT broker for the crewAI workers
    After=${local.pod_unit}
    Requires=${local.pod_unit}

    [Container]
    Image=${var.mosquitto_image}
    Pull=${var.image_pull_policy}
    Pod=${local.pod_file}
    Volume=${local.config_dir}:/mosquitto/config:Z
    Volume=${local.data_dir}:/mosquitto/data:Z
    %{~if var.enable_tls~}
    # Keys are 0600 on the host and unreadable to uid ${local.container_uid}
    # otherwise, so the broker needs to start as root to read them at all. Its
    # entrypoint drops to uid ${local.container_uid} afterwards.
    User=0
    # Read-only, and at its own path. The server key is 0600 on the host, so only
    # container root can read it (host uid ${var.container_user_id} under rootless
    # podman); the broker then drops to uid ${local.container_uid}. The per-role
    # client keys live in a separate directory that is never mounted here.
    Volume=${local.cert_dir}:/mosquitto/certs:Z,ro
    %{~endif~}
    # No log volume: uid ${local.container_uid} cannot write a host-owned
    # directory, so the broker logs to stdout and the journal keeps it.

    %{~if var.enable_deep_healthcheck~}
    # Proves an authenticated publish/subscribe round trip, not merely an open port.
    HealthCmd=/bin/sh /mosquitto/config/healthcheck.sh
    HealthInterval=30s
    HealthStartPeriod=20s
    HealthRetries=3
    %{~else~}
    # Fallback probe: the image has no curl or wget and no bash, but it does have nc.
    HealthCmd=nc -z 127.0.0.1 ${var.mqtt_port}
    HealthInterval=30s
    HealthStartPeriod=20s
    HealthRetries=3
    %{~endif~}

    [Service]
    Restart=always
    RestartSec=5

    [Install]
    WantedBy=${local.pod_unit}
  EOT
}

# --- host preparation -------------------------------------------------------

resource "null_resource" "dirs" {
  triggers = {
    config     = local.config_dir
    data       = local.data_dir
    credential = local.credential_file
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -eux
      mkdir -p "${local.config_dir}" "${local.data_dir}"
      mkdir -p "${local.secret_dir}"
      mkdir -p "${local.expanded_quadlet_dir}"
      chmod 0700 "${local.secret_dir}"
      systemctl --user daemon-reload || true
      systemctl --user reset-failed podman-user-wait-network-online.service || true
    EOT
  }
}

# --- lifecycle --------------------------------------------------------------

resource "null_resource" "start_services" {
  depends_on = [
    local_file.pod,
    local_file.mosquitto_quadlet,
    local_file.mosquitto_conf,
    local_sensitive_file.mqtt_env,
    null_resource.mosquitto_passwd,
    null_resource.dirs,
    null_resource.certificates,
  ]

  triggers = {
    pod    = local_file.pod.content
    broker = local_file.mosquitto_quadlet.content
    conf   = local_file.mosquitto_conf.content
    acl    = var.enable_topic_acl ? local_file.acl[0].content : ""
    # The passwd file is hashed inside a throwaway container, so its contents are
    # not available as a resource attribute. Trigger on the inputs that generate
    # it instead: null_resource.mosquitto_passwd re-runs whenever these change.
    passwd          = sha256(jsonencode(concat([for r, c in local.clients : c.password], [local.healthcheck_password])))
    linger          = var.enable_linger
    healthcheck     = var.enable_deep_healthcheck ? local_file.healthcheck_script[0].content : ""
    healthcheck_env = var.enable_deep_healthcheck ? local_file.healthcheck_env[0].content : ""
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -eu
      export XDG_RUNTIME_DIR=/run/user/$(id -u)
      wants="${local.home}/.config/systemd/user/default.target.wants"
      mkdir -p "$wants"

      %{~if var.enable_linger~}
      # Without linger the broker stops at logout and the Pis lose it.
      loginctl enable-linger "$(id -un)" || true
      %{~endif~}

      rm -f "$wants/${local.pod_unit}" "$wants/mqtt-broker.service"
      ln -sf "$XDG_RUNTIME_DIR/systemd/generator/${local.pod_unit}" "$wants/"
      systemctl --user daemon-reload

      systemctl --user restart ${local.pod_unit}
      systemctl --user restart mqtt-broker.service

      # Prove a real client can authenticate and complete a round trip on the
      # published port. mosquitto_pub exiting 0 proves nothing on its own, because
      # MQTT 3.1.1 does not acknowledge refused publishes, so the subscriber has
      # to actually receive the message.
      # Quadlet names rootful containers systemd-<unit>; under rootless podman it
      # is <unit> with a systemd- prefix. Ask podman for the name instead of
      # hardcoding it, so this keeps working either way. Note the label key is
      # PODMAN_SYSTEMD_UNIT, not the io.* form that --filter expects.
      container=$(podman ps --filter "label=PODMAN_SYSTEMD_UNIT=mqtt-broker.service" \
        --format '{{.Names}}' | head -1)
      if [ -z "$container" ]; then
        echo "no running container labelled for mqtt-broker.service" >&2
        journalctl --user -u mqtt-broker.service -n 40 --no-pager >&2 || true
        exit 1
      fi

      # Probe every published MQTT listener, so a TLS listener that fails to come
      # up cannot pass unnoticed behind a working plaintext one. The websockets
      # port is not in this list: mosquitto_pub speaks MQTT, not the websocket
      # framing, so it would fail against a perfectly healthy 9001. It is covered
      # by the socket reachability check below instead.
      probe_ports="${join(" ", local.mqtt_probe_ports)}"
      for port in $probe_ports; do
        ok=0
        for attempt in $(seq 1 30); do
          if podman exec "$container" /bin/sh /mosquitto/config/healthcheck.sh "$port" >/dev/null 2>&1; then
            ok=1
            break
          fi
          sleep 2
        done

        if [ "$ok" != 1 ]; then
          echo "broker did not accept an authenticated round trip on :$port" >&2
          journalctl --user -u mqtt-broker.service -n 40 --no-pager >&2 || true
          exit 1
        fi
        echo "broker accepts authenticated connections on ${var.bind_address}:$port"
      done

      # Also confirm the socket is reachable on the LAN interface, because a
      # loopback-only bind or a firewall drop would leave the Pis stranded.
      lan_ip=$(ip -4 -o addr show scope global 2>/dev/null | awk '$2 !~ /^(lo|docker|veth|virbr|cni|flannel)/ {split($4,a,"/"); print a[1]; exit}')
      if [ -n "$lan_ip" ]; then
        for port in ${join(" ", local.published_ports)}; do
          if timeout 3 sh -c "exec 3<>/dev/tcp/$lan_ip/$port" 2>/dev/null; then
            echo "  reachable on $lan_ip:$port"
          else
            echo "  WARNING: $lan_ip:$port is not reachable; check bind_address and the firewall" >&2
          fi
        done
      fi
    EOT
  }
}
