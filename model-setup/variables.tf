variable "home_dir" {
  type        = string
  description = "Home dir of user that runs Podman rootless user services."
  default     = "/home/vieta"
}

variable "spool_root" {
  type        = string
  description = "Base directory on the big aigents volume. Holds the Podman image graph (containers/), the model weights (model/) and the database files (database/)."
  default     = "/var/spool/aigents"
}

variable "container_user_id" {
  type        = number
  description = "UID of the user running the Podman rootless services. Used for the container runroot directory."
  default     = 1000
}

variable "quadlet_dir" {
  type        = string
  description = "Dir where Quadlet unit files are written."
  default     = "~/.config/containers/systemd"
}


variable "bind_address" {
  type        = string
  description = "Host interface the pod binds published ports on. 0.0.0.0 exposes the services to the LAN, 127.0.0.1 keeps them localhost-only."
  default     = "127.0.0.1"
}

variable "expose_public" {
  type        = bool
  description = "When true, opens the published TCP ports with sudo/iptables so they are reachable from outside the host. Needs passwordless sudo; leave false otherwise."
  default     = false
}

variable "sudo_command" {
  type        = string
  description = "Privilege escalation helper used to open the firewall."
  default     = "sudo -n"
}


variable "model_port" {
  type        = number
  description = "Host port published for the OpenAI-compatible model API."
  default     = 18080
}

variable "model_image" {
  type        = string
  description = "llama.cpp server image. The ggml-org image ships /app/llama-server plus curl/bash, which the fetch and health commands need."
  default     = "ghcr.io/ggml-org/llama.cpp:server"
}

variable "model_repo" {
  type        = string
  description = "Hugging Face repository holding the GGUF build of Qwen3-Coder."
  default     = "unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF"
}

variable "model_file" {
  type        = string
  description = "GGUF file inside model_repo. Q4_K_M of the 30B-A3B MoE is ~18.6 GB and is the smallest useful quantization for this host's 15 GB RAM."
  default     = "Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"
}

variable "model_sha256" {
  type        = string
  description = "Optional expected SHA-256 of model_file. The fetch unit verifies it when set."
  default     = ""
}

variable "model_alias" {
  type        = string
  description = "Model name reported by the OpenAI-compatible /v1/models endpoint."
  default     = "qwen3-coder-30b-a3b-instruct"
}

variable "model_context_size" {
  type        = number
  description = "KV cache context window. 30B-A3B at Q4_K_M is ~18.6 GB and is mmap'd from disk, so a small window is what keeps this host out of swap."
  default     = 16384
}

variable "model_threads" {
  type        = number
  description = "CPU threads used for generation. 0 lets llama.cpp pick every core."
  default     = 0
}

variable "model_parallel_slots" {
  type        = number
  description = "Concurrent request slots. Each slot multiplies the KV cache, so keep this at 1 on a memory constrained host."
  default     = 1
}

variable "model_gpu_layers" {
  type        = number
  description = "Layers offloaded to VRAM. This host is an AMD iGPU box without CUDA/ROCm, so it stays 0 and inference runs on the CPU."
  default     = 0
}

variable "model_kv_cache_type" {
  type        = string
  description = "Quantization used for the K and V KV cache (q8_0 halves it versus f16)."
  default     = "q8_0"
}

variable "model_api_key" {
  type        = string
  description = "Bearer token required by the model API. Leave empty to disable authentication (only sane while bind_address is 127.0.0.1)."
  default     = ""
  sensitive   = true
}

variable "hf_token" {
  type        = string
  description = "Optional Hugging Face token used by the fetch unit for gated or rate limited downloads."
  default     = ""
  sensitive   = true
}

variable "hf_endpoint" {
  type        = string
  description = "Hugging Face endpoint used for weight downloads."
  default     = "https://huggingface.co"
}


variable "postgres_image" {
  type        = string
  description = "PostgreSQL image that already carries the pgvector extension."
  default     = "docker.io/pgvector/pgvector:0.8.0-pg17"
}

variable "postgres_port" {
  type        = number
  description = "Host port published for the PostgreSQL container."
  default     = 15432
}

variable "postgres_db" {
  type        = string
  description = "Database created on first start."
  default     = "aigents"
}

variable "postgres_user" {
  type        = string
  description = "Superuser created on first start."
  default     = "aigents"
}

variable "postgres_password" {
  type        = string
  description = "Password for postgres_user. Generated when empty."
  default     = ""
  sensitive   = true
}

