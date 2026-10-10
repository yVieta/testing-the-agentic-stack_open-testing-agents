# deploy/ — the repo's single declarative controller.
#
# This root module composes every self-hosted service of the stack as one
# OpenTofu configuration, so the whole setup is brought up, converged and torn
# down with a single `tofu apply` (see `justfile`: `just deploy` / `just down`).
#
#   module.model    llama.cpp + PostgreSQL   (independent)
#   module.sut      Juice Shop + nginx       (independent)
#   module.mcp      MCP knowledge/control bus (independent)
#   module.agents   e2e / pentester / manager agents  (needs module.model)
#   module.odysseus workspace + chrome/ntfy/searxng    (needs module.model)
#
# Dependency waves fall out of OpenTofu's DAG: independent modules apply
# concurrently (-parallelism), and agents/odysseus only apply after the model —
# that is the declarative replacement for the old imperative start-services.sh.
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

  home_dir      = var.home_dir
  spool_root    = var.spool_root
  service_state = var.service_state
}

# --- system under test: Juice Shop behind the nginx proxy --------------------

module "sut" {
  source = "../sut-setup"

  home_dir      = var.home_dir
  service_state = var.service_state
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
  enable_on_boot    = var.enable_on_boot
  service_state     = var.service_state
}

# --- Odysseus workspace (UI, notes, documents, mail) --------------------------

module "odysseus" {
  source     = "../odysseus-setup"
  depends_on = [module.model]

  home_dir       = var.home_dir
  spool_root     = var.spool_root
  report_mail_to = var.report_mail_to
  enable_on_boot = var.enable_on_boot
  build_app_image = var.build_app_image
  service_state  = var.service_state
}