output "storage" {
  description = "Where each piece of state lives under the aigents volume."
  value = {
    podman_graph_root = local.graph_root
    podman_run_root   = local.run_root
    model_weights     = local.model_dir
    postgres_data     = local.postgres_data_dir
    qdrant_data       = local.qdrant_data_dir
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

output "qdrant" {
  description = "Qdrant endpoints."
  value = {
    http    = "http://${var.bind_address}:${var.qdrant_http_port}"
    grpc    = "${var.bind_address}:${var.qdrant_grpc_port}"
    api_key = "see ${local.credential_file} (mode 0600)"
  }
}

output "services" {
  description = "Systemd user services and the pod managed during apply."
  value = [
    "${local.pod_unit}",
    "postgres.service",
    "qdrant.service",
    "phi-4.service",
    "model-fetch.service",
  ]
}

output "quadlet_files" {
  description = "Quadlet unit files managed by Terraform."
  value = {
    pod          = local_file.pod.filename
    postgres     = local_file.postgres_quadlet.filename
    qdrant       = local_file.qdrant_quadlet.filename
    phi4         = local_file.phi4_quadlet.filename
    model_fetch  = local_file.model_fetch_quadlet.filename
    storage_conf = local_file.storage_conf.filename
  }
}

output "post_apply_steps" {
  description = "What still has to happen after apply."
  value = [
    "systemctl --user start model-fetch.service   # downloads ${var.model_file} (~8.5 GB) into ${local.model_dir}",
    "systemctl --user start phi-4.service    # first start mmaps the weights, expect several minutes",
    "curl http://${var.bind_address}:${local.model_port}/health",
    "curl http://${var.bind_address}:${local.model_port}/v1/models",
  ]
}

output "mcp" {
  description = "MCP endpoint the crewAI workers connect to for model access."
  value = {
    enabled  = var.enable_mcp_server
    url      = local.mcp_url
    bind     = var.mcp_bind_address
    port     = var.mcp_port
    token    = "see ${local.credential_file} (mode 0600)"
    tools    = ["phi4_chat", "phi4_complete", "phi4_info"]
    services = var.enable_mcp_server ? ["aigents-mcp.service"] : []
  }
}

output "exposure" {
  description = "How the services are published on the host."
  value = {
    bind_address   = var.bind_address
    firewall_open  = var.expose_public ? "ports opened with iptables" : "not modified"
    reachable_from = var.bind_address == "0.0.0.0" ? "LAN + localhost" : "localhost only"
    ports = {
      model       = local.model_port
      postgres    = var.postgres_port
      qdrant_http = var.qdrant_http_port
      qdrant_grpc = var.qdrant_grpc_port
    }
  }
}