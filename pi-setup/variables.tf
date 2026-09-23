variable "role" {
  type        = string
  description = "Which crew role this Pi runs (maps to a compiled crew from .dhall/Manifest.dhall)."
  validation {
    condition     = contains(["pi1-e2e", "pi2-pentester", "pi3-manager"], var.role)
    error_message = "role must be one of pi1-e2e, pi2-pentester, pi3-manager."
  }
}

variable "pi_user" {
  type        = string
  description = "User the worker runs as (owner of the Nix profile, repo and user systemd units)."
  default     = "pi"
}

variable "home_dir" {
  type        = string
  description = "Home directory of the pi user."
  default     = "/home/pi"
}

variable "repo_url" {
  type        = string
  description = "Git URL of this repository. Empty copies the checked-out tree next to pi-setup/ (../) instead."
  default     = ""
}

variable "repo_subdir" {
  type        = string
  description = "Directory (below home_dir) where the repository is provisioned."
  default     = "dhallcrew"
}

variable "tools" {
  type        = list(string)
  description = "Agent tooling installed from nixpkgs into the user's Nix profile (no NixOS required)."
  default = [
    "gnumake",   # make (repackaged make)
    "git",
    "dhall",       # .dhall/ sources
    "dhall-json",  # dhall-to-json / json-to-dhall (used by `make`)
    "jq",
    "python3",     # venv + pip for the worker
    "mosquitto",   # mosquitto_pub / mosquitto_sub for triggering + debugging
    "terraform",   # configure host systems / this Pi
  ]
}

variable "extra_tools" {
  type        = list(string)
  description = "Extra nixpkgs packages for this role, e.g. [\"chromium\" \"playwright\" \"nodejs\"] on pi1-e2e."
  default     = []
}

variable "pip_packages" {
  type        = list(string)
  description = "Extra Python packages installed into the worker venv (crewai[tools]+paho-mqtt come from `pip install -e .`)."
  default     = []
}

# --- MQTT -------------------------------------------------------------------

variable "broker_host" {
  type        = string
  description = "MQTT broker host (EMQX on the host system, or the optional NixOS broker)."
  default     = "10.0.0.10"
}

variable "broker_port" {
  type        = number
  description = "MQTT broker port (1883 plaintext, 8883 TLS)."
  default     = 1883
}

variable "broker_username" {
  type        = string
  description = "MQTT username for this Pi. Defaults to the role name (pi1-e2e, pi2-pentester, pi3-manager) which matches the broker ACLs."
  default     = ""
}

variable "broker_password" {
  type        = string
  sensitive   = true
  description = "MQTT password for this Pi. Create the matching user on the broker (mqtt-broker.nix / EMQX) with the role's ACLs."
}

variable "mqtt_topic_prefix" {
  type        = string
  description = "Topic prefix used by the crew."
  default     = "crew"
}

variable "tls_ca_path" {
  type        = string
  description = "Optional path to the broker CA certificate on THIS machine; copied to the Pi and used when broker_port is TLS. Leave empty for a plaintext broker."
  default     = ""
}

variable "tls_require_cert" {
  type        = bool
  description = "Require a verified broker hostname/certificate when TLS is used."
  default     = true
}

# --- System under test ------------------------------------------------------

variable "target_url" {
  type        = string
  description = "The local web server under test, reachable from the Pi (usually the Terraform-deployed SUT)."
  default     = "http://10.0.0.20"
}