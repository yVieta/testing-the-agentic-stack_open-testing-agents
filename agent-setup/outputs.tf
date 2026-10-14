output "agent_quadlets" {
  description = "Quadlet unit files written for the agents."
  value       = { for k, f in local_file.agent_quadlet : k => f.filename }
}

output "services" {
  description = "Systemd user services managed during apply."
  value       = [for role in sort(keys(var.roles)) : "agent-${role}.service"]
}

output "agent_images" {
  description = "Images the agent containers run: the shared base plus each per-role tool layer (built by this module)."
  value = {
    base  = local.base_image
    roles = local.role_image
  }
}

output "agent_tools" {
  description = "Declarative tool catalog per role (from tools.tf): the tools each role image installs and may execute."
  value = {
    for role, tools in local.role_tools : role => {
      tools        = sort(keys(tools))
      bins         = local.role_bins[role]
      capabilities = local.role_capabilities[role]
    }
  }
}

output "reach" {
  description = "How each agent reaches the model, db and SUT."
  value = {
    model      = var.model_url
    model_name = var.model_name
    postgres   = "127.0.0.1:15432 (via credentials.env)"
    target     = var.target_url
  }
}