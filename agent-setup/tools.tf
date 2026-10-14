# Declarative agent-tool catalog.
#
# One entry per tool. Add a tool = add an entry (or pass an override);
# remove a tool = drop the entry or set `enabled = false`. Everything that
# follows is generated from this map:
#
#   * the per-role image layer (agent-setup/.build/<role>/Containerfile)
#   * the in-image manifest   (/etc/aigents/tools.json)
#   * the exec allow-list     (/etc/aigents/allowed-commands.txt)
#
# Fields
#   enabled     - install this tool? (default true)
#   description - free text, recorded in the image manifest
#   roles       - which agent roles get it: e2e|pentester|manager|all (default ["all"])
#   apt         - Debian packages to `apt-get install`
#   pip         - Python packages to `pip install`
#   go          - Go modules to `go install` (golang-go is added automatically)
#   binary      - release assets to download: { url, dest, mode? }
#   run         - extra shell lines run at build time (one RUN per line)
#   env         - environment variables baked into the role image
#   bins        - command names this tool provides; they form the allow-list
#                 the `run_command` crew tool may execute
#   capabilities- Linux capabilities the tool needs, added to the role's quadlet
#                 (only capabilities valid in the rootless user namespace take
#                 effect; network caps over Network=host do not)
#
# The image layering: agent-setup/Containerfile builds the shared BASE image
# (python + crewai + lean + curl/git). Each role then gets a thin layer from
# this catalog, so e2e carries Playwright, the pentester carries its scanners
# and the manager carries neither.

variable "tools" {
  description = "Declarative catalog of agent tools (name -> definition)."
  type = map(object({
    enabled     = optional(bool, true)
    description = optional(string, "")
    roles       = optional(list(string), ["all"])
    apt         = optional(list(string), [])
    pip         = optional(list(string), [])
    go          = optional(list(string), [])
    binary = optional(list(object({
      url  = string
      dest = string
      mode = optional(string, "0755")
    })), [])
    run          = optional(list(string), [])
    env          = optional(map(string), {})
    bins         = optional(list(string), [])
    capabilities = optional(list(string), [])
  }))

  default = {
    # --- e2e engineer -------------------------------------------------------
    playwright = {
      description = "Playwright + headless Chromium for real browser e2e tests"
      roles       = ["e2e"]
      pip         = ["playwright>=1.47,<2.0.0"]
      env         = { PLAYWRIGHT_BROWSERS_PATH = "/opt/ms-playwright" }
      run         = ["python3 -m playwright install --with-deps chromium"]
      bins        = []
    }

    # --- pentester: pure Debian packages (fast, no download) ----------------
    nmap = {
      description = "Network / port / service scanner (unprivileged: -sT -Pn)"
      roles       = ["pentester"]
      apt         = ["nmap"]
      bins        = ["nmap"]
      # NOTE: agents run rootless with Network=host, so raw/SYN scans are not
      # possible (CAP_NET_RAW can't apply to the host netns). The persona/tasks
      # therefore use nmap's unprivileged TCP-connect scan: `nmap -sT -Pn -sV`.
    }
    sqlmap = {
      description = "Automatic SQL injection and database takeover"
      roles       = ["pentester"]
      apt         = ["sqlmap"]
      bins        = ["sqlmap"]
    }
    whatweb = {
      description = "Web technology fingerprinting"
      roles       = ["pentester"]
      apt         = ["whatweb"]
      bins        = ["whatweb"]
    }
    ffuf = {
      description = "Fast web fuzzer (content discovery)"
      roles       = ["pentester"]
      apt         = ["ffuf"]
      bins        = ["ffuf"]
    }
    gobuster = {
      description = "Directory / DNS / vhost brute forcing"
      roles       = ["pentester"]
      apt         = ["gobuster"]
      bins        = ["gobuster"]
    }
    hydra = {
      description = "Online password / login brute forcing"
      roles       = ["pentester"]
      apt         = ["hydra"]
      bins        = ["hydra"]
    }

    # --- pentester: not packaged in Debian, installed from source -----------
    nikto = {
      description = "Web server scanner (Perl; installed from upstream git)"
      roles       = ["pentester"]
      apt         = ["perl", "libnet-ssleay-perl", "libxml-writer-perl"]
      run = [
        "git clone --depth 1 https://github.com/sullo/nikto /opt/nikto",
        "ln -sf /opt/nikto/program/nikto.pl /usr/local/bin/nikto",
      ]
      bins = ["nikto"]
    }
    nuclei = {
      description = "Template-based vulnerability scanner (Go; pinned version)"
      roles       = ["pentester"]
      go          = ["github.com/projectdiscovery/nuclei/v3/cmd/nuclei@v3.3.7"]
      bins        = ["nuclei"]
    }
  }
}

