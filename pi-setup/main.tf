locals {
  # role directory (pi1-e2e) -> agent role name used by worker.py / PIPELINE.
  agent_roles = {
    "pi1-e2e"       = "e2e_test_agent"
    "pi2-pentester" = "pentester_agent"
    "pi3-manager"   = "test_manager_agent"
  }

  agent_role = local.agent_roles[var.role]

  repo_dir   = "${var.home_dir}/${var.repo_subdir}"
  nix_rc     = "${var.home_dir}/.nix-profile/etc/profile.d/nix.sh"
  cert_dir   = "${var.home_dir}/.config/dhallcrew"
  cert_file  = var.tls_ca_path != "" ? "${local.cert_dir}/ca.crt" : ""

  worker_dir = "${local.repo_dir}/build/${var.role}"
  venv_dir   = "${local.repo_dir}/.venv"

  tools     = distinct(concat(var.tools, var.extra_tools))
  tool_list = join(" ", local.tools)

  mqtt_username = var.broker_username != "" ? var.broker_username : var.role

  # MQTT topics this Pi publishes/subscribes to (crew/start, crew/.../input,
  # crew/status/<role>).
  mqtt_topics = {
    input  = "${var.mqtt_topic_prefix}/${var.role == "pi1-e2e" ? "start" : var.role}"
    output = "${var.mqtt_topic_prefix}/${local.agent_role == "e2e_test_agent" ? "pentester/input" : (local.agent_role == "pentester_agent" ? "manager/input" : "final")}"
    status = "${var.mqtt_topic_prefix}/status/${var.role}"
  }
}

# --- dirs + Nix -------------------------------------------------------------

resource "null_resource" "prepare_dirs" {
  provisioner "local-exec" {
    command = <<-EOT
      set -eux
      mkdir -p "${var.home_dir}/.config/dhallcrew"
      mkdir -p "${var.home_dir}/.config/systemd/user"
    EOT
  }
}

resource "null_resource" "install_nix" {
  depends_on = [null_resource.prepare_dirs]

  provisioner "local-exec" {
    # Single-user Nix (no root daemon), the documented way to get nixpkgs
    # tooling on Raspberry Pi OS without being on NixOS.
    command = <<-EOT
      set -eux
      if [ -f "${local.nix_rc}" ]; then
        . "${local.nix_rc}"
      fi
      if ! command -v nix >/dev/null 2>&1; then
        curl -fsSL https://nixos.org/nix/install.sh | sh -- --no-daemon
      fi
      . "${local.nix_rc}"
      nix --version
    EOT
  }
}

resource "null_resource" "install_tools" {
  depends_on = [null_resource.install_nix]

  provisioner "local-exec" {
    # Agent tools from nixpkgs, installed idempotently into the user profile.
    command = <<-EOT
      set -eux
      . "${local.nix_rc}"
      for p in ${local.tool_list}; do
        nix profile list 2>/dev/null | grep -q "nixpkgs#${p}\b" \
          || nix profile install "nixpkgs#${p}"
      done
      dhall --version | head -1
      dhall-to-json --version | head -1
      terraform version | head -1
    EOT
  }
}

# --- repo + build -----------------------------------------------------------

resource "null_resource" "sync_repo" {
  depends_on = [null_resource.install_tools]

  provisioner "local-exec" {
    command = <<-EOT
      set -eux
      if [ -d "${local.repo_dir}/.git" ]; then
        git -C "${local.repo_dir}" pull --ff-only
      elif [ -n "${var.repo_url}" ]; then
        git clone "${var.repo_url}" "${local.repo_dir}"
      else
        # Fall back to the checkout this pi-setup/ lives in.
        if [ ! -f ../Makefile ]; then
          echo "no repo_url and ../ has no Makefile" >&2
          exit 1
        fi
        mkdir -p "${local.repo_dir}"
        cp -a ../. "${local.repo_dir}/"
        rm -rf "${local.repo_dir}/.git"
      fi
      cd "${local.repo_dir}"
      test -f Makefile && test -f worker/worker.py
    EOT
  }
}

resource "null_resource" "build_worker" {
  depends_on = [null_resource.sync_repo, null_resource.install_tools]

  provisioner "local-exec" {
    # Compile the Dhall crews (needs dhall-json + jq) and prepare the venv
    # with crewai[tools] + paho-mqtt.
    command = <<-EOT
      set -eux
      . "${local.nix_rc}"
      cd "${local.repo_dir}"
      make
      if [ ! -x "${local.venv_dir}/bin/python" ]; then
        python3 -m venv "${local.venv_dir}"
      fi
      "${local.venv_dir}/bin/pip" install --upgrade pip
      "${local.venv_dir}/bin/pip" install -e . ${join(" ", var.pip_packages)}
      test -f "build/${var.role}/crew.json"
    EOT
  }
}

# --- worker .env (MQTT + target config) -------------------------------------

resource "local_file" "worker_env" {
  depends_on = [null_resource.build_worker, null_resource.prepare_dirs]

  filename = "${local.worker_dir}/.env"
  content = templatefile(
    "${path.module}/env.tftpl",
    {
      role            = var.role
      agent_role      = local.agent_role
      topic_prefix    = var.mqtt_topic_prefix
      broker_host     = var.broker_host
      broker_port     = var.broker_port
      broker_username = local.mqtt_username
      broker_password = var.broker_password
      tls_ca          = local.cert_file
      tls_require_cert = var.tls_require_cert
      target_url      = var.target_url
    }
  )
}

resource "local_file" "mqtt_ca" {
  count = var.tls_ca_path != "" ? 1 : 0

  depends_on = [null_resource.prepare_dirs]

  filename = local.cert_file
  content  = file(var.tls_ca_path)
}

resource "local_file" "mqtt_client_config" {
  depends_on = [local_file.worker_env]

  filename = "${local.cert_dir}/mosquitto.conf"
  content = templatefile(
    "${path.module}/mosquitto.conf.tftpl",
    {
      broker_host     = var.broker_host
      broker_port     = var.broker_port
      broker_username = local.mqtt_username
      broker_password = var.broker_password
      tls_ca          = local.cert_file
      tls_require_cert = var.tls_require_cert
    }
  )
}

# --- systemd user service ---------------------------------------------------

resource "local_file" "worker_service" {
  depends_on = [local_file.worker_env]

  filename = "${var.home_dir}/.config/systemd/user/crew-worker.service"
  content = templatefile(
    "${path.module}/crew-worker.service.tftpl",
    {
      role    = var.role
      worker_dir = local.worker_dir
      repo_dir   = local.repo_dir
      venv_dir   = local.venv_dir
    }
  )
}

resource "null_resource" "start_worker" {
  depends_on = [
    local_file.worker_service,
    local_file.mqtt_ca,
    null_resource.build_worker,
  ]

  triggers = {
    unit  = local_file.worker_service.content
    env   = local_file.worker_env.content
    ca    = var.tls_ca_path != "" ? file(var.tls_ca_path) : ""
    tools = local.tool_list
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -eux
      systemctl --user daemon-reload
      loginctl enable-linger ${var.pi_user} || sudo loginctl enable-linger ${var.pi_user}
      systemctl --user enable --now crew-worker.service
      systemctl --user --no-pager status crew-worker.service --no-legend || true
    EOT
  }
}