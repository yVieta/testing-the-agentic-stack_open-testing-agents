locals {
  # Home of the user running tofu (the rootless podman/systemd user). Empty
  # home_dir resolves the invoking user's real home, so no username is baked in.
  home                 = var.home_dir != "" ? var.home_dir : pathexpand("~")
  expanded_quadlet_dir = var.quadlet_dir == "~/.config/containers/systemd" ? format("%s/.config/containers/systemd", local.home) : var.quadlet_dir
  repo_dir             = var.repo_dir != "" ? var.repo_dir : abspath("${path.module}/..")
  credential_file      = var.credential_file != "" ? var.credential_file : "${var.spool_root}/database/secrets/credentials.env"
  # Results directory for test artifacts (Playwright screenshots, reports, etc.)
  results_dir          = var.results_dir != "" ? var.results_dir : "${var.spool_root}/results"
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
    harness_lib   = filesha256("${local.repo_dir}/skills/lean/AgentHarness.lean")
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

# --- host directories -------------------------------------------------------

# --- host directories -------------------------------------------------------
# The credentials dir is written by model-setup (llama.cpp + PostgreSQL).
# It is mounted read-only into each agent so the worker can access model
# configuration (e.g. API keys, report settings).
# The file is created by model-setup; here we just ensure it exists.
resource "null_resource" "ensure_credentials_env" {
  triggers = {
    file = local.credential_file
  }

  provisioner "local-exec" {
    command = "mkdir -p \"$(dirname ${local.credential_file})\" && [ -e ${local.credential_file} ] || : > ${local.credential_file}"
  }
}

# Results directory for test artifacts (screenshots, reports, etc.)
resource "null_resource" "ensure_results_dir" {
  triggers = {
    dir = local.results_dir
  }

  provisioner "local-exec" {
    command = "mkdir -p \"${local.results_dir}/e2e\" \"${local.results_dir}/pentester\" \"${local.results_dir}/manager\""
  }
}

# --- quadlet units: one systemd user service per role -----------------------

resource "local_file" "agent_quadlet" {
  for_each = var.roles

  filename = "${local.expanded_quadlet_dir}/agent-${each.key}.container"
  content = templatefile("${path.module}/quadlet/agent.container.tftpl", {
    repo_dir             = local.repo_dir
    image                = var.agent_image
    role_dir             = each.key   # build/<role>
    agent_role           = each.value # manifest agent name
    model_url            = var.model_url
    model_name           = var.model_name
    model_fast_url       = var.model_fast_url
    model_fast_name      = var.model_fast_name
    target_url           = var.target_url
    mcp_url              = var.mcp_url
    run_interval         = var.run_interval
    credential_file      = local.credential_file
    results_dir          = local.results_dir
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
    # A rebuilt image or worker script is only picked up by a restarted unit;
    # include their hashes so `tofu apply` converges the running agents too.
    image       = filesha256("${path.module}/Containerfile")
    harness     = filesha256("${local.repo_dir}/skills/lean/Main.lean")
    harness_lib = filesha256("${local.repo_dir}/skills/lean/AgentHarness.lean")
    worker      = filesha256("${local.repo_dir}/worker/run_agent.py")
    mcp_bus     = filesha256("${local.repo_dir}/worker/mcp_bus.py")
    crew_tool   = filesha256("${local.repo_dir}/worker/crew_tools/aigents_bus.py")
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -eu
      export XDG_RUNTIME_DIR=/run/user/$(id -u)
      user=$(id -un)
      systemctl --user daemon-reload
      # The podman user generator adds Wants=podman-user-wait-network-online
      # to every container unit. That one-shot polls the system-level
      # network-online.target, which never comes up on this host, so every
      # `systemctl start/restart agent-*` queues behind it and times out.
      # The whole stack is loopback, so mask it: Wants on a masked unit are
      # satisfied as inactive and start jobs complete immediately.
      systemctl --user mask podman-user-wait-network-online.service 2>/dev/null || true
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
        if [ "${var.enable_on_boot}" = "true" ]; then
          systemctl --user enable "agent-$${role}.service" 2>/dev/null || true
        fi
        systemctl --user restart "agent-$${role}.service" 2>/dev/null || true
      done
    EOT
  }
}