# model-setup

OpenTofu for the **model + vector store** side of the self-hosted server:
two llama.cpp instances — **phi-4-mini** (primary agent brain) and
**phi-mini-moe** (secondary fast model) — plus **PostgreSQL + pgvector**,
deployed as a single **podman-compose** stack managed by OpenTofu. There is no
Qdrant and no MQTT anymore: agents connect to the model directly, store results
in Postgres, and coordinate through the separate MCP bus (mcp-setup).

## Why two models?

- **phi-4-mini** (primary, `:18080`) is the better model for the agent results:
  a 3.8B dense model with a 128K training context and **native tool calling**,
  both of which CrewAI relies on. It is what the crews, the test-manager
  controller, the `tm` CLI and the Odysseus chat all use.
- **phi-mini-moe** (secondary/fast, `:18081`) *supports* the primary instead of
  replacing it: a 7.6B/2.4B-active MoE (4096-token native window, no
  tool-calling in its GGUF template) that is not a good agent model, but is fast
  and cheap for short, high-volume work. The worker uses it to condense the
  shared findings before they enter the primary's context (see
  `worker/run_agent.py`). It is optional: when it is disabled or unreachable,
  everything degrades gracefully to phi-4-mini alone.

## What it runs

The stack renders as `/var/spool/aigents/compose/compose.yaml` (project
`aigents`) and is applied by the `start_compose` step during `tofu apply`:

| Service | Container | Host port | Notes |
|---------|-----------|-----------|-------|
| PostgreSQL + pgvector | `aigents-postgres` | `15432` | schema seeded once on empty data dir (vector dim **3072**) |
| phi-4-mini (primary) | `aigents-phi-4-mini` | `18080` | OpenAI-compatible `/v1`, alias `phi-4-mini`, **65536 ctx, 4 parallel slots** — serves crews + interactive chat |
| phi-mini-moe (fast) | `aigents-phi-mini-moe` | `18081` | OpenAI-compatible `/v1`, alias `phi-mini-moe`, **8192 ctx, 2 slots** — condenses findings; CPU by default |
| model-fetch | (one-shot) | — | downloads the primary GGUF; profile `fetch` |
| model-fetch-secondary | (one-shot) | — | downloads the secondary GGUF; profile `fetch` |

Both models run the CUDA llama.cpp image
(`ghcr.io/ggml-org/llama.cpp:server-cuda`). The primary uses the GPU via the
CDI device `nvidia.com/gpu=all` (`model_gpu_layers = 99`). The secondary runs
on **CPU by default** (`secondary_model_gpu_layers = 0`) so it never competes
with the primary for the 12 GB GPU; raise that variable when VRAM allows.

## Usage

```sh
tofu init
tofu plan
tofu apply
```

`tofu apply` in order:

1. writes `~/.config/containers/storage.conf` (image graph on the aigents
   volume), directories, credentials
2. renders the compose file + the initdb schema
3. runs `podman-compose -p aigents --profile fetch run --rm model-fetch`
   (downloads `Phi-4-mini-instruct-Q4_K_M.gguf`, ~2.5 GB, idempotent) and, when
   enabled, `model-fetch-secondary` (`Phi-mini-MoE-instruct-Q4_K_M.gguf`,
   ~5 GB)
4. `podman-compose -p aigents up -d`, then waits for each model health endpoint

### Verify

```sh
curl http://127.0.0.1:18080/health        # the primary phi-4-mini instance
curl http://127.0.0.1:18080/v1/models     # -> "phi-4-mini"
curl http://127.0.0.1:18081/v1/models     # -> "phi-mini-moe" (secondary, when enabled)
podman-compose -f /var/spool/aigents/compose/compose.yaml -p aigents ps
```

### Start / Stop

The desired stack state is controlled by the `service_state` variable. Stop the
models + database (volumes and GGUF weights are kept) or bring them back up:

```sh
tofu apply -var service_state=stopped   # stop postgres + both models
tofu apply -var service_state=running    # start them again (default)
```

## Exposing ports to your LAN

Everything binds `127.0.0.1` by default (see `bind_address`). To make the stack
reachable from your other devices, two things are needed **per host**:

