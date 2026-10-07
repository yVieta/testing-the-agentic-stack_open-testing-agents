locals {
  home = var.home_dir == "" ? "/root" : var.home_dir

  # path.module is "." in a root module; the templates below embed these in
  # Quadlet bind mounts, which Quadlet resolves against the unit directory.
  module_dir = abspath(path.module)

  expanded_quadlet_dir = var.quadlet_dir == "~/.config/containers/systemd" ? format("%s/.config/containers/systemd", local.home) : var.quadlet_dir

  # Storage layout under the big aigents volume:
  #   containers/  podman image + layer graph (the model container lives here)
  #   model/       GGUF weights
  #   database/    PostgreSQL cluster, Qdrant storage, generated credentials
  containers_dir = "${var.spool_root}/containers"
  graph_root     = "${local.containers_dir}/storage"
  run_root       = "/run/user/${var.container_user_id}/containers/storage"
  model_dir      = "${var.spool_root}/model"
  database_dir   = "${var.spool_root}/database"

  postgres_data_dir = "${local.database_dir}/postgres"
  qdrant_data_dir   = "${local.database_dir}/qdrant"
  secret_dir        = "${local.database_dir}/secrets"
  initdb_dir        = "${local.module_dir}/postgres/rendered"
  scripts_dir       = "${local.module_dir}/scripts"

  pod_name = "aigents"
  pod_file = "aigents.pod"
  pod_unit = "aigents-pod.service"

  model_port      = var.model_port
  model_file_path = "${local.model_dir}/${var.model_file}"
  credential_file = "${local.secret_dir}/credentials.env"

  # The bind address inside the container. Always 0.0.0.0 so the pod's published
  # port can reach the server; host side exposure is var.bind_address. Passed via
  # LLAMA_ARG_HOST rather than `--host` because the image already defines that
  # variable, and having both makes llama-server warn that one overwrites the
  # other on every boot. Setting the variable to an empty string is not an
  # option either -- arg parsing then fails with "--host requires at least one
  # address".
  model_bind_address = "0.0.0.0"

  # Quadlet collapses repeated Exec= keys in [Container] to the last one, so the
  # whole llama-server command line is assembled here and emitted as a single
  # Exec= line.
  model_exec_args = join(" ", compact([
    "--model /models/${var.model_file}",
    "--alias ${var.model_alias}",
    "--port 8080",
    "--ctx-size ${var.model_context_size}",
    "--parallel ${var.model_parallel_slots}",
    "--n-gpu-layers ${var.model_gpu_layers}",
    "--cache-type-k ${var.model_kv_cache_type}",
    "--cache-type-v ${var.model_kv_cache_type}",
    var.model_threads > 0 ? "--threads ${var.model_threads}" : "",
    var.model_api_key != "" ? "--api-key ${var.model_api_key}" : "",
    "--jinja",
    "--no-webui",
    "--metrics",
  ]))

  published_ports = compact([
    var.model_port,
    var.postgres_port,
    var.qdrant_http_port,
    var.qdrant_grpc_port,
  ])

  postgres_password = var.postgres_password != "" ? var.postgres_password : random_password.postgres[0].result
  qdrant_api_key    = var.qdrant_api_key != "" ? var.qdrant_api_key : random_password.qdrant[0].result
  mcp_bearer_token  = var.mcp_bearer_token != "" ? var.mcp_bearer_token : random_password.mcp[0].result

  # crewAI runs on the Raspberry Pis, so the MCP facade listens on the LAN while
  # the model itself stays on loopback. Keeping the model private and putting
  # one authenticated facade in front of it means only mcp_port needs to be
  # reachable, and llama.cpp's own CORS-all-origins-without-auth warning never
  # applies to anything but localhost.
  mcp_script = "${dirname(local.module_dir)}/mcp/model_mcp_server.py"
  mcp_reqs   = "${dirname(local.module_dir)}/mcp/requirements.txt"
  mcp_url    = "http://${var.mcp_bind_address == "0.0.0.0" ? "127.0.0.1" : var.mcp_bind_address}:${var.mcp_port}/mcp"
}

# --- podman storage ---------------------------------------------------------

# Quadlet forwards PodmanArgs to `podman pod create` but *not* to
# `podman pod start`, so a per-unit --root leaves `pod start` looking in the
# default graph and failing. The storage config has to be global for the user.
resource "local_file" "storage_conf" {
  filename        = "${local.home}/.config/containers/storage.conf"
  file_permission = "0644"

  content = <<-EOT
    # Written by model-setup/terraform - moves the Podman image/layer graph onto
    # the large aigents volume. Required for pods, see comment in main.tf.
    [storage]

    driver = "overlay"
    runroot = "${local.run_root}"
    graphroot = "${local.graph_root}"
  EOT
}

