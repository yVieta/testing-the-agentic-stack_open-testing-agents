variable "home_dir" {
  type        = string
  description = "Home dir of the user that runs the systemd user services. Leave empty (default) to resolve the real home of the user running tofu (pathexpand \"~\")."
  default     = ""
}

variable "spool_root" {
  type        = string
  description = "Base directory on the big aigents volume. The bus keeps its SQLite state under <spool_root>/mcp."
  default     = "/var/spool/aigents"
}

variable "repo_dir" {
  type        = string
  description = "Repo root that holds worker/mcp_server.py. Defaults to the checkout that contains this module."
  default     = ""
}

variable "unit_dir" {
  type        = string
  description = "Dir where the systemd *user* unit file is written."
  default     = "~/.config/systemd/user"
}

variable "unit_name" {
  type        = string
  description = "Systemd user service name for the bus."
  default     = "aigents-mcp.service"
}

variable "mcp_host" {
  type        = string
  description = "Interface the MCP bus binds. 127.0.0.1 keeps it localhost-only (host networking, so the agent containers reach it there too)."
  default     = "127.0.0.1"
}

variable "mcp_port" {
  type        = number
  description = "TCP port the MCP bus listens on (POST /mcp)."
  default     = 8765
}

variable "mcp_path" {
  type        = string
  description = "HTTP path of the MCP endpoint."
  default     = "/mcp"
}

variable "target_url" {
  type        = string
  description = "The one system under test every agent is scoped to (OWASP Juice Shop behind the nginx proxy)."
  default     = "http://127.0.0.1:8080"
}

variable "report_mail_to" {
  type        = string
  description = "Default recipient of the test reports mailed through the Odysseus mail function (mail_report). Empty -> fall back to REPORT_MAIL_TO in the odysseus credentials.env."
  default     = ""
}

variable "unit_prefix" {
  type        = string
  description = "Prefix of the agent systemd user units the bus starts/stops (agent-<role>.service)."
  default     = "agent-"
}

variable "odysseus_secrets_dir" {
  type        = string
  description = "Directory holding Odysseus' credentials.env, used to publish the testing-process document. Defaults to <spool_root>/odysseus/secrets."
  default     = ""
}

variable "python_bin" {
  type        = string
  description = "Interpreter that runs the (stdlib-only) bus. /usr/bin/env python3 tracks the active python3 without hardcoding its path."
  default     = "/usr/bin/env python3"
}

variable "enable_linger" {
  type        = bool
  description = "Keep user services running after logout."
  default     = true
}

variable "enable_on_boot" {
  type        = bool
  description = "Enable the bus unit in the user's default.target so it starts automatically at boot/login. Default false: start it explicitly (systemctl --user start aigents-mcp.service, or ./start-services.sh)."
  default     = false
}

variable "service_state" {
  type        = string
  description = "Desired state of the bus: 'running' starts it (enabled for boot only when enable_on_boot=true), 'stopped' disables+stops it. Toggle with `tofu apply -var service_state=stopped`."
  default     = "running"

  validation {
    condition     = contains(["running", "stopped"], var.service_state)
    error_message = "service_state must be either \"running\" or \"stopped\"."
  }
}
