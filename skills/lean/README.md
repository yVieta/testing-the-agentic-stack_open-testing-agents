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

`Main.lean` reviews a proposed tuning parameter set for one role:

```bash
lake env lean --run Main.lean e2e 32 256 3600 4 600
# -> accepted | rejected
```

Arguments: `<role> queue_size dedupe_cap crew_timeout steps step_cost` with
`role ∈ { e2e, pentester, manager }`. A tuning is accepted for a role iff it
fits that role's `WellTuned` envelope in `AgentHarness.lean` (queue ≤ dedupe
window and every dimension inside the role's ceiling — the e2e crew gets more,
quicker steps; the pentester fewer, longer scan steps; the manager a moderate
review budget). The agent worker (`worker/run_agent.py`) runs this before every
crew execution with the role's own tuning and skips the crew when the harness
rejects it.

## Content

- Section 1: crew roles, topics, and the chain between them
- Section 2: action boundaries and tool pre-conditions
- Section 3: worker state transitions
- Section 4: `Tuning` + the per-role `WellTuned` envelope
- Section 5: the tuning loop (safe widening / raising steps)
- Section 6: feedback (`review : Role → Tuning → Verdict`)