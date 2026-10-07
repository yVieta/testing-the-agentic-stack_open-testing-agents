# AgentHarness - Lean 4

Formal harness for agent harnessing and tuning (Lean 4 port of the Agda
version in `../agda`).

## Building

```bash
cd skills/lean
lake build
```

## Checking

After building, the module can be used:

```bash
lake env lean -- -i AgentHarness
```

## Tuning check CLI

`Main.lean` reviews a proposed tuning parameter set:

```bash
lake env lean --run Main.lean 32 256 3600 4 900
# -> accepted | rejected
```

Arguments: `queue_size dedupe_cap crew_timeout steps step_cost`. The agent
worker (`worker/run_agent.py`) runs this before every crew execution and skips
the crew when the harness rejects the tuning.