# ---------------------------------------------------------------------------
# Host / storage layout
# ---------------------------------------------------------------------------

variable "home_dir" {
  type        = string
  description = "Home directory of the user that runs the Podman rootless user services."
  default     = "/home/vieta"
}

variable "spool_root" {
  type        = string
  description = "Base directory on the big aigents volume. Holds the broker's config, persistence and logs alongside the model-setup databases."
  default     = "/var/spool/aigents"
}

variable "quadlet_dir" {
  type        = string
  description = "Directory where Quadlet unit files are written."
  default     = "~/.config/containers/systemd"
}

variable "container_user_id" {
  type        = number
  description = "Host UID of the user running these rootless services. Under rootless podman, container root maps to this UID, which is why the broker can read 0600 host keys after User=0."
  default     = 1000
}

# ---------------------------------------------------------------------------
# Exposure
# ---------------------------------------------------------------------------

variable "bind_address" {
  type        = string
  description = "Host interface the pod binds published ports on. The Raspberry Pis connect over the LAN, so this must be 0.0.0.0 for them to reach the broker."
  default     = "0.0.0.0"
}

# ---------------------------------------------------------------------------
# Ports
# ---------------------------------------------------------------------------

variable "mqtt_port" {
  type        = number
  description = "Host port for plain MQTT. Must match pi-setup's broker_port."
  default     = 1883

  # sut-setup also defines a broker (EMQX) on 1883. Only one can hold the port.
  validation {
    condition     = var.mqtt_port != 1883 || !var.conflict_with_sut_setup_emqx
    error_message = "mqtt_port 1883 collides with sut-setup's EMQX broker. Set var.conflict_with_sut_setup_emqx = false if you are not applying sut-setup, or pick a different mqtt_port and set pi-setup's broker_port to match."
  }
}

variable "conflict_with_sut_setup_emqx" {
  type        = bool
  description = "Set true when sut-setup/ is also applied. It provisions EMQX on 1883, so this module's port must move. Ignored when mqtt_port is not 1883."
  default     = false
}

variable "mqtt_tls_port" {
  type        = number
  description = "Host port for MQTT over TLS. This is the port pi-setup should use (its broker_port, where 8883 is the conventional value)."
  default     = 8883
}

variable "mqtt_ws_port" {
  type        = number
  description = "Host port for MQTT over WebSockets, for browser dashboards. 0 disables the listener."
  default     = 9001
}

# ---------------------------------------------------------------------------
# TLS
# ---------------------------------------------------------------------------

variable "enable_tls" {
  type        = bool
  description = "Issue certificates and serve MQTT over TLS on mqtt_tls_port. The client certificates let a Pi authenticate without sending its password."
  default     = true
}

variable "require_client_certificate" {
  type        = bool
  description = "Refuse MQTT clients that present no certificate on the TLS port, and take the username from the certificate's common name. Turning this off still verifies a certificate when one is offered, but password authentication remains acceptable on the TLS port too."
  default     = true
}

variable "broker_hostname" {
  type        = string
  description = "Primary DNS name the broker's certificate is issued for. The Pis dial this name, and it must resolve to this host."
  default     = "adora.local"
}

variable "tls_extra_sans" {
  type        = list(string)
  description = "Additional DNS names or IP addresses to put in the server certificate's subjectAltName, for when the Pis reach the broker by a name or address that is not broker_hostname. The host's current IPv4 addresses are always included automatically, so a DHCP change only requires a re-apply if the certificate has to outlive it."
  default     = []
}

variable "force_reissue_certificates" {
  type        = bool
  description = "Mint a fresh CA and certificates on the next apply. Every client certificate signed by the old CA stops working, so this is for rotation rather than routine changes."
  default     = false
}

variable "local_monitor_port" {
  type        = number
  description = "Loopback-only port for host-local monitoring. Never published, and still subject to the ACL file, so clients on it can subscribe but not publish."
  default     = 1882
}

# ---------------------------------------------------------------------------
# Clients / credentials
# ---------------------------------------------------------------------------