1. **Bind** the port to all interfaces (`0.0.0.0`) in the module that owns it.
2. **Open the firewall** for that port. `model-setup` owns the iptables rules:
   `expose_public = true` opens every port listed in `expose_ports`
   (default: this module's own ports).

Example `tofu apply -var-file=lan.tfvars`:

```hcl
# model-setup
bind_address    = "0.0.0.0"
model_api_key   = "change-me"        # required once you are not localhost-only!
expose_public   = true
expose_ports    = [18080, 18081, 15432, 8080, 3001, 7000, 8888, 8100, 8091, 8765]
```

And in the other modules: `sut-setup` (`bind_address = "0.0.0.0"`),
`odysseus-setup` (`bind_address = "0.0.0.0"`), `mcp-setup`
(`mcp_host = "0.0.0.0"`). Only list a port in `expose_ports` when its owning
module actually binds `0.0.0.0`.

### Port matrix (defaults)

Reachable from a LAN device as `http://<host-ip>:<port>`. `tofu -chdir=model-setup output -json lan_matrix` prints it too.

| Service | Port | Owner module | Bind via |
|---------|------|--------------|----------|
| phi-4-mini OpenAI API | `18080` | model-setup | `bind_address` |
| phi-mini-moe OpenAI API | `18081` | model-setup | `bind_address` |
| PostgreSQL | `15432` | model-setup | `bind_address` |
| SUT nginx → Juice Shop | `8080` | sut-setup | `bind_address` |
| Juice Shop (direct) | `3000` | sut-setup | `bind_address` |
| Grafana | `3001` | sut-setup | `bind_address` |
| Odysseus UI | `7000` | odysseus-setup | `bind_address` |
| SearXNG | `8888` | odysseus-setup | `bind_address` |
| ChromaDB | `8100` | odysseus-setup | `bind_address` |
| ntfy | `8091` | odysseus-setup | `bind_address` |
| MCP bus (`/mcp`) | `8765` | mcp-setup | `mcp_host` |

> Security first: exposing Postgres (`15432`) and the model API without
> `model_api_key` is only sane on a trusted network. Expose only what you
> actually need (usually just `18080` for the model endpoint and `8080` for the
> SUT), set `model_api_key`/DB passwords, and prefer the nginx proxy `8080`
> over bare Juice Shop `3000`.

## Configuration knobs (highlights)

`model-setup/variables.tf` is the source of truth:

- `model_repo` = `unsloth/Phi-4-mini-instruct-GGUF`,
  `model_file` = `Phi-4-mini-instruct-Q4_K_M.gguf`, `model_alias` = `phi-4-mini`
- `secondary_model_*` — the fast model: repo
  `smarttasks/Phi-mini-MoE-instruct-GGUF`, alias `phi-mini-moe`, port `18081`,
  **CPU by default** (`secondary_model_gpu_layers = 0`), context `8192`
- `embedding_dimensions` = **3072** — must match the primary model's hidden size
  **before the first DB boot** (the initdb hook only runs on an empty data
  dir; change it only before initialising the cluster)
- `model_context_size` / `model_kv_cache_type`
  — total context **65536** -> **16384 per slot** at 4 slots (llama.cpp divides
  `--ctx-size` by `--parallel`), KV cache `q8_0`; `model_threads` defaults to
  0 = all cores
- `model_gpu_layers` = **99** — every primary layer is offloaded to the RTX 3060
  (CUDA image + CDI `nvidia.com/gpu=all`); set `0` for a pure-CPU run
- `model_parallel_slots` — default **4** so the three crews overlap with the
  interactive CLI/Odysseus chat; each slot multiplies the KV cache
- `bind_address` defaults to `127.0.0.1`; set `model_api_key` before
  switching to `0.0.0.0`
- `expose_public` / `expose_ports` — open the firewall (see above)
- `postgres_password` is generated by OpenTofu when left empty and stored in
  `/var/spool/aigents/database/secrets/credentials.env` (mode 0600) together
  with `POSTGRES_DSN`, `MODEL_URL`, `MODEL_NAME`, `MODEL_FAST_URL`,
  `MODEL_FAST_NAME`. The agent quadlets mount this file read-only.

## State layout

```
/var/spool/aigents/
├── containers/storage/        podman image + layer graph
├── compose/compose.yaml       the rendered stack (mode 0600)
├── model/                     GGUF weights (both models)
└── database/
    ├── postgres/              PostgreSQL cluster (pgdata)
    └── secrets/credentials.env  credentials for agents + tools
```

## Troubleshooting

- The stack is just a compose file: fix the cause and re-run
  `podman-compose -f /var/spool/aigents/compose/compose.yaml -p aigents up -d`,
  or `tofu apply` to re-apply.
- First apply is slow: it pulls images, downloads ~7.5 GB of weights and mmaps
  them before the `/health` endpoints respond.
- If your host's `network-online.target` never activates, keep
  `skip_network_online_wait = true` (default) so quadlets don't stall.