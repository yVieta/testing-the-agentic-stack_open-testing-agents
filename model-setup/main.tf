locals {
  # Home of the user running tofu (the rootless podman/systemd user). Never
  # hardcode a username: empty home_dir resolves the invoking user's real home.
  home = var.home_dir != "" ? var.home_dir : pathexpand("~")

  # path.module is "." in a root module; templates need absolute paths.
  module_dir = abspath(path.module)

  expanded_quadlet_dir = var.quadlet_dir == "~/.config/containers/systemd" ? format("%s/.config/containers/systemd", local.home) : var.quadlet_dir

  # Storage layout under the big aigents volume:
  #   containers/  podman image + layer graph
  #   model/       GGUF weights
  #   database/    PostgreSQL cluster, generated credentials
  containers_dir = "${var.spool_root}/containers"
  graph_root     = "${local.containers_dir}/storage"
  run_root       = "/run/user/${var.container_user_id}/containers/storage"
  model_dir      = "${var.spool_root}/model"
  database_dir   = "${var.spool_root}/database"
  compose_dir    = "${var.spool_root}/compose"

  postgres_data_dir = "${local.database_dir}/postgres"
  secret_dir        = "${local.database_dir}/secrets"
  initdb_dir        = "${local.module_dir}/postgres/rendered"
  scripts_dir       = "${local.module_dir}/scripts"

  compose_file       = "${local.compose_dir}/compose.yaml"
  model_file_path    = "${local.model_dir}/${var.model_file}"
  credential_file    = "${local.secret_dir}/credentials.env"
  model_port         = var.model_port
  model_bind_address = "0.0.0.0"

  # llama.cpp server args. Rendered as the compose `command`, flags come from
  # the same set that was validated for this host (CPU inference, mmap weights).
  # The primary model (phi-4-mini) is the agents' brain.
  model_exec_args = concat(
    ["--model", "/models/${var.model_file}"],
    ["--alias", var.model_alias],
    ["--port", "8080"],
    ["--ctx-size", tostring(var.model_context_size)],
    ["--parallel", tostring(var.model_parallel_slots)],
    ["--n-gpu-layers", tostring(var.model_gpu_layers)],
    ["--cache-type-k", var.model_kv_cache_type],
    ["--cache-type-v", var.model_kv_cache_type],
    var.model_threads > 0 ? ["--threads", tostring(var.model_threads)] : [],
    var.model_api_key != "" ? ["--api-key", var.model_api_key] : [],
    ["--jinja", "--no-webui", "--metrics"],
  )

  # Secondary (fast) model: same flags, its own port/ctx/offload. Runs on CPU by
  # default so it never competes with the primary for VRAM.
  secondary_model_port = var.secondary_model_port
  secondary_exec_args = concat(
    ["--model", "/models/${var.secondary_model_file}"],
    ["--alias", var.secondary_model_alias],
    ["--port", "8080"],
    ["--ctx-size", tostring(var.secondary_model_context_size)],
    ["--parallel", tostring(var.secondary_model_parallel_slots)],
    ["--n-gpu-layers", tostring(var.secondary_model_gpu_layers)],
    ["--cache-type-k", var.secondary_model_kv_cache_type],
    ["--cache-type-v", var.secondary_model_kv_cache_type],
    var.model_threads > 0 ? ["--threads", tostring(var.model_threads)] : [],
    var.model_api_key != "" ? ["--api-key", var.model_api_key] : [],
    ["--jinja", "--no-webui", "--metrics"],
  )

  published_ports = var.secondary_model_enabled ? [
    var.model_port,
    var.secondary_model_port,
    var.postgres_port,
    ] : [
    var.model_port,
    var.postgres_port,
  ]

  # Ports the firewall is opened for when expose_public=true. The operator can
  # override expose_ports to include the other modules' services; empty means
  # "this module's own published ports".
  firewall_ports = length(var.expose_ports) > 0 ? var.expose_ports : local.published_ports

  # Ports the start_compose lifecycle waits on.
  model_ports = var.secondary_model_enabled ? [
    var.model_port,
    var.secondary_model_port,
  ] : [var.model_port]

  # CDI device (NVIDIA container toolkit). Podman resolves nvidia.com/gpu=all
  # from the generated spec; only attach it when GPU offload is requested so a
  # --n-gpu-layers 0 run stays pure CPU.
  model_gpu_devices           = var.model_gpu_layers > 0 ? ["nvidia.com/gpu=all"] : []
  secondary_model_gpu_devices = var.secondary_model_gpu_layers > 0 ? ["nvidia.com/gpu=all"] : []

  postgres_password = var.postgres_password != "" ? var.postgres_password : random_password.postgres[0].result
}

