output "broker" {
  description = "MQTT endpoints the Raspberry Pis connect to."
  value = {
    mqtt    = "${var.bind_address}:${var.mqtt_port}"
    websock = var.mqtt_ws_port > 0 ? "${var.bind_address}:${var.mqtt_ws_port}" : null
    # Loopback only, never published, and still ACL-constrained.
    monitor = "127.0.0.1:${var.local_monitor_port}"
  }
}

output "security" {
  description = "How the broker authenticates and authorises clients."
  value = {
    anonymous_published_port = false
    password_required        = true
    topic_acls               = var.enable_topic_acl ? "per role, see pipeline_acl" : "DISABLED: every authenticated client may read and write every topic"
    hash_algorithm           = var.mosquitto_hash_algorithm
    note                     = "crew/final carries the finished pentest report, so unauthenticated or un-ACL'd publish access to it is a report-forgery path."
  }
}

output "topics" {
  description = "Effective per-role topics, for cross-checking against pi-setup's mqtt_topics."
  value = {
    for role, c in local.clients : role => {
      read  = c.acl.read
      write = c.acl.write
    }
  }
}

output "clients" {
  description = "Per-role MQTT accounts. Passwords are in the credentials file, not here."
  value = {
    for role, c in local.clients : role => {
      username = c.username
      env_key  = "MQTT_PASSWORD_${c.env}"
    }
  }
}

output "credentials_file" {
  description = "Where the plaintext MQTT passwords were written (mode 0600)."
  value       = local.credential_file
}

output "services" {
  description = "Systemd user services managed here."
  value       = [local.pod_unit, "mqtt-broker.service"]
}

output "storage" {
  description = "Where the broker keeps its configuration and persistent messages."
  value = {
    config      = local.config_dir
    data        = local.data_dir
    credentials = local.credential_file
  }
}

output "pi_setup_vars" {
  description = "Ready-made pi-setup arguments. The broker address is left as a hostname on purpose: the Pis get theirs over DHCP, while this host also answers to its mDNS name."
  value = {
    broker_host     = "adora.local"
    broker_port     = var.mqtt_port
    note            = "pi-setup's own broker_host default is 10.0.0.10, which is not this host; pass -var 'broker_host=adora.local'. Confirm the mDNS name resolves from a Pi first."
    password_source = "pass the value of MQTT_PASSWORD_<ROLE> from ${local.credential_file} as -var 'broker_password=...' on that Pi"
  }
}

output "post_apply_steps" {
  description = "What the Raspberry Pis need next."
  value = [
    "Credentials are in ${local.credential_file} (mode 0600).",
    "On each Pi, in pi-setup/terraform.tfvars, set broker_host and broker_password:",
    "  broker_host     = \"adora.local\"",
    "  broker_password = \"<MQTT_PASSWORD_* from the file above>\"",
    "broker_username may be left empty: pi-setup already defaults it to the role name.",
    "Then on the Pi: cd pi-setup && tofu init && tofu apply",
    "Smoke test from any machine on the LAN:",
    "  mosquitto_sub -h adora.local -p ${var.mqtt_port} -u pi1-e2e -P <password> -t 'crew/#' -v",
    "Trigger the pipeline:",
    "  mosquitto_pub -h adora.local -p ${var.mqtt_port} -u pi1-e2e -P <password> -t crew/start -m go",
  ]
}
