# AgentHarness - Lean 4

Formal harness for agent harnessing and tuning. Lean 4 port of the Agda
version (`../agda/AgentHarness.agda`, kept for traceability). The toolchain is
pinned by `lean-toolchain` (`leanprover/lean4:v4.23.0`).

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

Arguments: `queue_size dedupe_cap crew_timeout steps step_cost`. A tuning is
accepted iff `queue_size ≤ dedupe_cap` and `steps * step_cost ≤ crew_timeout`
(the `WellTuned` obligation in `AgentHarness.lean`). The agent worker
(`worker/run_agent.py`) runs this before every crew execution and skips the
crew when the harness rejects the tuning.

## Content

- Section 1: crew roles, topics, and the chain between them
- Section 2: action boundaries and tool pre-conditions
- Section 3: worker state transitions
- Section 4: `Tuning` + `WellTuned` safety envelope
- Section 5: the tuning loop (safe widening / raising steps)
- Section 6: feedback (`review : Tuning → Verdict`)