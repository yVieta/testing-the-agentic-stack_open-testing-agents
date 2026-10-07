import AgentHarness

/-!
# Main.lean - tuning check CLI.

Reads five tuning parameters from the command line and prints the
`AgentHarness.review` verdict for them:

    lake env lean --run Main.lean queue_size dedupe_cap crew_timeout steps step_cost

Used by worker/run_agent.py to validate a tuning proposal before it is
applied (the safety obligations live in AgentHarness.lean).
-/

-- Convert a native Lean Nat to the harness's own Nat (iterated successor).
def harnessNat : _root_.Nat → AgentHarness.Nat
  | 0 => AgentHarness.Nat.zero
  | _root_.Nat.succ n => AgentHarness.Nat.succ (harnessNat n)

-- Parse a CLI arg as a harness Nat; 0 on garbage input.
def toTuningNat (s : String) : AgentHarness.Nat :=
  match s.toNat? with
  | some n => harnessNat n
  | none => AgentHarness.Nat.zero

def main (args : List String) : IO Unit :=
  match args with
  | [q, d, c, s, k] =>
    let t : AgentHarness.Tuning :=
      { queue_size := toTuningNat q, dedupe_cap := toTuningNat d
      , crew_timeout := toTuningNat c, steps := toTuningNat s, step_cost := toTuningNat k }
    match AgentHarness.review t with
    | AgentHarness.Verdict.accepted => IO.println "accepted"
    | AgentHarness.Verdict.rejected => IO.println "rejected"
  | _ => IO.println "usage: Main.lean queue_size dedupe_cap crew_timeout steps step_cost"