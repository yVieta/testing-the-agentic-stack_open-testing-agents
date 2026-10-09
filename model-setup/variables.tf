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
  description = "Host interface the compose stack binds published ports on. 0.0.0.0 exposes the services to the LAN, 127.0.0.1 keeps them localhost-only."
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
  description = "llama.cpp server image. The ggml-org image ships /app/llama-server plus curl/bash, which the fetch and health commands need. `server-cuda` bundles the CUDA runtime (driver 615 works with the bundled CUDA 12.8)."
  default     = "ghcr.io/ggml-org/llama.cpp:server-cuda"
}

variable "model_repo" {
  type        = string
  description = "Hugging Face repository holding the GGUF build of Phi-4 mini."
  default     = "unsloth/Phi-4-mini-instruct-GGUF"
}

variable "model_file" {
  type        = string
  description = "GGUF file inside model_repo. Q4_K_M of the 3.8B mini model is ~2.5 GB and fits the 16 GB RAM budget comfortably."
  default     = "Phi-4-mini-instruct-Q4_K_M.gguf"
}

variable "model_sha256" {
  type        = string
  description = "Optional expected SHA-256 of model_file. The fetch step verifies it when set."
  default     = ""
}

variable "model_alias" {
  type        = string
  description = "Model name reported by the OpenAI-compatible /v1/models endpoint."
  default     = "phi-4-mini"
}

variable "model_context_size" {
  type        = number
  description = "KV cache context window. A smaller window keeps CPU-only inference out of swap."
  default     = 16384
}

variable "model_threads" {
  type        = number
  description = "CPU threads used for generation. 0 lets llama.cpp pick every core."
  default     = 0
}

variable "model_parallel_slots" {
  type        = number
  description = "Concurrent request slots for the crew-facing model server (phi4). Each slot multiplies the KV cache; 2 lets crews overlap."
  default     = 2
}

variable "model_cli_port" {
  type        = number
  description = "Host port of the second phi-4-mini instance dedicated to the interactive test-manager CLI."
  default     = 18081
}

variable "model_cli_parallel_slots" {
  type        = number
  description = "Slots for the CLI-dedicated model server (phi4-cli); 1 is enough for a single interactive terminal."
  default     = 1
}

variable "model_gpu_layers" {
  type        = number
  description = "Layers offloaded to VRAM. 0 runs pure CPU. 99 offloads every phi-4-mini layer to the NVIDIA GPU (RTX 3060, CDI device nvidia.com/gpu=all). Both phi4 instances share the GPU."
  default     = 99
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
  description = "Optional Hugging Face token used by the fetch step for gated or rate limited downloads."
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
  description = "Dimensionality of the embeddings stored in pgvector. Matches phi-4-mini's hidden size (3072)."
  default     = 3072
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
  description = "Keep the user services running after logout so the stack survives SSH disconnects."
  default     = true
}

variable "skip_network_online_wait" {
  type        = bool
  description = "Neutralise podman's podman-user-wait-network-online.service helper. Podman gates every Quadlet unit on it and it polls `systemctl is-active network-online.target` until that unit activates, with TimeoutStartSec=90s. On hosts where the system network-online.target never reaches active, every container start stalls for the full 90s and then fails the helper - even when the network itself is up (NetworkManager healthy, nm-online returning instantly). Disable if your host's network-online.target does activate."
  default     = true
}

variable "service_state" {
  type        = string
  description = "Desired state of the compose stack: 'running' starts postgres + the model, 'stopped' stops them (volumes and GGUF weights are kept). Toggle with `tofu apply -var service_state=stopped` (re-run with 'running' to start again)."
  default     = "running"

  validation {
    condition     = contains(["running", "stopped"], var.service_state)
    error_message = "service_state must be either \"running\" or \"stopped\"."
  }
}