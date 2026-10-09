locals {
  # Home of the user running tofu (the rootless podman/systemd user). Empty
  # home_dir resolves the invoking user's real home, so no username is baked in.
  home                 = var.home_dir != "" ? var.home_dir : pathexpand("~")
  expanded_quadlet_dir = var.quadlet_dir == "~/.config/containers/systemd" ? format("%s/.config/containers/systemd", local.home) : var.quadlet_dir
  expanded_nginx_dir   = var.nginx_config_dir == "~/.config/iacSUT/nginx" ? format("%s/.config/iacSUT/nginx", local.home) : var.nginx_config_dir
}

resource "local_file" "juice_shop_quadlet" {
  filename = "${local.expanded_quadlet_dir}/juice-shop.container"
  content = templatefile(
    "${path.module}/quadlet/juice-shop.container.tftpl",
    {
      juice_shop_image = var.juice_shop_image
    }
  )
}

resource "local_file" "grafana_quadlet" {
  filename = "${local.expanded_quadlet_dir}/grafana.container"
  content = templatefile(
    "${path.module}/quadlet/grafana.container.tftpl",
    {
      grafana_image          = var.grafana_image
      grafana_admin_user     = var.grafana_admin_user
      grafana_admin_password = var.grafana_admin_password
      grafana_listen_port    = var.grafana_listen_port
    }
  )
}

resource "local_file" "sut_pod_quadlet" {
  filename = "${local.expanded_quadlet_dir}/sut.pod"
  content = templatefile(
    "${path.module}/quadlet/sut.pod.tftpl",
    {
      bind_address        = var.bind_address
      nginx_http_port     = var.nginx_http_port
      juice_shop_port     = var.juice_shop_port
      grafana_port        = var.grafana_port
      grafana_listen_port = var.grafana_listen_port
    }
  )
}

resource "local_file" "nginx_proxy_quadlet" {
  filename = "${local.expanded_quadlet_dir}/nginx-proxy.container"
  content = templatefile(
    "${path.module}/quadlet/nginx-proxy.container.tftpl",
    {
      nginx_image      = var.nginx_image
      nginx_config_dir = local.expanded_nginx_dir
    }
  )
}

resource "local_file" "nginx_default_conf" {
  filename = "${local.expanded_nginx_dir}/default.conf"
  content = templatefile(
    "${path.module}/nginx/default.conf.tftpl",
    {
      grafana_listen_port = var.grafana_listen_port
    }
  )
}

resource "null_resource" "start_services" {
  depends_on = [
    local_file.juice_shop_quadlet,
    local_file.grafana_quadlet,
    local_file.sut_pod_quadlet,
    local_file.nginx_proxy_quadlet,
    local_file.nginx_default_conf,
  ]

  triggers = {
    pod           = local_file.sut_pod_quadlet.content
    juice         = local_file.juice_shop_quadlet.content
    grafana       = local_file.grafana_quadlet.content
    nginx         = local_file.nginx_proxy_quadlet.content
    nginx_conf    = local_file.nginx_default_conf.content
    service_state = var.service_state
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -eux
      export XDG_RUNTIME_DIR=/run/user/$(id -u)
      user=$(id -un)
      wants=${local.home}/.config/systemd/user/default.target.wants
      mkdir -p "$wants"
      systemctl --user daemon-reload
      # Rootless user services only: no sudo, no firewall changes.
      if [ "${var.service_state}" = "stopped" ]; then
        for s in nginx-proxy juice-shop grafana sut-pod; do
          systemctl --user stop "$s.service" 2>/dev/null || true
        done
        systemctl --user disable sut-pod.service 2>/dev/null || true
        exit 0
      fi
      for s in juice-shop grafana nginx-proxy; do
        systemctl --user stop "$s.service" 2>/dev/null || true
      done
      if [ "${var.enable_on_boot}" = "true" ]; then
        ln -sf "$XDG_RUNTIME_DIR/systemd/generator/sut-pod.service" "$wants/"
      else
        rm -f "$wants/sut-pod.service"
      fi
      loginctl enable-linger "$user" 2>/dev/null || true
      systemctl --user restart sut-pod.service
    EOT
  }
}