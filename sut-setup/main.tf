locals {
  expanded_quadlet_dir = var.quadlet_dir == "~/.config/containers/systemd" ? format("%s/.config/containers/systemd", var.home_dir) : var.quadlet_dir
  expanded_nginx_dir   = var.nginx_config_dir == "~/.config/iacSUT/nginx" ? format("%s/.config/iacSUT/nginx", var.home_dir) : var.nginx_config_dir
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
    }
  )
}

resource "local_file" "sut_pod_quadlet" {
  filename = "${local.expanded_quadlet_dir}/sut.pod"
  content = templatefile(
    "${path.module}/quadlet/sut.pod.tftpl",
    {
      bind_address    = var.bind_address
      nginx_http_port = var.nginx_http_port
      juice_shop_port = var.juice_shop_port
      grafana_port    = var.grafana_port
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
  content  = file("${path.module}/nginx/default.conf")
}

resource "null_resource" "install_podman" {
  provisioner "local-exec" {
    command = "doas apt-get install -y ${join(" ", var.install_packages)}"
  }
}

resource "null_resource" "open_firewall" {
  count = var.expose_public ? 1 : 0

  depends_on = [null_resource.install_podman]

  triggers = {
    ports = join(",", [
      var.nginx_http_port,
      var.juice_shop_port,
      var.grafana_port,
    ])
    bind_address = var.bind_address
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -eux
      for p in ${var.nginx_http_port} ${var.juice_shop_port} ${var.grafana_port}; do
        doas sh -c 'command -v iptables >/dev/null 2>&1 || exit 0
          iptables -C INPUT -p tcp --dport "$1" -j ACCEPT -m comment --comment security-sut 2>/dev/null ||
            iptables -I INPUT -p tcp --dport "$1" -j ACCEPT -m comment --comment security-sut' sh "$p"
      done
    EOT
  }
}

resource "null_resource" "start_services" {
  depends_on = [
    local_file.juice_shop_quadlet,
    local_file.grafana_quadlet,
    local_file.sut_pod_quadlet,
    local_file.nginx_proxy_quadlet,
    local_file.nginx_default_conf,
    null_resource.install_podman,
  ]

  triggers = {
    pod        = local_file.sut_pod_quadlet.content
    juice      = local_file.juice_shop_quadlet.content
    grafana    = local_file.grafana_quadlet.content
    nginx      = local_file.nginx_proxy_quadlet.content
    nginx_conf = local_file.nginx_default_conf.content
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -eux
      export XDG_RUNTIME_DIR=/run/user/$(id -u)
      user=$(id -un)
      wants=${var.home_dir}/.config/systemd/user/default.target.wants
      mkdir -p "$wants"
      for s in juice-shop grafana; do
        systemctl --user stop "$s.service" 2>/dev/null || true
      done
      ln -sf "$XDG_RUNTIME_DIR/systemd/generator/sut-pod.service" "$wants/"
      loginctl enable-linger "$user"
      systemctl --user daemon-reload
      systemctl --user restart sut-pod.service
    EOT
  }
}