# --- podman storage ---------------------------------------------------------

# Global storage config: the Podman image/layer graph lives on the big volume.
resource "local_file" "storage_conf" {
  filename        = "${local.home}/.config/containers/storage.conf"
  file_permission = "0644"

  content = <<-EOT
    # Written by model-setup/terraform - moves the Podman image/layer graph onto
    # the large aigents volume.
    [storage]

    driver = "overlay"
    runroot = "${local.run_root}"
    graphroot = "${local.graph_root}"
  EOT
}

# --- credentials shared with the agent quadlets -----------------------------

resource "random_password" "postgres" {
  count = var.postgres_password == "" ? 1 : 0

  length  = 32
  special = false
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
    MODEL_URL=http://127.0.0.1:${local.model_port}
    MODEL_NAME=${var.model_alias}
    MODEL_FAST_URL=${var.secondary_model_enabled ? "http://127.0.0.1:${local.secondary_model_port}" : ""}
    MODEL_FAST_NAME=${var.secondary_model_enabled ? var.secondary_model_alias : ""}
    MODEL_API_KEY=${var.model_api_key}
  EOT
}

# --- database + AI model via podman compose ---------------------------------

# DB and model run as one podman-compose stack managed by OpenTofu. The
# testing agents are separate Quadlet units (agent-setup/).
resource "local_file" "compose_yaml" {
  filename        = local.compose_file
  file_permission = "0600" # contains the postgres password

  content = templatefile("${local.module_dir}/compose.yaml.tftpl", {
    postgres_image    = var.postgres_image
    postgres_db       = var.postgres_db
    postgres_user     = var.postgres_user
    postgres_password = local.postgres_password
    postgres_port     = var.postgres_port
    postgres_data_dir = local.postgres_data_dir
    initdb_dir        = local.initdb_dir
    bind_address      = var.bind_address

    model_image       = var.model_image
    model_dir         = local.model_dir
    model_repo        = var.model_repo
    model_file        = var.model_file
    model_sha256      = var.model_sha256
    model_port        = local.model_port
    model_exec_args   = local.model_exec_args
    model_gpu_devices = local.model_gpu_devices

    secondary_model_enabled     = var.secondary_model_enabled
    secondary_model_repo        = var.secondary_model_repo
    secondary_model_file        = var.secondary_model_file
    secondary_model_sha256      = var.secondary_model_sha256
    secondary_model_alias       = var.secondary_model_alias
    secondary_model_port        = local.secondary_model_port
    secondary_exec_args         = local.secondary_exec_args
    secondary_model_gpu_devices = local.secondary_model_gpu_devices

    hf_endpoint = var.hf_endpoint
    hf_token    = var.hf_token
    scripts_dir = local.scripts_dir
  })
}

