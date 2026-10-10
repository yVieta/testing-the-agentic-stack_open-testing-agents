locals {
  # Home of the user running tofu (the rootless podman/systemd user). Empty
  # home_dir resolves the invoking user's real home, so no username is baked in.
  home                 = var.home_dir != "" ? var.home_dir : pathexpand("~")
  expanded_quadlet_dir = var.quadlet_dir == "~/.config/containers/systemd" ? format("%s/.config/containers/systemd", local.home) : var.quadlet_dir
  odysseus_dir         = "${var.spool_root}/odysseus"
  searxng_settings_dir = "${local.odysseus_dir}/searxng"
  services             = ["odysseus-searxng", "odysseus-chromadb", "odysseus-ntfy", "odysseus-app"]
}

# --- generated secrets --------------------------------------------------------

# Always generated; only used when the operator did not pin one themselves.
# NOTE: the charset must avoid '%' — in a systemd unit file '%' starts a
# specifier ('%m' -> machine-id), so a '%' in the value would silently mangle
# the password the container actually sees.
resource "random_password" "admin_password" {
  length           = 24
  special          = true
  override_special = "_-+@."
  keepers = {
    gen = "2"
  }
}

resource "random_password" "searxng_secret" {
  length  = 64
  special = false
}

# --- local odysseus image build ------------------------------------------------
# When build_app_image=true, build the image from the repo's vendored odysseus/
# source (which includes the aigents-bus MCP server for test manager integration).
# This makes the entire stack repo-owned and declarative.

locals {
  # External odysseus repo (cloned separately as a sibling of this repo)
  # Use relative path from odysseus-setup: ../../odysseus -> /var/spool/aigents/odysseus
  odysseus_source_dir = "${path.root}/../../odysseus"
  use_local_image     = var.build_app_image
  effective_app_image = var.build_app_image ? var.app_image_tag : var.app_image
}

resource "null_resource" "build_app_image" {
  # Only run when build_app_image=true
  count = var.build_app_image ? 1 : 0

  triggers = {
    # Rebuild when source files change (key files that affect the build)
    dockerfile   = filesha256("${local.odysseus_source_dir}/Dockerfile")
    entrypoint   = filesha256("${local.odysseus_source_dir}/docker/entrypoint.sh")
    app_py       = filesha256("${local.odysseus_source_dir}/app.py")
    builtin_mcp  = filesha256("${local.odysseus_source_dir}/src/builtin_mcp.py")
    aigents_bus  = filesha256("${local.odysseus_source_dir}/mcp_servers/aigents_bus_server.py")
    requirements = filesha256("${local.odysseus_source_dir}/requirements.txt")
    pyproject    = filesha256("${local.odysseus_source_dir}/pyproject.toml")
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -eu
      echo "Building Odysseus image from ${local.odysseus_source_dir} -> ${var.app_image_tag}"
      export XDG_RUNTIME_DIR=/run/user/$(id -u)
      podman build \
        --tag "${var.app_image_tag}" \
        --file "${local.odysseus_source_dir}/Dockerfile" \
        "${local.odysseus_source_dir}"
      echo "Build complete: ${var.app_image_tag}"
    EOT
  }
}

locals {
  admin_password = var.admin_password != "" ? var.admin_password : random_password.admin_password.result
}

# --- declarative workspace seed ----------------------------------------------
# Odysseus keeps model endpoints and character presets in its own DB, so on a
# fresh deployment they would otherwise have to be clicked in by hand. The
# `configure_odysseus` step below replays them through the app's HTTP API once
# the UI is healthy, keeping the whole stack reproducible from `tofu apply`.

locals {
  # The model stack serves two llama.cpp instances: the primary phi-4-mini on
  # 18080 (crews + interactive chat) and the fast phi-mini-moe on 18081. The
  # app uses host networking, so these are plain loopback URLs.
  llm_hosts_value = var.llm_hosts != "" ? var.llm_hosts : (
    var.llm_fast_host != "" ? "${var.llm_host},${var.llm_fast_host}" : var.llm_host
  )

  seed_endpoints = concat([
    { name = "phi-4-mini (llama.cpp)", base_url = "http://${var.llm_host}/v1" },
    ], var.llm_fast_host != "" ? [
    { name = "phi-mini-moe (llama.cpp) (fast)", base_url = "http://${var.llm_fast_host}/v1" },
  ] : [])

  # Prefer the compiled Dhall persona so the UI character matches the CLI/crew
  # agent. `build/` is generated (`nix develop -c just`); fall back to a short
  # inline prompt on a checkout that has not compiled yet.
  compiled_persona = fileexists("${path.root}/../build/agents/test_manager_agent.json") ? jsondecode(file("${path.root}/../build/agents/test_manager_agent.json")) : null

  test_manager_name = "Test Manager"
  test_manager_prompt = local.compiled_persona != null ? join("\n\n", [
    "You are the ${local.compiled_persona.role}: ${local.compiled_persona.backstory}.",
    local.compiled_persona.goal,
    "Prefer taking action with the available tools over describing what you would do, and keep the final consolidated report in clear markdown.",
  ]) : "You are the test manager: coordinate and review all testing activities, track the e2e and pentester agents (each role writes previous_output.md for the next one), and produce a final consolidated report of end-to-end and security test results."
}

