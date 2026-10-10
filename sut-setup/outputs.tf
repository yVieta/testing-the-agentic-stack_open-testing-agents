output "quadlet_files" {
  description = "Quadlet unit files managed by Terraform."
  value = {
    juice_shop  = local_file.juice_shop_quadlet.filename
    grafana     = var.grafana_enabled ? local_file.grafana_quadlet[0].filename : null
    sut_pod     = local_file.sut_pod_quadlet.filename
    nginx_proxy = local_file.nginx_proxy_quadlet.filename
  }
}

output "services" {
  description = "Systemd user services and pod managed during apply."
  value = concat([
    "sut-pod.service",
    "juice-shop.service",
    "nginx-proxy.service",
  ], var.grafana_enabled ? ["grafana.service"] : [])
}

output "service_urls" {
  description = "Endpoints exposed on localhost (via nginx proxy where applicable)."
  value = {
    nginx_proxy       = "http://localhost:${var.nginx_http_port} (default -> Juice Shop)"
    grafana_via_nginx = var.grafana_enabled ? "curl -H 'Host: grafana.sut' http://localhost:${var.nginx_http_port}" : null
    juice_shop        = "http://localhost:${var.juice_shop_port}"
    grafana           = var.grafana_enabled ? "http://localhost:${var.grafana_port}" : null
  }
}

output "exposure" {
  description = "How the services are published on the host."
  value = {
    bind_address   = var.bind_address
    reachable_from = var.bind_address == "0.0.0.0" ? "LAN + localhost" : "localhost only"
    note           = "rootless user services; no iptables/root access required"
  }
}