resource "local_sensitive_file" "credentials_env" {
  filename        = local.credential_file
  file_permission = "0600"

  content = <<-EOT
    # Written by model-setup/terraform - service credentials, mode 0600.
    POSTGRES_DB=${var.postgres_db}
    POSTGRES_USER=${var.postgres_user}
    POSTGRES_PASSWORD=${local.postgres_password}
    POSTGRES_DSN=postgresql://${var.postgres_user}:${local.postgres_password}@127.0.0.1:${var.postgres_port}/${var.postgres_db}
    QDRANT_URL=http://127.0.0.1:${var.qdrant_http_port}
    QDRANT_API_KEY=${local.qdrant_api_key}
    MODEL_URL=http://127.0.0.1:${local.model_port}
    MODEL_NAME=${var.model_alias}
    MODEL_API_KEY=${var.model_api_key}
    MCP_URL=${local.mcp_url}
    MCP_BIND_ADDRESS=${var.mcp_bind_address}
    MCP_PORT=${var.mcp_port}
    MCP_BEARER_TOKEN=${local.mcp_bearer_token}
  EOT
}

resource "random_password" "postgres" {
  count = var.postgres_password == "" ? 1 : 0

  length  = 32
  special = false
}

resource "random_password" "qdrant" {
  count = var.qdrant_api_key == "" ? 1 : 0

  length  = 48
  special = false
}

resource "random_password" "mcp" {
  count = var.mcp_bearer_token == "" ? 1 : 0

  length  = 48
  special = false
}

# --- quadlet unit files -----------------------------------------------------

resource "local_file" "pod" {
  filename        = "${local.expanded_quadlet_dir}/aigents.pod"
  file_permission = "0644"
  content = templatefile("${local.module_dir}/quadlet/aigents.pod.tftpl", {
    pod_name         = local.pod_name
    bind_address     = var.bind_address
    model_port       = local.model_port
    postgres_port    = var.postgres_port
    qdrant_http_port = var.qdrant_http_port
    qdrant_grpc_port = var.qdrant_grpc_port
  })
}

resource "local_file" "postgres_quadlet" {
  filename        = "${local.expanded_quadlet_dir}/postgres.container"
  file_permission = "0644"
  content = templatefile("${local.module_dir}/quadlet/postgres.container.tftpl", {
    pod_unit          = local.pod_unit
    pod_file          = local.pod_file
    home_dir          = local.home
    image_pull_policy = var.image_pull_policy
    postgres_image    = var.postgres_image
    postgres_data_dir = local.postgres_data_dir
    initdb_dir        = local.initdb_dir
    postgres_db       = var.postgres_db
    postgres_user     = var.postgres_user
    postgres_password = local.postgres_password
  })
}

resource "local_file" "qdrant_quadlet" {
  filename        = "${local.expanded_quadlet_dir}/qdrant.container"
  file_permission = "0644"
  content = templatefile("${local.module_dir}/quadlet/qdrant.container.tftpl", {
    pod_unit                  = local.pod_unit
    pod_file                  = local.pod_file
    image_pull_policy         = var.image_pull_policy
    qdrant_image              = var.qdrant_image
    qdrant_data_dir           = local.qdrant_data_dir
    qdrant_api_key            = local.qdrant_api_key
    qdrant_max_search_threads = var.qdrant_max_search_threads
  })
}

resource "local_file" "phi4_quadlet" {
  filename        = "${local.expanded_quadlet_dir}/phi-4.container"
  file_permission = "0600"
  content = templatefile("${local.module_dir}/quadlet/phi-4.container.tftpl", {
    pod_unit           = local.pod_unit
    pod_file           = local.pod_file
    image_pull_policy  = var.image_pull_policy
    model_image        = var.model_image
    model_dir          = local.model_dir
    model_file         = var.model_file
    model_file_path    = local.model_file_path
    model_exec_args    = local.model_exec_args
    model_bind_address = local.model_bind_address
  })
}

resource "local_file" "model_fetch_quadlet" {
  filename        = "${local.expanded_quadlet_dir}/model-fetch.container"
  file_permission = "0600"
  content = templatefile("${local.module_dir}/quadlet/model-fetch.container.tftpl", {
    pod_unit          = local.pod_unit
    image_pull_policy = var.image_pull_policy
    model_image       = var.model_image
    model_dir         = local.model_dir
    model_file_path   = local.model_file_path
    scripts_dir       = local.scripts_dir
    model_repo        = var.model_repo
    model_file        = var.model_file
    model_sha256      = var.model_sha256
    hf_endpoint       = var.hf_endpoint
    hf_token          = var.hf_token
  })
}

# Rendered from postgres/initdb/ so the source SQL stays free of Terraform
# interpolation and can be reviewed as plain SQL.
resource "local_file" "initdb_schema" {
  filename        = "${local.initdb_dir}/01-aigents-schema.sql"
  file_permission = "0644"
  content = templatefile("${local.module_dir}/postgres/initdb/01-aigents-schema.sql", {
    embedding_dimensions = var.embedding_dimensions
  })
}