variable "tools_overrides" {
  description = "Additive overrides to the tool catalog (shallow-merged over var.tools). Add a tool by adding an entry; disable one with `enabled = false`. Note: a shallow merge replaces the whole entry, so to tweak an existing tool restate its fields."
  type = map(object({
    enabled     = optional(bool, true)
    description = optional(string, "")
    roles       = optional(list(string), ["all"])
    apt         = optional(list(string), [])
    pip         = optional(list(string), [])
    go          = optional(list(string), [])
    binary = optional(list(object({
      url  = string
      dest = string
      mode = optional(string, "0755")
    })), [])
    run          = optional(list(string), [])
    env          = optional(map(string), {})
    bins         = optional(list(string), [])
    capabilities = optional(list(string), [])
  }))
  default = {}
}

locals {
  # The live catalog = built-in defaults + operator overrides.
  catalog = merge(var.tools, var.tools_overrides)

  # Keep only enabled tools.
  enabled_tools = {
    for name, t in local.catalog : name => t if t.enabled
  }

  # Per role: the tools whose `roles` list covers that role (or "all").
  role_tools = {
    for role in keys(var.roles) : role => {
      for name, t in local.enabled_tools : name => t
      if contains(t.roles, "all") || contains(t.roles, role)
    }
  }

  # --- flattened per-role install recipe ---------------------------------
  role_go = {
    for role, tools in local.role_tools :
    role => distinct(flatten([for t in values(tools) : t.go]))
  }
  role_apt = {
    for role, tools in local.role_tools :
    role => distinct(concat(
      flatten([for t in values(tools) : t.apt]),
      # any `go` install needs the Go toolchain
      length(local.role_go[role]) > 0 ? ["golang-go"] : [],
    ))
  }
  role_pip = {
    for role, tools in local.role_tools :
    role => distinct(flatten([for t in values(tools) : t.pip]))
  }
  role_binaries = {
    for role, tools in local.role_tools :
    role => flatten([for t in values(tools) : t.binary])
  }
  role_run = {
    for role, tools in local.role_tools :
    role => flatten([for t in values(tools) : t.run])
  }
  role_env = {
    for role, tools in local.role_tools :
    role => length(tools) > 0 ? merge([for t in values(tools) : t.env]...) : {}
  }
  role_bins = {
    for role, tools in local.role_tools :
    role => distinct(flatten([for t in values(tools) : t.bins]))
  }
  role_capabilities = {
    for role, tools in local.role_tools :
    role => distinct(flatten([for t in values(tools) : t.capabilities]))
  }

  # Manifest written into each image: what this role carries.
  role_tools_json = {
    for role, tools in local.role_tools : role => jsonencode({
      role = role
      tools = [for name, t in tools : {
        name         = name
        description  = t.description
        bins         = t.bins
        capabilities = t.capabilities
      }]
    })
  }

  # The exec allow-list consumed by worker/crew_tools/run_command.py.
  role_allowlist = {
    for role, bins in local.role_bins : role => join("\n", concat(
      ["# Allowed commands for role '${role}' (generated from agent-setup/tools.tf)"],
      sort(bins),
      [""],
    ))
  }
}
