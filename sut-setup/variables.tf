variable "home_dir" {
  type        = string
  description = "Home directory of the user that runs the Podman user services."
  default     = "/home/vieta"
}

variable "bind_address" {
  type        = string
  description = "Host interface the pod binds published ports on. 0.0.0.0 exposes the services to the LAN, 127.0.0.1 keeps them localhost-only."
  default     = "0.0.0.0"
}

variable "nginx_image" {
  type    = string
  default = "docker.io/nginx:1.27-alpine"
}

variable "nginx_http_port" {
  type    = number
  default = 80
}

variable "nginx_config_dir" {
  type        = string
  description = "Host directory holding the nginx config mounted into the proxy container."
  default     = "~/.config/iacSUT/nginx"
}

variable "expose_public" {
  type        = bool
  description = "When true, opens the published ports in nftables so they are reachable from outside the host."
  default     = true
}

variable "quadlet_dir" {
  type        = string
  description = "Directory where Quadlet unit files are written."
  default     = "~/.config/containers/systemd"
}

variable "juice_shop_image" {
  type    = string
  default = "docker.io/bkimminich/juice-shop:latest"
}

variable "juice_shop_port" {
  type    = number
  default = 3000
}

variable "grafana_image" {
  type    = string
  default = "docker.io/grafana/grafana:11.5.0"
}

variable "grafana_port" {
  type    = number
  default = 3001
}

variable "grafana_admin_user" {
  type    = string
  default = "admin"
}

variable "grafana_admin_password" {
  type      = string
  sensitive = true
  default   = "admin"
}

variable "install_packages" {
  type        = list(string)
  description = "Packages installed via doas before starting services."
  default = [
    "podman",
    "slirp4netns",
    "fuse-overlayfs",
    "podman-docker",
  ]
}