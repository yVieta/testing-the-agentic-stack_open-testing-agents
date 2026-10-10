output "mcp_url" {
  description = "MCP endpoint the agents and the tm CLI connect to."
  value       = local.mcp_url
}

output "mcp_unit" {
  description = "Systemd user unit running the bus."
  value       = local_file.mcp_unit.filename
}

output "state" {
  description = "Where the SQLite bus state and the declarative job seed live."
  value = {
    dir       = local.state_dir
    db        = local.db_path
    seed_file = local.seed_file
  }
}

output "tools" {
  description = "MCP tools exposed by the bus."
  value = [
    "assign_test_case", "list_tasks", "get_next_task", "submit_findings",
    "get_findings", "get_agent_status", "start_agent", "stop_agent",
    "publish_process", "get_process",
  ]
}

output "sut" {
  description = "The one system under test all agents are scoped to."
  value       = var.target_url
}
