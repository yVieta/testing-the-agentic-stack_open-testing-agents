import AgentHarness

/-!
# Main.lean - tuning check CLI.

Reads five tuning parameters from the command line and prints the
`AgentHarness.review` verdict for them:

    lake env lean --run Main.lean queue_size dedupe_cap crew_timeout steps step_cost

Used by worker/run_agent.py to validate a tuning proposal before it is
applied (the safety obligations live in AgentHarness.lean).
-/

-- Parse a CLI arg as a Nat; 0 on garbage input.
def toTuningNat (s : String) : Nat :=
  match s.toNat? with
  | some n => n
  | none   => 0

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