# --- host directories ---------------------------------------------------------

resource "null_resource" "odysseus_dirs" {
  triggers = {
    dir = local.odysseus_dir
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -eu
      mkdir -p "${local.odysseus_dir}"/data/ssh
      mkdir -p "${local.odysseus_dir}"/data/huggingface
      mkdir -p "${local.odysseus_dir}"/data/local
      mkdir -p "${local.odysseus_dir}"/logs
      mkdir -p "${local.searxng_settings_dir}"
      mkdir -p "${local.odysseus_dir}"/secrets
      chmod 0700 "${local.odysseus_dir}"/secrets
    EOT
  }
}

# --- rendered config ----------------------------------------------------------

resource "local_file" "searxng_settings" {
  filename        = "${local.searxng_settings_dir}/settings.yml"
  file_permission = "0640"

  content = templatefile("${path.module}/searxng/settings.yml.tftpl", {
    searxng_secret = random_password.searxng_secret.result
  })
}

resource "local_sensitive_file" "credentials_env" {
  filename        = "${local.odysseus_dir}/secrets/credentials.env"
  file_permission = "0600"

  content = <<-EOT
    # Written by odysseus-setup/terraform. Print for the first-boot UI login.
    ODYSSEUS_ADMIN_USER="${var.admin_user}"
    ODYSSEUS_ADMIN_PASSWORD="${local.admin_password}"
    ODYSSEUS_URL="http://${var.bind_address}:${var.app_port}"
    LLM_PRIMARY="${var.llm_host}"
    LLM_SECONDARY="${local.llm_hosts_value}"
    RESEARCH_LLM_ENDPOINT="${var.research_llm_endpoint}"
    # Recipient of the test-report mail (Odysseus mail function); read by the
    # MCP bus / agents / tm CLI. Empty -> mail_report needs an explicit `to`.
    REPORT_MAIL_TO="${var.report_mail_to}"
  EOT
}

# Rendered config consumed by scripts/configure_odysseus.py. It carries no
# secret: the admin password is read from credentials.env at run time.
resource "local_file" "seed" {
  filename        = "${local.odysseus_dir}/seed.json"
  file_permission = "0600"

  content = jsonencode({
    base_url         = "http://${var.bind_address}:${var.app_port}"
    admin_user       = var.admin_user
    credentials_file = "${local.odysseus_dir}/secrets/credentials.env"
    preset_name      = local.test_manager_name
    preset_prompt    = local.test_manager_prompt
    endpoints        = local.seed_endpoints
  })
}

# --- quadlet units: one systemd user service per container -------------------

resource "local_file" "app_quadlet" {
  filename = "${local.expanded_quadlet_dir}/odysseus-app.container"

  content = templatefile("${path.module}/quadlet/odysseus-app.container.tftpl", {
    app_image             = local.effective_app_image
    bind_address          = var.bind_address
    app_port              = var.app_port
    odysseus_dir          = local.odysseus_dir
    llm_host              = var.llm_host
    llm_hosts             = local.llm_hosts_value
    research_llm_endpoint = var.research_llm_endpoint
    searxng_port          = var.searxng_port
    chromadb_port         = var.chromadb_port
    auth_enabled          = var.auth_enabled
    localhost_bypass      = var.localhost_bypass
    admin_user            = var.admin_user
    admin_password        = local.admin_password
    puid                  = var.puid
    pgid                  = var.pgid
    smtp_host             = var.smtp_host
    smtp_port             = var.smtp_port
    smtp_security         = var.smtp_security
    smtp_user             = var.smtp_user
    smtp_password         = var.smtp_password
    imap_host             = var.imap_host
    imap_port             = var.imap_port
    imap_user             = var.imap_user
    imap_password         = var.imap_password
    email_from            = var.email_from
  })
}

# Self-healing drop-in for the app unit: recreates every host-backed volume
# source on each `systemd --user start/restart`, so a cleanup or manual
# restart cannot wedge the service (podman refuses to start on a missing
# bind source). Rendered next to the quadlet file.
resource "local_file" "app_quadlet_dropin" {
  filename = "${local.expanded_quadlet_dir}/odysseus-app.container.d/override.conf"

  content = templatefile("${path.module}/quadlet/odysseus-app.container.d/override.conf.tftpl", {
    odysseus_dir = local.odysseus_dir
  })
}

resource "local_file" "chromadb_quadlet" {
  filename = "${local.expanded_quadlet_dir}/odysseus-chromadb.container"

  content = templatefile("${path.module}/quadlet/odysseus-chromadb.container.tftpl", {
    chromadb_image = var.chromadb_image
    bind_address   = var.bind_address
    chromadb_port  = var.chromadb_port
  })
}

resource "local_file" "searxng_quadlet" {
  filename = "${local.expanded_quadlet_dir}/odysseus-searxng.container"

  content = templatefile("${path.module}/quadlet/odysseus-searxng.container.tftpl", {
    searxng_image        = var.searxng_image
    bind_address         = var.bind_address
    searxng_port         = var.searxng_port
    searxng_settings_dir = local.searxng_settings_dir
  })
}

