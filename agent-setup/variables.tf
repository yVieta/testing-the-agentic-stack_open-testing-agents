variable "home_dir" {
  type        = string
  description = "Home dir of user that runs the Podman rootless user services. Leave empty (default) to resolve the real home of the user running tofu (pathexpand \"~\"), so storage paths are never hardcoded to a username; override with `-var home_dir=/home/x` when deploying through sudo or a dedicated service account."
  default     = ""
}

variable "spool_root" {
  type        = string
  description = "Base directory on the big aigents volume (container graph, model, database)."
  default     = "/var/spool/aigents"
}

variable "repo_dir" {
  type        = string
  description = "Repo root mounted into the agent containers (/repo). Defaults to the checkout that contains this module."
  default     = ""
}

variable "quadlet_dir" {
  type        = string
  description = "Dir where Quadlet unit files are written."
  default     = "~/.config/containers/systemd"
}

variable "model_url" {
  type        = string
  description = "Base URL of the local model server (worker appends /v1)."
  default     = "http://127.0.0.1:18080"
}

variable "model_name" {
  type        = string
  description = "Model name as served by llama-server --alias."
  default     = "phi-4-mini"
}

variable "target_url" {
  type        = string
  description = "System under test the agents exercise: the OWASP Juice Shop behind the nginx proxy of the rootless SUT on 127.0.0.1."
  default     = "http://127.0.0.1:8080"
}

variable "agent_image" {
  type        = string
  description = "Image tag for the agent container (built from this module's Containerfile)."
  default     = "localhost/aigents-agent"
}

variable "build_agent_image" {
  type        = bool
  description = "Build localhost/aigents-agent with podman during apply (pulls crewai + lean toolchain)."
  default     = true
}

variable "credential_file" {
  type        = string
  description = "credentials.env written by model-setup; mounted into each agent."
  default     = ""
}

variable "odysseus_secrets_dir" {
  type        = string
  description = "Directory holding Odysseus' credentials.env (written by odysseus-setup). Mounted read-only into each agent so the e2e worker can publish generated Playwright code to the Odysseus document library. Defaults to <spool_root>/odysseus/secrets."
  default     = ""
}

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
  description = "Seconds the worker idles between crew runs."
  default     = 900
}

variable "enable_linger" {
  type        = bool
  description = "Keep user services running after logout."
  default     = true
}

variable "service_state" {
  type        = string
  description = "Desired state of the agent quadlet services: 'running' enables+starts them, 'stopped' disables+stops them. Toggle with `tofu apply -var service_state=stopped` (re-run with 'running' to start again)."
  default     = "running"

  validation {
    condition     = contains(["running", "stopped"], var.service_state)
    error_message = "service_state must be either \"running\" or \"stopped\"."
  }
}