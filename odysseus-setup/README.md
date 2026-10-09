# odysseus-setup

Deploys [Odysseus](https://github.com/odysseus-dev/odysseus) — a self-hosted AI
workspace — as four Podman **Quadlet** user services via OpenTofu, exactly like
`sut-setup`/`agent-setup`. Odysseus gives you a browser UI to chat with the
local phi-4-mini model and to run an agent with the test-manager persona.

## What it deploys

| Unit                  | Image                                     | Host port                | Purpose                          |
| --------------------- | ----------------------------------------- | ------------------------ | -------------------------------- |
| `odysseus-app`        | `ghcr.io/odysseus-dev/odysseus:latest`    | host net, `0.0.0.0:7000` | Web UI, chat, agents, research   |
| `odysseus-chromadb`   | `docker.io/chromadb/chroma:latest`        | `127.0.0.1:8100` (->8000)| Vector store for documents       |
| `odysseus-searxng`    | pinned searxng digest                     | `127.0.0.1:8888` (->8080)| Metasearch (host 8080 stays SUT) |
| `odysseus-ntfy`       | `docker.io/binwiederhier/ntfy`            | `127.0.0.1:8091` (->80)  | Notification push                |

The app runs with **host networking** (rootless containers cannot reach
host-loopback services through pasta's gateway). It talks to the single
phi-4-mini instance directly on the loopback:

- `LLM_HOST` -> `127.0.0.1:18080` (the shared phi-4-mini: crews + chats)
- `LLM_HOSTS` -> `127.0.0.1:18080` (same instance; kept because the app scans
  both env vars) 
- `RESEARCH_LLM_ENDPOINT` -> `http://127.0.0.1:18080/v1`

## Usage

```bash
cd odysseus-setup
tofu init
tofu apply -input=false -auto-approve -var service_state=running   # start
tofu apply -input=false -auto-approve -var service_state=stopped   # stop
```

Then open <http://localhost:7000> and log in. The first-boot admin credentials
are shown by `tofu output -raw admin_credentials` or at
`/var/spool/aigents/odysseus/secrets/credentials.env`

```bash
cat /var/spool/aigents/odysseus/secrets/credentials.env
```

## Talking to the model & test-manager agent

The module seeds the workspace on every `apply` (idempotently) through
`scripts/configure_odysseus.py`:

1. **Model endpoint** — registers `http://127.0.0.1:18080/v1` (the single
   phi-4-mini serving crews + interactive chat) as an OpenAI-compatible
   endpoint, where `phi-4-mini` is discovered. Stale endpoints left over from
   the retired CLI-only instance (port 18081) are pruned on apply.
2. **Test Manager preset** — installs and activates a character preset built
   from the compiled persona at `<repo>/build/agents/test_manager_agent.json`
   (run `nix develop -c just agents` first; a short fallback prompt is used when
   the file is absent). Pick the *Test Manager* character in the UI to chat as
   the test manager.
3. Chat tools (search/embedding/memory) use the bundled SearXNG, ChromaDB and
   fastembed.

The seeding is skipped when `service_state=stopped`, and re-running `apply`
never creates duplicate endpoints or presets.

Starting/stopping this module is also covered by the repo-root
`../start-services.sh` wrapper (it runs `odysseus-setup` last on start and
first on stop).