variable "client_roles" {
  type = map(object({
    username = string
    # Suffix for the keys in mqtt.env. Must be a valid shell identifier
    # because the Pis source that file; Terraform has no upper().
    env = string
  }))

  description = <<-EOT
    One MQTT account per crewAI role. The map key is the role, the username is
    the broker login, and env is the key suffix in the generated credentials
    file. Usernames must match pi-setup's role directory names
    (pi1-e2e, pi2-pentester, pi3-manager), because pi-setup defaults
    mqtt_username to the role name.
  EOT

  default = {
    "pi1-e2e" = {
      username = "pi1-e2e"
      env      = "PI1_E2E"
    }
    "pi2-pentester" = {
      username = "pi2-pentester"
      env      = "PI2_PENTESTER"
    }
    "pi3-manager" = {
      username = "pi3-manager"
      env      = "PI3_MANAGER"
    }
  }

  validation {
    condition     = length(var.client_roles) > 0
    error_message = "client_roles must name at least one account."
  }

  validation {
    condition = alltrue([
      for k, v in var.client_roles :
      can(regex("^[A-Za-z_][A-Za-z0-9_]*$", v.env))
    ])
    error_message = "Each client_roles env suffix must be a valid shell identifier (letters, digits and underscore, not starting with a digit)."
  }

  validation {
    condition = alltrue([
      for k, v in var.client_roles :
      can(regex("^[A-Za-z0-9_.-]+$", v.username))
    ])
    error_message = "Each client_roles username may only contain letters, digits, underscore, dot and hyphen."
  }
}

variable "pipeline_acl" {
  type = map(object({
    read  = list(string)
    write = list(string)
  }))

  description = <<-EOT
    Per-role topic permissions. These mirror pi-setup's mqtt_topics locals, which
    derive each role's input, output and status topics. The defaults assume
    pi-setup's mqtt_topic_prefix stays "crew"; if you change that variable there,
    change these topics too or the workers will be silently denied.

    Roles absent from this map get no permissions and can connect but not
    exchange any message.
  EOT

  default = {
    # subscribes crew/start, publishes to the pentester, reports its own status
    "pi1-e2e" = {
      read  = ["crew/start"]
      write = ["crew/pentester/input", "crew/status/pi1-e2e"]
    }
    "pi2-pentester" = {
      read  = ["crew/pi2-pentester"]
      write = ["crew/manager/input", "crew/status/pi2-pentester"]
    }
    # produces the finished report
    "pi3-manager" = {
      read  = ["crew/pi3-manager"]
      write = ["crew/final", "crew/status/pi3-manager"]
    }
  }

  validation {
    condition = alltrue(flatten([
      for role, acl in var.pipeline_acl : [
        for t in concat(acl.read, acl.write) :
        can(regex("^[^#+][^\\x00]*$", t)) && t != ""
      ]
    ]))
    error_message = "ACL topics must be non-empty and must not start with # or + (a leading wildcard would grant access far beyond one role's place in the chain)."
  }
}

variable "enable_topic_acl" {
  type        = bool
  description = "Restrict each account to the topics in pipeline_acl. Turning this off lets any authenticated client read and write everything, including crew/final."
  default     = true
}

variable "enable_deep_healthcheck" {
  type        = bool
  description = "Probe an authenticated publish/subscribe round trip rather than just an open port. Costs one extra low-privilege account whose password is written to the config directory in plaintext."
  default     = true
}

variable "mosquitto_hash_algorithm" {
  type        = string
  description = "Password hashing scheme for the generated password file. sha512-pbkdf2 is the portable default; argon2id is faster to verify but needs more memory, which matters on a Raspberry Pi broker."
  default     = "sha512-pbkdf2"

  validation {
    condition     = contains(["sha512-pbkdf2", "argon2id"], var.mosquitto_hash_algorithm)
    error_message = "mosquitto_hash_algorithm must be sha512-pbkdf2 or argon2id."
  }
}

# ---------------------------------------------------------------------------
# Image / lifecycle
# ---------------------------------------------------------------------------

variable "mosquitto_image" {
  type        = string
  description = "Mosquitto broker image. Also used for the throwaway container that hashes passwords."
  default     = "docker.io/library/eclipse-mosquitto:2"
}

variable "image_pull_policy" {
  type        = string
  description = "Quadlet Pull= policy."
  default     = "missing"

  validation {
    condition     = contains(["always", "missing", "newer", "never"], var.image_pull_policy)
    error_message = "image_pull_policy must be one of always, missing, newer, never."
  }
}

variable "enable_linger" {
  type        = bool
  description = "Keep the user services running after logout so the broker survives SSH disconnects and stays up for the Pis."
  default     = true
}

variable "skip_network_online_wait" {
  type        = bool
  description = "Neutralise podman's podman-user-wait-network-online.service helper. Quadlet gates every unit on it and it polls the system network-online.target until that unit activates, which on some hosts never happens and stalls every container start for the full TimeoutStartSec (90s here). Disable on a host where the target does activate."
  default     = true
}