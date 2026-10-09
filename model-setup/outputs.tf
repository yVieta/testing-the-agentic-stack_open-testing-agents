output "storage" {
  description = "Where each piece of state lives under the aigents volume."
  value = {
    podman_graph_root = local.graph_root
    podman_run_root   = local.run_root
    model_weights     = local.model_dir
    postgres_data     = local.postgres_data_dir
    generated_secrets = local.credential_file
  }
}

output "model" {
  description = "Model server identity and how to reach it."
  value = {
    alias      = var.model_alias
    repo       = var.model_repo
    file       = var.model_file
    url        = "http://${var.bind_address}:${local.model_port}/v1"
    health     = "http://${var.bind_address}:${local.model_port}/health"
    weights_at = local.model_file_path
    auth       = nonsensitive(var.model_api_key) == "" ? "disabled" : "bearer token required"
  }
}

output "postgres" {
  description = "PostgreSQL + pgvector endpoint."
  value = {
    host     = var.bind_address
    port     = var.postgres_port
    database = var.postgres_db
    user     = var.postgres_user
    password = "see ${local.credential_file} (mode 0600)"
  }
}

output "compose" {
  description = "The podman-compose stack managed by this root module."
  value = {
    file       = local.compose_file
    project    = "aigents"
    services   = var.secondary_model_enabled ? ["postgres", "phi-4-mini", "phi-mini-moe"] : ["postgres", "phi-4-mini"]
    fetch      = "model-fetch (+model-fetch-secondary when enabled; profile: fetch, one-shot weight downloads)"
    pull_iface = "podman-compose -f ${local.compose_file} pull"
    up         = "podman-compose -f ${local.compose_file} up -d"
    ps         = "podman-compose -f ${local.compose_file} ps"
  }
}

output "post_apply_steps" {
  description = "What still has to happen after apply."
  value = [
    "apply runs podman-compose (--profile fetch) run --rm model-fetch   # downloads ${var.model_file} (~2.5 GB, phi-4-mini) into ${local.model_dir}",
    "apply runs podman-compose up -d, then waits for each model health endpoint",
    "curl http://${var.bind_address}:${local.model_port}/health",
    "curl http://${var.bind_address}:${local.model_port}/v1/models",
    "curl http://${var.bind_address}:${var.secondary_model_port}/v1/models  # fast model (phi-mini-moe, when enabled)",
  ]
}

output "exposure" {
  description = "How the services are published on the host."
  value = {
    bind_address   = var.bind_address
    firewall_open  = var.expose_public ? "ports opened with iptables" : "not modified"
    reachable_from = var.bind_address == "0.0.0.0" ? "LAN + localhost" : "localhost only"
    ports = {
      model           = local.model_port
      model_secondary = var.secondary_model_port
      postgres        = var.postgres_port
    }
    firewall_ports = local.firewall_ports
  }
}

output "lan_matrix" {
  description = "Every port in the stack that a LAN device can connect to once the owning module binds 0.0.0.0 and the firewall is opened. Defaults shown; the SUT/Odysseus/MCP values come from their own modules (sut-setup, odysseus-setup, mcp-setup)."
  value = {
    "phi-4-mini OpenAI API (model-setup)"   = var.model_port
    "phi-mini-moe OpenAI API (model-setup)" = var.secondary_model_port
    "postgres (model-setup)"                = var.postgres_port
    "SUT nginx -> Juice Shop (sut-setup)"   = 8080
    "Juice Shop direct (sut-setup)"         = 3000
    "Grafana (sut-setup)"                   = 3001
    "Odysseus UI (odysseus-setup)"          = 7000
    "SearXNG (odysseus-setup)"              = 8888
    "ChromaDB (odysseus-setup)"             = 8100
    "ntfy (odysseus-setup)"                 = 8091
    "MCP bus (mcp-setup)"                   = 8765
  }
}