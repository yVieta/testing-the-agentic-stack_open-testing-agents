variable "home_dir" {
  type        = string
  description = "Home dir of the user that runs the Podman rootless user services. Leave empty (default) to resolve the real home of the user running tofu (pathexpand \"~\"), so storage paths are never hardcoded to a username; override with `-var home_dir=/home/x` when deploying through sudo or a dedicated service account."
  default     = ""
}

variable "spool_root" {
  type        = string
  description = "Base directory on the big aigents volume (model, database, workspaces)."
  default     = "/var/spool/aigents"
}

variable "quadlet_dir" {
  type        = string
  description = "Dir where Quadlet unit files are written."
  default     = "~/.config/containers/systemd"
}

variable "bind_address" {
  type        = string
  description = "Host interface the Odysseus UI is published on. 127.0.0.1 keeps it localhost-only."
  default     = "127.0.0.1"
}

# --- images -----------------------------------------------------------------

variable "app_image" {
  type        = string
  description = "Odysseus workspace image (published by CI on every push to main/dev)."
  default     = "ghcr.io/odysseus-dev/odysseus:latest"
}

variable "chromadb_image" {
  type        = string
  description = "Vector store used for document memory/embeddings."
  default     = "docker.io/chromadb/chroma:latest"
}

variable "searxng_image" {
  type        = string
  description = "Metasearch engine. Pinned like upstream: broken latest tags fail the app boot (issue #1414)."
  default     = "docker.io/searxng/searxng:2026.9.25-12f8b6515@sha256:5286edb35782454ab8a102c5eff6b54bff745853191b46aeead95f225aa6dfb6"
}

variable "ntfy_image" {
  type        = string
  description = "Notification/interest-topic push server."
  default     = "docker.io/binwiederhier/ntfy"
}

# --- ports ------------------------------------------------------------------

variable "app_port" {
  type        = number
  description = "Port of the Odysseus web UI. The app runs with host networking and its uvicorn CMD binds 0.0.0.0:7000, so this stays 7000 (no port publish)."
  default     = 7000
}

variable "chromadb_port" {
  type        = number
  description = "Host port of the ChromaDB admin/API."
  default     = 8100
}

variable "searxng_port" {
  type        = number
  description = "Host port of SearXNG. Defaults to 8888 because the SUT nginx already takes 8080."
  default     = 8888
}

variable "ntfy_port" {
  type        = number
  description = "Host port of the ntfy push server."
  default     = 8091
}

# --- model wiring ------------------------------------------------------------

variable "llm_host" {
  type        = string
  description = "Primary LLM host Odysseus scans for model discovery. Since the model stack now runs a single phi-4-mini on 18080 (crews + interactive chat), everything points at it. The app runs with host networking, so 127.0.0.1 is the host."
  default     = "127.0.0.1:18080"
}

variable "llm_hosts" {
  type        = string
  description = "Additional comma-separated LLM hosts. The single phi-4-mini is on `llm_host`; this stays the same value because the app scans both env vars — harmless duplicate, set to \"\" if your build tolerates an empty secondary."
  default     = "127.0.0.1:18080"
}

variable "research_llm_endpoint" {
  type        = string
  description = "Explicit OpenAI-compatible endpoint for the research model (the single phi-4-mini)."
  default     = "http://127.0.0.1:18080/v1"
}

variable "embedding_endpoint" {
  type        = string
  description = "OpenAI-compatible embeddings URL. Empty -> built-in fastembed (all-MiniLM) is used."
  default     = ""
}

# --- auth / identity ----------------------------------------------------------

variable "admin_user" {
  type        = string
  description = "Odysseus initial admin account name (created on first boot)."
  default     = "admin"
}

variable "admin_password" {
  type        = string
  sensitive   = true
  description = "Initial admin password. Empty -> a random one is generated and written to secrets/credentials.env."
  default     = ""
}

variable "auth_enabled" {
  type        = bool
  description = "Require login to use the workspace."
  default     = true
}

variable "localhost_bypass" {
  type        = bool
  description = "Skip authentication for requests that look like localhost."
  default     = false
}

variable "puid" {
  type        = number
  description = "UID the Odysseus container drops to (entrypoint also chowns /app/data + /app/logs)."
  default     = 1000
}

variable "pgid" {
  type        = number
  description = "GID the Odysseus container drops to."
  default     = 1000
}

# --- lifecycle ----------------------------------------------------------------

variable "enable_linger" {
  type        = bool
  description = "Keep user services running after logout."
  default     = true
}

variable "service_state" {
  type        = string
  description = "Desired state of the Odysseus quadlet services: 'running' enables+starts them, 'stopped' disables+stops them. Toggle with `tofu apply -var service_state=stopped` (re-run with 'running' to start again)."
  default     = "running"

  validation {
    condition     = contains(["running", "stopped"], var.service_state)
    error_message = "service_state must be either \"running\" or \"stopped\"."
  }
}