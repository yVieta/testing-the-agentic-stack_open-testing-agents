# Orchestration-level variables. Everything else keeps the defaults declared in
# each module's own variables.tf (the modules are the source of truth for their
# internal tuning; this root only exposes what an operator changes in practice).

variable "service_state" {
  type        = string
  description = "Desired state of the whole stack: 'running' converges/keeps every service up, 'stopped' disables+stops all services in reverse order. Toggle with `tofu apply -var service_state=stopped` (or `just down`)."
  default     = "running"

  validation {
    condition     = contains(["running", "stopped"], var.service_state)
    error_message = "service_state must be either \"running\" or \"stopped\"."
  }
}

variable "home_dir" {
  type        = string
  description = "Home dir of the user that runs the Podman/systemd user services. Leave empty (default) to resolve the real home of the user running tofu."
  default     = ""
}

variable "spool_root" {
  type        = string
  description = "Base directory on the big aigents volume (model weights, database, bus state, Odysseus)."
  default     = "/var/spool/aigents"
}

# --- the one system under test ------------------------------------------------

variable "target_url" {
  type        = string
  description = "The one system under test every agent is scoped to (OWASP Juice Shop behind the nginx proxy)."
  default     = "http://127.0.0.1:8080"
}

# --- model wiring -------------------------------------------------------------

variable "model_url" {
  type        = string
  description = "Primary LLM endpoint the agents use (llama.cpp phi-4-mini on 18080)."
  default     = "http://127.0.0.1:18080"
}

variable "model_name" {
  type        = string
  description = "Primary model alias served at model_url."
  default     = "phi-4-mini"
}

variable "model_fast_url" {
  type        = string
  description = "Fast secondary model endpoint (phi-mini-moe on 18081) used to condense shared findings. Empty = disabled (default)."
  default     = ""
}

variable "model_fast_name" {
  type        = string
  description = "Fast secondary model alias. Only used when model_fast_url is set."
  default     = "phi-mini-moe"
}

# --- MCP bus ------------------------------------------------------------------

variable "mcp_host" {
  type        = string
  description = "Interface the MCP bus binds (localhost-only by default; the agent containers reach it over host networking)."
  default     = "127.0.0.1"
}

variable "mcp_port" {
  type        = number
  description = "TCP port the MCP bus listens on."
  default     = 8765
}

variable "mcp_path" {
  type        = string
  description = "HTTP path of the MCP endpoint."
  default     = "/mcp"
}

# --- agents -------------------------------------------------------------------

variable "roles" {
  type        = map(string)
  description = "build/<role> directory -> agent name (matches .dhall/Manifest.dhall)."
  default = {
    e2e       = "e2e_test_agent"
    pentester = "pentester_agent"
    manager   = "test_manager_agent"
  }
}

variable "run_interval" {
  type        = number
  description = "Seconds each agent idles between crew runs. `just pace N` sets this; 900 is the quiet production default, 60 makes the team react within a minute."
  default     = 900
}

variable "build_agent_image" {
  type        = bool
  description = "Build the agent image from agent-setup/Containerfile on apply (else assume it exists)."
  default     = true
}

variable "build_app_image" {
  type        = bool
  description = "Build the Odysseus image from the local vendored source (../odysseus) instead of pulling upstream. Enables the aigents-bus and Lean 4 MCP servers."
  default     = false
}

variable "enable_on_boot" {
  type        = bool
  description = "Enable every service in the user's default.target so it starts automatically at boot/login. disabled (default): services are running now, started declaratively by `just deploy`."
  default     = false
}

variable "secondary_model_enabled" {
  type        = bool
  description = "Run the secondary fast model (Phi-mini-MoE) alongside the primary phi-4-mini. When false only the primary model is served and the worker's condense step is skipped."
  default     = false
}

# --- report mail (MCP bus mail function) -------------------------------------

variable "report_mail_to" {
  type        = string
  description = "Default recipient(s) of the test reports (comma-separated ok). Written into the MCP bus config as REPORT_MAIL_TO so the manager's report is mailed to these recipients. Empty -> the sender must pass a recipient explicitly."
  default     = ""
}

# --- SUT options --------------------------------------------------------------

variable "grafana_enabled" {
  type        = bool
  description = "Enable Grafana dashboard in the SUT pod."
  default     = false
}