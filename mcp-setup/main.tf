locals {
  # Home of the user running tofu (the rootless podman/systemd user). Empty
  # home_dir resolves the invoking user's real home, so no username is baked in.
  home                 = var.home_dir != "" ? var.home_dir : pathexpand("~")
  expanded_unit_dir    = var.unit_dir == "~/.config/systemd/user" ? format("%s/.config/systemd/user", local.home) : var.unit_dir
  repo_dir             = var.repo_dir != "" ? var.repo_dir : abspath("${path.module}/..")
  odysseus_secrets_dir = var.odysseus_secrets_dir != "" ? var.odysseus_secrets_dir : "${var.spool_root}/odysseus/secrets"
  state_dir            = "${var.spool_root}/mcp"
  db_path              = "${local.state_dir}/mcp.db"
  server               = "${local.repo_dir}/worker/mcp_server.py"
  mcp_url              = "http://${var.mcp_host}:${var.mcp_port}${var.mcp_path}"
}

# --- host directory for the SQLite bus state --------------------------------

resource "null_resource" "state_dir" {
  triggers = {
    dir = local.state_dir
  }

  provisioner "local-exec" {
    command = "mkdir -p \"${local.state_dir}\""
  }
}

# --- systemd user unit: the MCP bus runs on the host, not in a container ----

# Living on the host lets the bus drive the agents with `systemctl --user` and
# talk to Odysseus on 127.0.0.1 without publishing anything.
resource "local_file" "mcp_unit" {
  filename        = "${local.expanded_unit_dir}/${var.unit_name}"
  file_permission = "0644"

  content = <<-EOT
    # Written by mcp-setup/terraform - the aigents MCP knowledge/control bus.
    [Unit]
    Description=aigents MCP knowledge + control bus
    After=network-online.target
    Wants=network-online.target

    [Service]
    Type=simple
    Environment=PYTHONUNBUFFERED=1
    Environment=MCP_HOST=${var.mcp_host}
    Environment=MCP_PORT=${var.mcp_port}
    Environment=TARGET_URL=${var.target_url}
    Environment=MCP_UNIT_PREFIX=${var.unit_prefix}
    Environment=REPORT_MAIL_TO=${var.report_mail_to}
    Environment=ODYSSEUS_SECRETS=${local.odysseus_secrets_dir}/credentials.env
    ExecStart=${var.python_bin} ${local.server} --host ${var.mcp_host} --port ${var.mcp_port} --db ${local.db_path} --odysseus-secrets ${local.odysseus_secrets_dir}/credentials.env --unit-prefix ${var.unit_prefix}
    Restart=on-failure
    RestartSec=5

    [Install]
    WantedBy=default.target
  EOT
}

# --- lifecycle --------------------------------------------------------------

resource "null_resource" "start_bus" {
  depends_on = [
    local_file.mcp_unit,
    null_resource.state_dir,
  ]

  triggers = {
    unit          = local_file.mcp_unit.content
    server        = filesha256(local.server)
    service_state = var.service_state
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -eu
      export XDG_RUNTIME_DIR=/run/user/$(id -u)
      user=$(id -un)
      systemctl --user daemon-reload
      if [ "${var.service_state}" = "stopped" ]; then
        systemctl --user disable --now "${var.unit_name}" 2>/dev/null || true
        exit 0
      fi
      if [ "${var.enable_linger}" = "true" ]; then
        loginctl enable-linger "$user" || true
      fi
      if [ "${var.enable_on_boot}" = "true" ]; then
        systemctl --user enable "${var.unit_name}" 2>/dev/null || true
      fi
      systemctl --user restart "${var.unit_name}" 2>/dev/null || true
    EOT
  }
}
