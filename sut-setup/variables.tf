variable "home_dir" {
  type        = string
  description = "Home directory of the user that runs the Podman rootless user services. Leave empty (default) to resolve the real home of the user running tofu (pathexpand \"~\"), so storage paths are never hardcoded to a username; override with `-var home_dir=/home/x` when deploying through sudo or a dedicated service account."
  default     = ""
}

variable "bind_address" {
  type        = string
  description = "Host interface the pod binds published ports on. 127.0.0.1 keeps everything localhost-only (no LAN exposure, no root firewall needed)."
  default     = "127.0.0.1"
}

variable "nginx_image" {
  type    = string
  default = "docker.io/nginx:1.27-alpine"
}

variable "nginx_http_port" {
  type        = number
  description = "Host port for the nginx proxy. Must be >= 1024 for rootless Podman (only callable with root below 1024)."
  default     = 8080
}

variable "nginx_config_dir" {
  type        = string
  description = "Host directory holding the nginx config mounted into the proxy container."
  default     = "~/.config/iacSUT/nginx"
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
  type        = number
  description = "Host port for Juice Shop. The container keeps its default internal port 3000."
  default     = 3000
}

variable "grafana_image" {
  type    = string
  default = "docker.io/grafana/grafana:11.5.0"
}

variable "grafana_listen_port" {
  type        = number
  description = "Port Grafana listens on inside the pod. Must differ from Juice Shop's 3000 so the shared pod network namespace does not collide (issue #4)."
  default     = 3001
}

variable "grafana_port" {
  type        = number
  description = "Host port for Grafana."
  default     = 3001
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

variable "grafana_enabled" {
  type        = bool
  description = "Enable Grafana dashboard in the SUT pod."
  default     = false
}

variable "enable_on_boot" {
  type        = bool
  description = "Link the SUT pod into the user's default.target so it starts automatically at boot/login. Default false: the pod is started now but not linked, so start it explicitly (systemctl --user start sut-pod.service, or ./start-services.sh)."
  default     = false
}

variable "service_state" {
  type        = string
  description = "Desired state of the SUT services: 'running' starts the pod (linked for boot only when enable_on_boot=true), 'stopped' stops it and removes it from the user's default.target. Toggle with `tofu apply -var service_state=stopped` (re-run with 'running' to start again)."
  default     = "running"

  validation {
    condition     = contains(["running", "stopped"], var.service_state)
    error_message = "service_state must be either \"running\" or \"stopped\"."
  }
}