# --- host preparation -------------------------------------------------------

resource "null_resource" "dirs" {
  triggers = {
    containers = local.containers_dir
    model      = local.model_dir
    database   = local.database_dir
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -eux
      mkdir -p "${local.containers_dir}"
      mkdir -p "${local.graph_root}"
      mkdir -p "${local.run_root}"
      mkdir -p "${local.model_dir}"
      mkdir -p "${local.database_dir}"
      mkdir -p "${local.postgres_data_dir}"
      mkdir -p "${local.qdrant_data_dir}"
      mkdir -p "${local.secret_dir}"
      mkdir -p "${local.expanded_quadlet_dir}"
      mkdir -p "${local.initdb_dir}"
      chmod 0755 "${local.scripts_dir}/fetch-gguf.sh"
      chmod 0700 "${local.secret_dir}"
      systemctl --user daemon-reload || true
      systemctl --user reset-failed podman-user-wait-network-online.service || true
    EOT
  }
}

resource "local_file" "network_online_dropin" {
  count = var.skip_network_online_wait ? 1 : 0

  filename        = "${local.home}/.config/systemd/user/podman-user-wait-network-online.service.d/aigents.conf"
  file_permission = "0644"

  # See containers/podman#22197: Quadlet adds Wants=+After= on this helper to
  # every generated unit, and the helper's ExecStart is a poll loop on the
  # *system* network-online.target with TimeoutStartSec=90s. Where that target
  # never reaches active, every container start pays the full timeout and then
  # fails the helper. It is not a network fault: NetworkManager can be healthy
  # and nm-online instant while the target itself stays inactive.
  content = <<-EOT
    # Written by model-setup/terraform. See skip_network_online_wait.
    [Service]
    ExecStart=
    ExecStart=/bin/true
  EOT
}

resource "null_resource" "install_podman" {
  count = var.install_podman ? 1 : 0

  triggers = {
    packages = join(",", var.install_packages)
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -eux
      if ! command -v podman >/dev/null 2>&1; then
        ${var.apt_command} apt-get update
        ${var.apt_command} apt-get install -y ${join(" ", var.install_packages)}
      fi
      podman --version
    EOT
  }
}

resource "null_resource" "open_firewall" {
  count = var.expose_public ? 1 : 0

  depends_on = [
    local_file.pod,
    null_resource.install_podman,
  ]

  triggers = {
    ports        = join(",", local.published_ports)
    bind_address = var.bind_address
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -eux
      if [ "${var.bind_address}" != "0.0.0.0" ]; then
        echo "bind_address is ${var.bind_address}, not opening the firewall" >&2
        exit 0
      fi
      for p in ${join(" ", local.published_ports)}; do
        ${var.sudo_command} sh -c 'command -v iptables >/dev/null 2>&1 || exit 0
          iptables -C INPUT -p tcp --dport "$1" -j ACCEPT -m comment --comment aigents-model 2>/dev/null ||
            iptables -I INPUT -p tcp --dport "$1" -j ACCEPT -m comment --comment aigents-model' sh "$p"
      done
    EOT
  }
}

# --- MCP server (agent-facing facade over the model) -----------------------

# A venv plus a systemd user service rather than a Quadlet container: it is a
# single stateless Python process, and the model it fronts is already a
# container. See mcp/README.md.
resource "null_resource" "mcp_venv" {
  count = var.enable_mcp_server ? 1 : 0

  triggers = {
    requirements = filesha256(local.mcp_reqs)
    interpreter  = var.mcp_python
    venv         = var.mcp_venv_dir
  }

  provisioner "local-exec" {
    # `python -m venv` needs no extra tooling, and it is exactly how pi-setup
    # builds the worker venv on the Raspberry Pis.
    command = <<-EOT
      set -eux
      mkdir -p "$(dirname "${var.mcp_venv_dir}")"
      if [ ! -x "${var.mcp_venv_dir}/bin/python" ]; then
        ${var.mcp_python} -m venv "${var.mcp_venv_dir}"
      fi
      "${var.mcp_venv_dir}/bin/pip" install --quiet --upgrade pip
      "${var.mcp_venv_dir}/bin/pip" install --quiet --requirement "${local.mcp_reqs}"
      "${var.mcp_venv_dir}/bin/python" -c 'import mcp, starlette, uvicorn; print("mcp deps ok")'
    EOT
  }
}

