locals {
  expanded_quadlet_dir = var.quadlet_dir == "~/.config/containers/systemd" ? format("%s/.config/containers/systemd", var.home_dir) : var.quadlet_dir
  repo_dir             = var.repo_dir != "" ? var.repo_dir : abspath("${path.module}/..")
  credential_file      = var.credential_file != "" ? var.credential_file : "${var.spool_root}/database/secrets/credentials.env"
}

# --- agent image ------------------------------------------------------------

# One image for all agents: python + crewai + psycopg + lean4 (elan) with the
# formal harness pre-built. Build context is the repo root so skills/lean and
# worker/ can be baked into /opt/harness.
resource "null_resource" "build_agent_image" {
  count = var.build_agent_image ? 1 : 0

  triggers = {
    containerfile = filesha256("${path.module}/Containerfile")
    harness       = filesha256("${local.repo_dir}/skills/lean/Main.lean")
    worker        = filesha256("${local.repo_dir}/worker/run_agent.py")
    lakefile      = filesha256("${local.repo_dir}/skills/lean/lakefile.toml")
  }

  provisioner "local-exec" {
    command = <<-EOT
      export XDG_RUNTIME_DIR=/run/user/$(id -u)
      podman build -f "${path.module}/Containerfile" -t "${var.agent_image}" "${local.repo_dir}"
    EOT
  }
}

# --- quadlet units: one systemd user service per role -----------------------

resource "local_file" "agent_quadlet" {
  for_each = var.roles

  filename = "${local.expanded_quadlet_dir}/agent-${each.key}.container"
  content = templatefile("${path.module}/quadlet/agent.container.tftpl", {
    repo_dir        = local.repo_dir
    image           = var.agent_image
    role_dir        = each.key   # build/<role>
    agent_role      = each.value # manifest agent name
    model_url       = var.model_url
    model_name      = var.model_name
    target_url      = var.target_url
    credential_file = local.credential_file
  })
}

# --- lifecycle --------------------------------------------------------------

resource "null_resource" "start_agents" {
  depends_on = [
    local_file.agent_quadlet,
    null_resource.build_agent_image,
  ]

  triggers = {
    units         = join("", [for f in local_file.agent_quadlet : f.content])
    service_state = var.service_state
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -eu
      export XDG_RUNTIME_DIR=/run/user/$(id -u)
      user=$(id -un)
      systemctl --user daemon-reload
      if [ "${var.service_state}" = "stopped" ]; then
        for role in ${join(" ", sort(keys(var.roles)))}; do
          systemctl --user disable --now "agent-$${role}.service" 2>/dev/null || true
        done
        exit 0
      fi
      if [ "${var.enable_linger}" = "true" ]; then
        loginctl enable-linger "$user" || true
      fi
      for role in ${join(" ", sort(keys(var.roles)))}; do
        systemctl --user enable --now "agent-$${role}.service" 2>/dev/null || true
      done
    EOT
  }
}