output "agent_quadlets" {
  description = "Quadlet unit files written for the agents."
  value       = { for k, f in local_file.agent_quadlet : k => f.filename }
}

output "services" {
  description = "Systemd user services managed during apply."
  value       = [for role in sort(keys(var.roles)) : "agent-${role}.service"]
}

output "agent_image" {
  description = "Image the agent containers run (built by this module)."
  value       = var.agent_image
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