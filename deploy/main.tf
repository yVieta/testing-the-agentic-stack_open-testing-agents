# deploy/ — the repo's single declarative controller.
#
# This root module composes every self-hosted service of the stack as one
# OpenTofu configuration, so the whole setup is brought up, converged and torn
# down with a single `tofu apply` (see `justfile`: `just deploy` / `just down`).
#
#   module.model     llama.cpp + PostgreSQL          (independent)
#   module.sut       Juice Shop + nginx              (independent)
#   module.mcp       MCP knowledge/control bus       (independent)
#   module.agents    e2e / pentester / manager agents (needs module.model)
#   module.odysseus  Workspace + chrome/ntfy/searxng  (needs module.model)
#
# Dependency waves fall out of OpenTofu's DAG: independent modules apply
# concurrently (-parallelism), and agents/odysseus only apply after the model.
# This root module is the single controller — drive the lifecycle through it
# (`just start` / `just stop` / `just redeploy`) and never apply a `*-setup/`
# module directly, which would fork the state. The old imperative
# start-services.sh has been removed.
# Each module still owns its quadlet/systemd units and all runtime state; this
# root only wires shared values and the desired `service_state`.
#
# Each module's `service_state` fans out from here. `running` converges the
# units and restarts a unit exactly when its rendered content changed;
# `stopped` disables+stops all services in reverse order.

locals {
  repo_dir = abspath("${path.module}/..")
  mcp_url  = "http://${var.mcp_host}:${var.mcp_port}${var.mcp_path}"
}

# --- model stack: llama.cpp (primary + fast) and PostgreSQL ------------------

module "model" {
  source = "../model-setup"

  home_dir                = var.home_dir
  spool_root              = var.spool_root
  service_state           = var.service_state
  secondary_model_enabled = var.secondary_model_enabled
  enable_linger           = var.enable_linger
}

# --- system under test: Juice Shop behind the nginx proxy --------------------

module "sut" {
  source = "../sut-setup"

  home_dir        = var.home_dir
  service_state   = var.service_state
  grafana_enabled = var.grafana_enabled
  enable_on_boot  = var.enable_on_boot
}

# --- MCP knowledge/control bus ------------------------------------------------
# The one SUT all agents are scoped to and the report recipient are declared
# here; the module renders the seeds/tasks.json initial job queue from them.

module "mcp" {
  source = "../mcp-setup"

  home_dir       = var.home_dir
  spool_root     = var.spool_root
  repo_dir       = local.repo_dir
  target_url     = var.target_url
  report_mail_to = var.report_mail_to
  service_state  = var.service_state
  enable_on_boot = var.enable_on_boot
  enable_linger  = var.enable_linger
}

# --- testing agents -----------------------------------------------------------
# One systemd user service per role, wired to the shared model + bus + SUT.

module "agents" {
  source     = "../agent-setup"
  depends_on = [module.model]

  home_dir          = var.home_dir
  spool_root        = var.spool_root
  repo_dir          = local.repo_dir
  target_url        = var.target_url
  model_url         = var.model_url
  model_name        = var.model_name
  model_fast_url    = var.model_fast_url
  model_fast_name   = var.model_fast_name
  mcp_url           = local.mcp_url
  run_interval      = var.run_interval
  roles             = var.roles
  build_agent_image = var.build_agent_image
  tools_overrides   = var.tools_overrides
  enable_on_boot    = var.enable_on_boot
  enable_linger     = var.enable_linger
  service_state     = var.service_state
}

# --- Odysseus workspace (UI, notes, documents, mail) --------------------------

module "odysseus" {
  source     = "../odysseus-setup"
  depends_on = [module.model]

  home_dir        = var.home_dir
  spool_root      = var.spool_root
  report_mail_to  = var.report_mail_to
  enable_on_boot  = var.enable_on_boot
  enable_linger   = var.enable_linger
  build_app_image = var.build_app_image
  service_state   = var.service_state
}

# --- user-manager linger ------------------------------------------------------
# `enable_on_boot` decides whether units start at boot; linger decides whether
# the systemd *user manager* (and any running units) survives logout. Reconcile
# it once here instead of in each module: default off means `just stop` /
# `just shutdown` also turn lingering off, so nothing is left running after the
# operator logs out. Enable together with enable_on_boot for an unattended host.
resource "null_resource" "linger" {
  triggers = {
    enable_linger = var.enable_linger
  }

  provisioner "local-exec" {
    command = <<-EOT
      if [ "${var.enable_linger}" = "true" ]; then
        loginctl enable-linger "$(id -un)" || true
      else
        loginctl disable-linger "$(id -un)" || true
      fi
    EOT
  }
}