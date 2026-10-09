# mcp-setup

OpenTofu for the **MCP knowledge + control bus** — an optional but central piece
of the stack. It runs **on the host** (not in a container) as a systemd **user**
service so it can drive the agent units with `systemctl --user` and reach
Odysseus on `127.0.0.1` without publishing anything.

The server is `../worker/mcp_server.py` (stdlib-only, JSON-RPC 2.0 over HTTP at
`/mcp`); this module wires it up: the unit file, the SQLite state dir, and the
start/stop lifecycle.

## What the bus does

| Tool | Purpose |
|------|---------|
| `assign_test_case` | test manager → queue a case for e2e/pentester/both/all |
| `get_next_task` / `list_tasks` | workers claim their pending case; anyone lists the queue |
| `submit_findings` / `get_findings` | roles exchange the knowledge their runs produced |
| `start_agent` / `stop_agent` / `get_agent_status` | `systemctl --user` control of the agent units |
| `publish_process` / `get_process` | live *Testing process* markdown → Odysseus **documents** |
| `publish_note` / `list_notes` | test results → Odysseus **Notes** panel (web UI) and back |

Consumers: the workers (`../worker/run_agent.py`), the test-manager CLI
(`../worker/tm_cli.py`, `/notes`, `/note`, `/publish`, …) and the
Test-Manager character in Odysseus via `custom:aigents_bus` (`../worker/crew_tools/aigents_bus.py`).

## Tools talk to Odysseus

The bus logs into Odysseus with the credentials in
`<spool_root>/odysseus/secrets/credentials.env` and:

- **document** publishing — `publish_process` writes the live process markdown
  to the *Document library* (title-keyed, so it updates in place);
- **note** publishing — `publish_note` writes each role's test results into the
  *Notes* panel (Google-Keep style, label `test-results`). Same title + label
  updates the existing note, so the web UI always holds the latest results per
  role; `list_notes` reads them back for the user or the manager agent.

Any failure is reported as a tool message and never breaks the bus or a run.

## Usage

```sh
tofu init
tofu apply                # running (default)
tofu apply -var service_state=stopped   # disable + stop
```

State lives in SQLite at `<spool_root>/mcp/mcp.db`; the unit is
`~/.config/systemd/user/aigents-mcp.service`. Starting is also covered by the
repo-root `../start-services.sh` (runs after `sut-setup`, before
`agent-setup`).

```sh
systemctl --user status aigents-mcp
curl -s http://127.0.0.1:8765/health
python3 ../worker/mcp_bus.py get_process          # tiny client CLI check
```

## Configuration knobs

`mcp-setup/variables.tf` is the source of truth:

- `mcp_host` / `mcp_port` (default `127.0.0.1:8765`) — bind interface and
  port. `0.0.0.0` lets other devices reach the bus on your LAN (add `8765` to
  `model-setup`'s `expose_ports` and open the firewall there too).
- `spool_root` (default `/var/spool/aigents`) — where `mcp/` state lives.
- `repo_dir` — which checkout provides `worker/mcp_server.py`.
- `service_state` (`running` | `stopped`), `enable_on_boot` (default `false`,
  nothing auto-starts), `enable_linger` (default `true`).
- `odysseus_secrets_dir` — Odysseus credentials used for notes/documents.

## Layout

```
/var/spool/aigents/mcp/        SQLite bus state
~/.config/systemd/user/aigents-mcp.service   unit
```