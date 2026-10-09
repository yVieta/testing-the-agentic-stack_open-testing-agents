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

`Main.lean` reviews a proposed tuning parameter set for one role, scoped to the
deployed SUT:

```bash
lake env lean --run Main.lean e2e 32 256 3600 4 600
# -> accepted | rejected
lake env lean --run Main.lean e2e 32 256 3600 4 600 http://127.0.0.1:8080
# ^ the optional sut_url must match the set SUT (juiceShop)
```

Arguments: `<role> queue_size dedupe_cap crew_timeout steps step_cost [sut_url]`
with `role ∈ { e2e, pentester, manager }`. A tuning is accepted for a role iff
the run is scoped to **the one deployed SUT** (`AgentHarness.juiceShop`, OWASP
Juice Shop on `:8080`) *and* the tuning fits that role's `WellTuned` envelope in
`AgentHarness.lean` (queue ≤ dedupe window and every dimension inside the role's
ceiling — the e2e crew gets more, quicker steps; the pentester fewer, longer
scan steps; the manager a moderate review budget). Point the check at any other
target and it is rejected no matter how well tuned (`off_target_rejected`), so
all three agents are provably focused on the same clearly set service. The agent
worker (`worker/run_agent.py`) runs this before every crew execution with the
role's own tuning and its configured `TARGET_URL`, and skips the crew when the
harness rejects it.

## Content

- Section 1: crew roles, topics, and the chain between them
- Section 1b: the single SUT (`SUT`, `juiceShop`, `focus`, `Scoped`) every role
  is scoped to
- Section 2: action boundaries and tool pre-conditions
- Section 3: worker state transitions
- Section 4: `Tuning` + the per-role `WellTuned` envelope
- Section 5: the tuning loop (safe widening / raising steps)
- Section 6: feedback (`Harnessed`, `reviewOn : SUT → Role → Tuning → Verdict`)