# agent-setup

OpenTofu for the **testing agents** themselves: they now run **locally** on the
same server, each as a Podman Quadlet service — no MQTT, no Raspberry Pis. Each
agent connects **directly** to the local model (`phi-4-mini` via llama.cpp) and
to the local **PostgreSQL + pgvector** store.

The model + database stack is managed by `../model-setup` as a podman-compose
stack (`/var/spool/aigents/compose/compose.yaml`, project `aigents`), so run
that module first — the agent quadlets assume the model port (`18080`) and
postgres (`15432`) are already up on `127.0.0.1`.

## What it builds

| Piece | Description |
|---|---|
| `localhost/aigents-agent` image | python 3.12-slim + `crewai[tools]` + `psycopg[binary]` + lean4 via **elan**; `skills/lean/` is baked into `/opt/harness` and built with `lake build` |
| `agent-<role>.container` per role | Quadlet: `Network=host`, repo mounted read-only at `/repo`, `credentials.env` at `/run/secrets/credentials.env`, runs `worker/run_agent.py` |

Roles come from `.dhall/Manifest.dhall` (default): `e2e`, `pentester`,
`manager` → `build/<role>/` crews.

## Usage

```sh
tofu init
tofu plan
tofu apply
```

Apply:
1. builds `localhost/aigents-agent` (pulls crewai + the lean toolchain — slow
   the first time),
2. writes `agent-<role>.container` into `~/.config/containers/systemd`,
3. `systemctl --user enable --now agent-<role>.service`.

The worker runs its crew once, then idles `RUN_INTERVAL` (900 s) and runs
again. Crews must have been compiled first (see the root `justfile` /
`README.md`):

```sh
nix develop -c just   # .dhall -> build/<role>/crew.json
```

If a role has no compiled crew yet, the worker falls back to a direct chat
completion against the local model.

### Start / Stop

The desired service state is controlled by the `service_state` variable. Stop
all agents (disables + stops the quadlet units) or start them again:

```sh
tofu apply -var service_state=stopped   # stop agent-e2e/pentester/manager
tofu apply -var service_state=running    # start them again (default)
```

## Tuning with Lean4

The harness is role-aware: each role gets its own `WellTuned` envelope and
default tuning (see `skills/lean/AgentHarness.lean`):

| Role      | queue | dedupe | timeout | steps | step_cost |
|-----------|-------|--------|---------|-------|-----------|
| e2e       | 32    | 256    | 3600    | 4     | 600       |
| pentester | 32    | 256    | 4800    | 4     | 1200      |
| manager   | 32    | 256    | 3600    | 4     | 900       |

Every cycle the worker runs `lake env lean --run Main.lean <role> ...` (the
harness at `/opt/harness`) and only executes the crew when that role's verdict
is `accepted`. Rejected tunings are logged to postgres instead. Override per
role with:

```sh
systemctl --user set-environment QUEUE_SIZE=64
systemctl --user restart agent-e2e.service
```

## Layout

- `main.tf` — image build, Quadlet units, start step
- `providers.tf`, `variables.tf`, `outputs.tf`
- `Containerfile` — the `localhost/aigents-agent` image
- `quadlet/agent.container.tftpl` — one unit per role
- `../worker/run_agent.py` — the local runner
- `../skills/lean/{Main,AgentHarness}.lean` — formal harness + tuning CLI