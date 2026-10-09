# odysseus-setup

Deploys [Odysseus](https://github.com/odysseus-dev/odysseus) — a self-hosted AI
workspace — as four Podman **Quadlet** user services via OpenTofu, exactly like
`sut-setup`/`agent-setup`. Odysseus gives you a browser UI to chat with the
local phi-4-mini model (and the fast phi-mini-moe) and to run an agent with the
test-manager persona.

## What it deploys

| Unit                  | Image                                     | Host port                | Purpose                          |
| --------------------- | ----------------------------------------- | ------------------------ | -------------------------------- |
| `odysseus-app`        | `ghcr.io/odysseus-dev/odysseus:latest`    | host net, `0.0.0.0:7000` | Web UI, chat, agents, research   |
| `odysseus-chromadb`   | `docker.io/chromadb/chroma:latest`        | `127.0.0.1:8100` (->8000)| Vector store for documents       |
| `odysseus-searxng`    | pinned searxng digest                     | `127.0.0.1:8888` (->8080)| Metasearch (host 8080 stays SUT) |
| `odysseus-ntfy`       | `docker.io/binwiederhier/ntfy`            | `127.0.0.1:8091` (->80)  | Notification push                |

The app runs with **host networking** (rootless containers cannot reach
host-loopback services through pasta's gateway). It talks to the two local
llama.cpp instances directly on the loopback:

- `LLM_HOST` -> `127.0.0.1:18080` (the shared phi-4-mini primary: crews + chats)
- `LLM_HOSTS` -> `127.0.0.1:18080,127.0.0.1:18081` (primary + fast model; derived
  from `llm_host` + `llm_fast_host`)
- `RESEARCH_LLM_ENDPOINT` -> `http://127.0.0.1:18080/v1`

## Usage

```bash
cd odysseus-setup
tofu init
tofu apply -input=false -auto-approve -var service_state=running   # start
tofu apply -input=false -auto-approve -var service_state=stopped   # stop
```

Then open <http://localhost:7000> and log in with the admin account (default
user `admin`). The first-boot admin password is generated and written to
`secrets/credentials.env`; print it either way:

```bash
tofu output -raw admin_credentials                 # user + password
cat /var/spool/aigents/odysseus/secrets/credentials.env
```

Notes:

- Pin your own admin password with `-var admin_password='...'` before the first
  apply; otherwise a random one is generated (and kept in state).
- `auth_enabled=true` (default) requires the login. `localhost_bypass=true`
  would skip auth for requests that look local — leave it `false` when the UI is
  reachable beyond localhost.
- The UI binds `bind_address:app_port` (default `127.0.0.1:7000`).

## Talking to the model & test-manager agent

The module seeds the workspace on every `apply` (idempotently) through
`scripts/configure_odysseus.py`:

1. **Model endpoints** — registers `http://127.0.0.1:18080/v1` (the primary
   phi-4-mini serving crews + interactive chat) and, when enabled,
   `http://127.0.0.1:18081/v1` (the fast phi-mini-moe) as OpenAI-compatible
   endpoints. Stale local model registrations on 18080/18081 that are no longer
   declared in the seed are pruned on apply.
2. **Test Manager preset** — installs and activates a character preset built
   from the compiled persona at `<repo>/build/agents/test_manager_agent.json`
   (run `nix develop -c just agents` first; a short fallback prompt is used when
   the file is absent). Pick the *Test Manager* character in the UI to chat as
   the test manager.
3. Chat tools (search/embedding/memory) use the bundled SearXNG, ChromaDB and
   fastembed.

**Test results as notes.** The agents push their reports into the Odysseus
**Notes** panel after every run — the bus (`../worker/mcp_server.py`) writes them
via the Notes API (`POST/PUT /api/notes`, label `test-results`, one note per
role, updated in place). They show up as Keep-style cards in the UI's Notes tab.
The chat's `aigents_bus` tool and the `tm` CLI (`/notes`, `/note`) can list and
publish them too.

**Test reports as mail.** The test manager delivers the final report as mail
through Odysseus' own mail function (`POST /api/email/send`); the MCP bus tool
`mail_report` drives it, every manager run mails `report.md`, and `tm` `/mail`
mails the latest report. Outbound mail needs an SMTP-capable mailbox, configured
either interactively (**Settings → Email** in the UI) or declaratively:

```bash
tofu apply \
  -var smtp_host=smtp.example.com -var smtp_user=reports@example.com \
  -var smtp_password=... -var report_mail_to=you@example.com \
  -var imap_host=imap.example.com -var imap_user=reports@example.com -var imap_password=...
```

- `smtp_host`/`smtp_user`/`smtp_password` (+ optional `smtp_port`,
  `smtp_security`, `email_from`) enable sending. They are passed to the app as
  `SMTP_*`/`EMAIL_FROM`, which Odysseus uses when no Email Account exists in its
  DB (`_get_email_config` fallback).
- Add `imap_host`/`imap_user`/`imap_password` to also **receive** the reports in
  the Odysseus inbox and keep a copy in Sent.
- `report_mail_to` is written to `credentials.env` as `REPORT_MAIL_TO` — the
  default recipient for the bus, the agents and `tm` `/mail`.
- With no mailbox configured, `mail_report` returns a clear "no SMTP-capable
  email account configured" message; the report is still published as a
  note/document.

The seeding is skipped when `service_state=stopped`, and re-running `apply`
never creates duplicate endpoints or presets.

Starting/stopping this module is also covered by the repo-root
`../start-services.sh` wrapper (it runs `odysseus-setup` last on start and
first on stop).