resource "local_file" "mcp_unit" {
  count = var.enable_mcp_server ? 1 : 0

  filename        = "${local.home}/.config/systemd/user/aigents-mcp.service"
  file_permission = "0600"
  content         = <<-EOT
    [Unit]
    Description=MCP server exposing Phi-4 to the crewAI agents
    Documentation=file://${local.mcp_script}
    # No Requires=phi-4.service on purpose: the weights take minutes to
    # mmap, and requiring them would keep this port down for the whole load.
    # While the model is down the tools return "cannot reach model" instead.
    After=phi-4.service

    [Service]
    Type=simple
    Environment=MODEL_URL=http://127.0.0.1:${local.model_port}/v1
    Environment=MODEL_NAME=${var.model_alias}
    Environment=MODEL_API_KEY=${var.model_api_key}
    Environment=MODEL_CONTEXT=${var.model_context_size}
    Environment=MODEL_TIMEOUT=${var.mcp_model_timeout}
    Environment=MCP_HOST=${var.mcp_bind_address}
    Environment=MCP_PORT=${var.mcp_port}
    Environment=MCP_BEARER_TOKEN=${local.mcp_bearer_token}
    Environment=MCP_ALLOWED_HOSTS=${join(",", var.mcp_allowed_hosts)}
    Environment=MCP_ALLOWED_ORIGINS=${join(",", var.mcp_allowed_origins)}
    ExecStart=${var.mcp_venv_dir}/bin/python ${local.mcp_script} --transport streamable-http
    Restart=on-failure
    RestartSec=5
    NoNewPrivileges=yes
    PrivateTmp=yes

    [Install]
    WantedBy=default.target
  EOT
}

resource "null_resource" "start_mcp" {
  count = var.enable_mcp_server ? 1 : 0

  depends_on = [
    null_resource.mcp_venv,
    local_file.mcp_unit,
    local_sensitive_file.credentials_env,
  ]

  triggers = {
    unit         = local_file.mcp_unit[0].content
    requirements = filesha256(local.mcp_reqs)
    script       = filesha256(local.mcp_script)
  }

  provisioner "local-exec" {
    # Guard first: the default bind address is 0.0.0.0, and an MCP server with
    # no token would hand unauthenticated inference to the whole LAN.
    command = <<-EOT
      set -eu
      export XDG_RUNTIME_DIR=/run/user/$(id -u)
      if [ "${var.mcp_bind_address}" = "127.0.0.1" ] || [ "${var.mcp_bind_address}" = "localhost" ] || [ "${var.mcp_bind_address}" = "::1" ]; then
        echo "MCP_BIND_ADDRESS=${var.mcp_bind_address}: loopback-only, the Raspberry Pis cannot reach it." >&2
      fi
      if [ -z "${local.mcp_bearer_token}" ]; then
        echo "refusing to start aigents-mcp: no bearer token but binding to ${var.mcp_bind_address}" >&2
        exit 1
      fi
      systemctl --user daemon-reload
      systemctl --user enable --now aigents-mcp.service
    EOT
  }
}

# --- lifecycle --------------------------------------------------------------

resource "null_resource" "start_services" {
  depends_on = [
    local_file.storage_conf,
    local_file.pod,
    local_file.postgres_quadlet,
    local_file.qdrant_quadlet,
    local_file.phi4_quadlet,
    local_file.model_fetch_quadlet,
    local_file.initdb_schema,
    local_sensitive_file.credentials_env,
    local_file.network_online_dropin,
    null_resource.dirs,
    null_resource.install_podman,
    null_resource.open_firewall,
  ]

  triggers = {
    pod          = local_file.pod.content
    postgres     = local_file.postgres_quadlet.content
    qdrant       = local_file.qdrant_quadlet.content
    model        = local_file.phi4_quadlet.content
    model_fetch  = local_file.model_fetch_quadlet.content
    fetch_script = filesha256("${local.scripts_dir}/fetch-gguf.sh")
    schema       = local_file.initdb_schema.content
    credentials  = sha256(local_sensitive_file.credentials_env.content)
  }

  provisioner "local-exec" {
    # The model weights are ~8.5 GB, so phi-4 only starts once
    # model-fetch.service has put the GGUF in place. Everything else comes up
    # immediately.
    command = <<-EOT
      set -eu
      export XDG_RUNTIME_DIR=/run/user/$(id -u)
      user=$(id -un)
      wants="${local.home}/.config/systemd/user/default.target.wants"
      mkdir -p "$wants"

      if [ "${var.enable_linger}" = "true" ]; then
        loginctl enable-linger "$user" || true
      fi

      systemctl --user stop phi-4.service 2>/dev/null || true
      systemctl --user stop postgres.service qdrant.service 2>/dev/null || true
      systemctl --user stop ${local.pod_name}-pod.service 2>/dev/null || true

      ln -sf "$XDG_RUNTIME_DIR/systemd/generator/${local.pod_unit}" "$wants/"
      systemctl --user daemon-reload

      systemctl --user restart ${local.pod_name}-pod.service
      systemctl --user start postgres.service qdrant.service
    EOT
  }
}