variable "embedding_dimensions" {
  type        = number
  description = "Dimensionality of the embeddings stored in pgvector. Matches Qwen3's hidden size."
  default     = 2048
}


variable "qdrant_image" {
  type        = string
  description = "Qdrant server image."
  default     = "docker.io/qdrant/qdrant:v1.15.4"
}

variable "qdrant_http_port" {
  type        = number
  description = "Host port published for the Qdrant REST/gRPC-web API."
  default     = 16333
}

variable "qdrant_grpc_port" {
  type        = number
  description = "Host port published for the Qdrant gRPC API."
  default     = 16334
}

variable "qdrant_api_key" {
  type        = string
  description = "API key required by Qdrant. Generated when empty."
  default     = ""
  sensitive   = true
}

variable "qdrant_max_search_threads" {
  type        = number
  description = "Qdrant search thread cap. 15 GB of RAM cannot afford one search thread per core."
  default     = 4
}


variable "enable_mcp_server" {
  type        = bool
  description = "Run the MCP facade in mcp/model_mcp_server.py as a systemd user service, so the crewAI workers can call the model over MCP."
  default     = true
}

variable "mcp_bind_address" {
  type        = string
  description = "Bind address for the MCP server. The crewAI workers run on separate Raspberry Pis and connect over the LAN, so this normally has to be 0.0.0.0. The server refuses to start on a non-loopback address without mcp_bearer_token."
  default     = "0.0.0.0"
}

variable "mcp_port" {
  type        = number
  description = "Host port for the MCP streamable-http endpoint. Deliberately different from model_port so the raw model API and the agent-facing facade are separately reachable/securable."
  default     = 18081
}

variable "mcp_bearer_token" {
  type        = string
  description = "Shared secret the MCP server requires from clients. Generated when empty. Required whenever mcp_bind_address is not loopback."
  default     = ""
  sensitive   = true
}

variable "mcp_allowed_hosts" {
  type        = list(string)
  description = "Host header values the MCP server accepts. Guards against DNS rebinding, where a browser reaches a loopback MCP server through an attacker-controlled hostname."
  default     = ["127.0.0.1", "localhost", "[::1]"]
}

variable "mcp_allowed_origins" {
  type        = list(string)
  description = "Origin header values the MCP server accepts. Empty means no browser-origin check; non-browser MCP clients (crewAI) send no Origin at all, so this only matters if something drives the server from a web page."
  default     = []
}

variable "mcp_model_timeout" {
  type        = number
  description = "Seconds the MCP server waits for one completion. This host runs CPU-only inference on a 30B MoE, so minutes per call is normal; too low and the tool returns errors mid-generation."
  default     = 900
}

variable "mcp_venv_dir" {
  type        = string
  description = "Virtualenv for the MCP server. Kept out of the repo so the venv is not synced to the Raspberry Pis by pi-setup."
  default     = "/var/spool/aigents/database/mcp-venv"
}

variable "mcp_python" {
  type        = string
  description = "Python interpreter used to build the MCP virtualenv. Must be >= 3.10."
  default     = "python3"
}


variable "image_pull_policy" {
  type        = string
  description = "Quadlet Pull= policy. missing keeps the pinned llama.cpp build that was validated here instead of silently upgrading on every boot."
  default     = "missing"

  validation {
    condition     = contains(["always", "missing", "newer", "never"], var.image_pull_policy)
    error_message = "image_pull_policy must be one of always, missing, newer, never."
  }
}

variable "install_podman" {
  type        = bool
  description = "Install podman and friends through apt when the binary is missing. Set false if podman is already provided by the OS or nix."
  default     = false
}

variable "install_packages" {
  type        = list(string)
  description = "Packages installed by install_podman."
  default = [
    "podman",
    "slirp4netns",
    "fuse-overlayfs",
  ]
}

variable "apt_command" {
  type        = string
  description = "Privilege escalation helper used to install packages."
  default     = "sudo -n"
}

variable "enable_linger" {
  type        = bool
  description = "Keep the user services running after logout so the pod survives SSH disconnects."
  default     = true
}

variable "skip_network_online_wait" {
  type        = bool
  description = "Neutralise podman's podman-user-wait-network-online.service helper. Podman gates every Quadlet unit on it and it polls `systemctl is-active network-online.target` until that unit activates, with TimeoutStartSec=90s. On hosts where the system network-online.target never reaches active, every container start stalls for the full 90s and then fails the helper - even when the network itself is up (NetworkManager healthy, nm-online returning instantly). Disable if your host's network-online.target does activate."
  default     = true
}
