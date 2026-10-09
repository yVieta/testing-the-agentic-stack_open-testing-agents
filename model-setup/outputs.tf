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
    cli_url    = "http://${var.bind_address}:${local.model_cli_port}/v1"
    cli_health = "http://${var.bind_address}:${local.model_cli_port}/health"
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
    services   = ["postgres", "phi4"]
    fetch      = "model-fetch (profile: fetch, one-shot weight download)"
    pull_iface = "podman-compose -f ${local.compose_file} pull"
    up         = "podman-compose -f ${local.compose_file} up -d"
    ps         = "podman-compose -f ${local.compose_file} ps"
  }
}

output "post_apply_steps" {
  description = "What still has to happen after apply."
  value = [
    "apply runs podman-compose (--profile fetch) run --rm model-fetch   # downloads ${var.model_file} (~2.5 GB) into ${local.model_dir}",
    "apply runs podman-compose up -d, then waits for the model health endpoint",
    "curl http://${var.bind_address}:${local.model_port}/health",
    "curl http://${var.bind_address}:${local.model_port}/v1/models",
  ]
}

output "exposure" {
  description = "How the services are published on the host."
  value = {
    bind_address   = var.bind_address
    firewall_open  = var.expose_public ? "ports opened with iptables" : "not modified"
    reachable_from = var.bind_address == "0.0.0.0" ? "LAN + localhost" : "localhost only"
    ports = {
      model    = local.model_port
      postgres = var.postgres_port
    }
  }
}