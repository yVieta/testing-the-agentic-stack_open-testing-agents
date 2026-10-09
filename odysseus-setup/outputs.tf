output "quadlet_files" {
  description = "Quadlet unit files managed by Terraform."
  value = {
    app      = local_file.app_quadlet.filename
    chromadb = local_file.chromadb_quadlet.filename
    searxng  = local_file.searxng_quadlet.filename
    ntfy     = local_file.ntfy_quadlet.filename
  }
}

output "services" {
  description = "Systemd user services managed during apply."
  value       = [for s in local.services : "${s}.service"]
}

output "service_urls" {
  description = "Endpoints exposed on localhost."
  value = {
    odysseus = "http://localhost:${var.app_port}"
    chromadb = "http://localhost:${var.chromadb_port}"
    searxng  = "http://localhost:${var.searxng_port}"
    ntfy     = "http://localhost:${var.ntfy_port}"
  }
}

output "model_wiring" {
  description = "How Odysseus reaches the local phi-4-mini instances."
  value = {
    primary       = var.llm_host
    secondary     = var.llm_hosts
    research_base = var.research_llm_endpoint
    embedding     = var.embedding_endpoint == "" ? "built-in fastembed (all-MiniLM-L6-v2)" : var.embedding_endpoint
    note          = "app runs with Network=host and talks to the models on the loopback"
  }
}

output "admin_credentials" {
  description = "First-boot login (also written to secrets/credentials.env)."
  sensitive   = true
  value = {
    user     = var.admin_user
    password = local.admin_password
  }
}