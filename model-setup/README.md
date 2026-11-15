# model-setup

Terraform/OpenTofu for the model + vector-store side of the self-hosted server:
**Qwen3-Coder** served by llama.cpp, **PostgreSQL + pgvector**, and **Qdrant**,
all as Podman Quadlet container services in a single pod.

Mirrors the layout of [`../sut-setup`](../sut-setup): `tofu apply` writes the
Quadlet units, and systemd user services do the rest.

## What it runs

| Service             | Unit               | Host port | Notes                                            |
|---------------------|---------------------- |-----------|--------------------------------------------------|
| Qwen3-Coder (30B-A3B)| `qwen-coder.service`| 18080   | llama.cpp, OpenAI-compatible `/v1`               |
| PostgreSQL + pgvector| `postgres.service` | 15432    | `aigents` database, schema seeded on first boot  |
| Qdrant              | `qdrant.service`    | 16333 / 16334 | HTTP / gRPC, API key enforced on data endpoints |

`model-fetch.service` is a one-shot unit that downloads the GGUF weights; it is
not enabled at boot.

## Usage

```sh
tofu init
tofu plan
tofu apply

# 1. to get the GGUF 
systemctl --user start model-fetch.service

# 2. start the server
systemctl --user start qwen-coder.service

# 3. manuel test the connection
curl http://127.0.0.1:18080/health
curl http://127.0.0.1:18080/v1/models
```

`qwen-coder.service` carries `ConditionPathExists=<weights>`, so it stays
`inactive` until step 1 has put the file in place. Watch either job with
`journalctl --user -fu model-fetch` / `-fu qwen-coder`.

Credentials are generated on first apply and written to
`/var/spool/aigents/database/secrets/credentials.env` (mode 0600):

```sh
set -a; . /var/spool/aigents/database/secrets/credentials.env; set +a
psql "$POSTGRES_DSN" -c 'SELECT * FROM match_documents(...)'
curl -H "api-key: $QDRANT_API_KEY" "$QDRANT_URL/collections"
```

## Storage layout

Everything lives on the large `aigents` volume:

| Path                              | Contents                                    |
|-----------------------------------|---------------------------------------------|
| `/var/spool/aigents/containers/storage` | Podman image + layer graph            |
| `/var/spool/aigents/model`        | GGUF weights (bind-mounted at `/models`)     |
| `/var/spool/aigents/database/postgres` | `PGDATA` cluster                      |
| `/var/spool/aigents/database/qdrant`   | Qdrant segments + snapshots             |
| `/var/spool/aigents/database/secrets`   | `credentials.env` (0700 dir, 0600 file) |

The Podman graphroot is set through a global
`~/.config/containers/storage.conf`, **not** per-unit `PodmanArgs`: Quadlet
forwards `PodmanArgs` to `podman pod create` but not to `podman pod start`, so a
per-unit `--root` leaves pod starts looking in the default graph and failing.

Note that `/var/spool/aigents/containers/storage` is now the graphroot for
**every** rootless podman command run as this user, including the ones
`sut-setup` manages. The two setups share one image store by design.

## Vector schema

`postgres/initdb/01-aigents-schema.sql` runs once via the pgvector image's
initdb hook and creates the `vector` extension, `documents`,
`document_embeddings`, and the `match_documents()` cosine-distance lookup
function. Embeddings are `vector(2048)` to match Qwen3's hidden size —
override with `embedding_dimensions` **only before the first boot**, since the
initdb hook never re-runs on an existing `PGDATA`. To change it later, drop and
recreate the cluster:

```sh
systemctl --user stop postgres.service
systemctl --user start postgres.service
```

No ANN index is created by default; the SQL file documents the HNSW/IVFFlat
statements to add once the table has data.

## Choosing a different model

Any GGUF works — override the repo and file:

```sh
tofu apply \
  -var 'model_repo=Qwen/Qwen3-0.6B-GGUF' \
  -var 'model_file=Qwen3-0.6B-Q8_0.gguf' \
  -var 'model_alias=qwen3-0.6b' \
  -var 'model_context_size=4096'
```

Set `model_sha256` to have `model-fetch.service` verify the download. Use
`hf_token` for gated or rate-limited repos.

## Exposure and the API-key caveat

`bind_address` defaults to `127.0.0.1` (localhost only), and `expose_public`
(default `false`) is what would open the ports in iptables.

**`model_api_key` is empty by default, and llama-server's own CORS policy
allows every origin.** That is only acceptable because the published port binds
to loopback. Before setting `bind_address = "0.0.0.0"`:

```sh
tofu apply -var 'model_api_key=<bearer-token>'
```

## Project layout

- `main.tf` — writes storage.conf, the Quadlet units, the rendered schema, and runs the start steps
- `variables.tf` — tunables (model, images, ports, credentials, host quirks?)
- `outputs.tf` — endpoints, storage paths, post-apply steps
- `quadlet/` — Quadlet templates (`*.container.tftpl`, `*.pod.tftpl`)
- `postgres/initdb/01-aigents-schema.sql` — schema, templated on `embedding_dimensions`

## Teardown

```sh
systemctl --user stop qwen-coder.service postgres.service qdrant.service
systemctl --user stop aigents-pod.service
tofu destroy
```