resource "local_file" "ntfy_quadlet" {
  filename = "${local.expanded_quadlet_dir}/odysseus-ntfy.container"

  content = templatefile("${path.module}/quadlet/odysseus-ntfy.container.tftpl", {
    ntfy_image   = var.ntfy_image
    bind_address = var.bind_address
    ntfy_port    = var.ntfy_port
  })
}

# Track admin password hash to detect changes and force re-initialization
resource "local_file" "admin_password_hash" {
  filename = "${local.odysseus_dir}/.admin_password_hash"
  content  = sha256(local.admin_password)
}

# Clean up Odysseus data when admin password changes to force re-initialization
# Also pre-create auth.json with the correct password hash so the app uses our password
resource "null_resource" "reinit_odysseus_on_password_change" {
  depends_on = [local_sensitive_file.credentials_env, local_file.admin_password_hash]

  triggers = {
    password_hash = local_file.admin_password_hash.content
    service_state = var.service_state
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -eu
      if [ "${var.service_state}" = "stopped" ]; then
        exit 0
      fi
      echo "Admin password changed, removing Odysseus data to force re-initialization..."
      rm -rf "${local.odysseus_dir}/data" "${local.odysseus_dir}/logs" 2>/dev/null || true
      mkdir -p "${local.odysseus_dir}/data" "${local.odysseus_dir}/logs" "${local.odysseus_dir}/services/cache/search"

      # Pre-create auth.json with the correct password hash so the app uses our password
      ADMIN_PASSWORD="${local.admin_password}"
      # Generate bcrypt hash using Python
      PASSWORD_HASH=$(python3 -c "
import bcrypt, sys
pwd = sys.argv[1].encode()
hash = bcrypt.hashpw(pwd, bcrypt.gensalt(rounds=12))
print(hash.decode())
" "\$ADMIN_PASSWORD")
      mkdir -p "${local.odysseus_dir}/data"
      cat > "${local.odysseus_dir}/data/auth.json" <<EOF
{
  "users": {
    "admin": {
      "password_hash": "\$PASSWORD_HASH",
      "is_admin": true
    }
  }
}
EOF
      chmod 600 "${local.odysseus_dir}/data/auth.json"
      echo "Pre-created auth.json with correct password hash"
    EOT
  }
}

# --- lifecycle ----------------------------------------------------------------

resource "null_resource" "start_odysseus" {
  depends_on = [
    local_file.app_quadlet,
    local_file.app_quadlet_dropin,
    local_file.chromadb_quadlet,
    local_file.searxng_quadlet,
    local_file.ntfy_quadlet,
    local_file.searxng_settings,
    local_sensitive_file.credentials_env,
    null_resource.odysseus_dirs,
    null_resource.reinit_odysseus_on_password_change,
  ]

  triggers = {
    units         = "${local_file.app_quadlet.content}${local_file.chromadb_quadlet.content}${local_file.searxng_quadlet.content}${local_file.ntfy_quadlet.content}"
    settings      = local_file.searxng_settings.content
    service_state = var.service_state
    password_hash = local_file.admin_password_hash.content
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -eu
      export XDG_RUNTIME_DIR=/run/user/$(id -u)
      user=$(id -un)
      if [ "${var.service_state}" = "stopped" ]; then
        ${join("\n", [for s in local.services : "        systemctl --user disable --now ${s}.service 2>/dev/null || true"])}
        exit 0
      fi
      if [ "${var.enable_linger}" = "true" ]; then
        loginctl enable-linger "$user" || true
      fi
      # Only pull images that aren't locally built (localhost/* tags)
      ${join("\n", [for img in [local.effective_app_image, var.chromadb_image, var.searxng_image, var.ntfy_image] : "        case ${img} in\n          localhost/*) echo \"Using local image ${img}, skipping pull\" ;;\n          *) podman image exists ${img} 2>/dev/null || podman pull ${img} ;;\n        esac"])}
      systemctl --user daemon-reload
      ${join("\n", [for s in local.services : "        if [ \"${var.enable_on_boot}\" = \"true\" ]; then systemctl --user enable ${s}.service 2>/dev/null || true; fi\n        systemctl --user restart ${s}.service 2>/dev/null || true"])}
    EOT
  }
}

# Replay the model endpoints + Test Manager persona through the app's HTTP API
# after the services are up. Idempotent: the script skips anything already
# present, so it is safe to run on every apply.
resource "null_resource" "configure_odysseus" {
  depends_on = [
    null_resource.start_odysseus,
    local_sensitive_file.credentials_env,
    local_file.seed,
  ]

  triggers = {
    seed          = local_file.seed.content
    script        = filesha256("${path.module}/scripts/configure_odysseus.py")
    service_state = var.service_state
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -eu
      if [ "${var.service_state}" = "stopped" ]; then
        exit 0
      fi
      export XDG_RUNTIME_DIR=/run/user/$(id -u)
      python3 "${path.module}/scripts/configure_odysseus.py" "${local.odysseus_dir}/seed.json"
    EOT
  }
}
