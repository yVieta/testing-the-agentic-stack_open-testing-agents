# State & plan encryption at rest (OpenTofu >= 1.7).
#
# The state holds generated secrets (Postgres password, Odysseus admin
# password, model API key), so it is encrypted with PBKDF2 (key derivation,
# 600k rounds) + AES-GCM. The passphrase is deliberately NOT stored here: it is
# read from TF_VAR_state_passphrase, which the justfile exports from a 0600 file
# outside the repo (default /var/spool/aigents/.tofu-state-passphrase,
# auto-generated on first use). Back that file up — without it the state is
# unrecoverable.
#
# The default is empty so `tofu validate`/`fmt` work without a passphrase, but
# any real plan/apply fails closed: PBKDF2 rejects a passphrase shorter than 16
# characters rather than encrypting (or reading) with a weak key. `enforced`
# means OpenTofu refuses to read or write unencrypted state/plans, so a missing
# passphrase is an error instead of a silent downgrade to plaintext.

variable "state_passphrase" {
  type        = string
  description = "Passphrase (>= 16 chars) used to encrypt the OpenTofu state and plan files at rest (PBKDF2 + AES-GCM). Supplied via TF_VAR_state_passphrase; see README. Empty disables nothing — plan/apply then fail closed."
  default     = ""
  sensitive   = true
}

terraform {
  encryption {
    key_provider "pbkdf2" "state" {
      passphrase = var.state_passphrase
    }

    method "aes_gcm" "state" {
      keys = key_provider.pbkdf2.state
    }

    state {
      method   = method.aes_gcm.state
      enforced = true
    }

    plan {
      method   = method.aes_gcm.state
      enforced = true
    }
  }
}