resource "local_file" "initdb_schema" {
  filename = "${local.initdb_dir}/01-aigents-schema.sql"
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
    compose    = local.compose_dir
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -eux
      mkdir -p "${local.containers_dir}"
      mkdir -p "${local.graph_root}"
      mkdir -p "${local.run_root}"
      mkdir -p "${local.model_dir}"
      mkdir -p "${local.database_dir}"
      mkdir -p "${local.compose_dir}"
      mkdir -p "${local.initdb_dir}"
      mkdir -p "${local.secret_dir}"
      chmod 0755 "${local.scripts_dir}/fetch-gguf.sh"
      chmod 0700 "${local.secret_dir}"
    EOT
  }
}

resource "local_file" "network_online_dropin" {
  count = var.skip_network_online_wait ? 0 : 1

  filename        = "${local.home}/.config/systemd/user/podman-user-wait-network-online.service.d/aigents.conf"
  file_permission = "0644"

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
      command -v podman-compose || ${var.apt_command} apt-get install -y podman-compose
    EOT
  }
}

resource "null_resource" "open_firewall" {
  count = var.expose_public ? 1 : 0

  depends_on = [null_resource.install_podman]

  triggers = {
    ports        = join(",", local.firewall_ports)
    bind_address = var.bind_address
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -eux
      if [ "${var.bind_address}" != "0.0.0.0" ]; then
        echo "bind_address is ${var.bind_address}, not opening the firewall" >&2
        exit 0
      fi
      for p in ${join(" ", local.firewall_ports)}; do
        ${var.sudo_command} sh -c 'command -v iptables >/dev/null 2>&1 || exit 0
          iptables -C INPUT -p tcp --dport "$1" -j ACCEPT -m comment --comment aigents-model 2>/dev/null ||
            iptables -I INPUT -p tcp --dport "$1" -j ACCEPT -m comment --comment aigents-model' sh "$p"
      done
    EOT
  }
}

# --- lifecycle: fetch weights, start the compose stack ----------------------

resource "null_resource" "start_compose" {
  depends_on = [
    local_file.storage_conf,
    local_file.compose_yaml,
    local_file.initdb_schema,
    local_sensitive_file.credentials_env,
    local_file.network_online_dropin,
    null_resource.dirs,
    null_resource.install_podman,
    null_resource.open_firewall,
  ]

  triggers = {
    compose       = local_file.compose_yaml.content
    fetch_script  = filesha256("${local.scripts_dir}/fetch-gguf.sh")
    schema        = local_file.initdb_schema.content
    credentials   = sha256(local_sensitive_file.credentials_env.content)
    ports         = join(",", local.published_ports)
    service_state = var.service_state
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -eu
      export XDG_RUNTIME_DIR=/run/user/$(id -u)
      user=$(id -un)
      if [ "${var.service_state}" = "stopped" ]; then
        # stop model + database; volumes and GGUF weights are kept
        podman-compose -p aigents -f "${local.compose_file}" stop || true
        exit 0
      fi
      if [ "${var.enable_linger}" = "true" ]; then
        loginctl enable-linger "$user" || true
      fi

      # one-shot weight download (fetch-gguf.sh exits 0 when already present)
      podman-compose -p aigents -f "${local.compose_file}" --profile fetch run --rm model-fetch
${var.secondary_model_enabled ? "      podman-compose -p aigents -f \"${local.compose_file}\" --profile fetch run --rm model-fetch-secondary" : ""}

      # bring up postgres + the primary model + the secondary fast model
      podman-compose -p aigents -f "${local.compose_file}" up -d

      # the CLI-dedicated second instance (aigents-phi4-cli) and the original
      # phi-4-mini container (aigents-phi4) were retired; drop them when a
      # previous version of this stack left them running
      podman rm -f aigents-phi4-cli aigents-phi4 2>/dev/null || true

      # wait for each model API (weights can take minutes to mmap)
      for port in ${join(" ", local.model_ports)}; do
        echo "waiting for model on 127.0.0.1:$${port} ..."
        for i in $(seq 1 120); do
          curl -fsS "http://127.0.0.1:$${port}/health" && break
          sleep 5
        done
        echo "model 127.0.0.1:$${port} healthy"
      done
    EOT
  }
}