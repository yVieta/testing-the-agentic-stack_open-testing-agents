output "mcp" {
  description = "MCP knowledge/control bus: endpoint, state and the declarative seed file."
  value = {
    url       = module.mcp.mcp_url
    unit      = module.mcp.mcp_unit
    state_dir = module.mcp.state.dir
    db        = module.mcp.state.db
    seed_jobs = module.mcp.state.seed_file
    tools     = module.mcp.tools
  }
}

output "odysseus" {
  description = "Odysseus workspace and support services."
  value = {
    urls           = module.odysseus.service_urls
    services       = module.odysseus.services
    quadlet_files  = module.odysseus.quadlet_files
    model_wiring   = module.odysseus.model_wiring
    admin_ui_creds = "(see /var/spool/aigents/odysseus/secrets/credentials.env)"
  }
}

output "agents" {
  description = "Testing agents: one systemd user service per role."
  value = {
    services     = module.agents.services
    quadlets     = module.agents.agent_quadlets
    image        = module.agents.agent_image
    reach        = module.agents.reach
    run_interval = var.run_interval
  }
}

output "sut" {
  description = "System under test endpoints."
  value       = module.sut.service_urls
}

output "model" {
  description = "Model server identity and where PostgreSQL lives."
  value = {
    model    = module.model.model
    postgres = module.model.postgres
    storage  = module.model.storage
  }
}

output "services" {
  description = "Every systemd user service managed by this deployment, by module."
  value = {
    model    = module.model.compose
    sut      = module.sut.services
    mcp      = [module.mcp.mcp_unit]
    agents   = module.agents.services
    odysseus = module.odysseus.services
  }
}