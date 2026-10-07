# AgentHarness - Lean 4

This is the Lean 4 port of the Agda formal harness. The harness is used for agent harnessing and tuning.

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

## Usage

Same as the Agda version - agents propose new tuning parameters and the Lean 4 checker verifies the safety envelope.
