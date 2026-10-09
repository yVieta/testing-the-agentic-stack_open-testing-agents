import AgentHarness

/-!
# Main.lean - role-aware tuning check CLI.

Reads a role name and five tuning parameters from the command line and prints
the `AgentHarness.reviewOn` verdict for them under that role's safety envelope:

    lake env lean --run Main.lean <role> queue_size dedupe_cap crew_timeout steps step_cost [sut_url]

Roles: e2e | pentester | manager. The optional `sut_url` must match the deployed
SUT (`AgentHarness.juiceShop`); any other target is rejected, so a run is only
accepted against the one clearly set service. Used by worker/run_agent.py to
validate a tuning proposal before it is applied (the safety obligations live in
AgentHarness.lean).
-/

-- Parse the harness Role name; None on garbage input.
def parseRole (s : String) : Option AgentHarness.Role :=
  match s with
  | "e2e"       => some AgentHarness.Role.e2e
  | "pentester" => some AgentHarness.Role.pentester
  | "manager"   => some AgentHarness.Role.manager
  | _           => none

-- Parse a CLI arg as a Nat; 0 on garbage input.
def toTuningNat (s : String) : Nat :=
  match s.toNat? with
  | some n => n
  | none   => 0

-- Print the review verdict for a role/tuning against a specific SUT.
def decide (role : AgentHarness.Role) (t : AgentHarness.Tuning)
    (sut : AgentHarness.SUT) : IO Unit :=
  match AgentHarness.reviewOn sut role t with
  | AgentHarness.Verdict.accepted => IO.println "accepted"
  | AgentHarness.Verdict.rejected => IO.println "rejected"

def main (args : List String) : IO Unit :=
  match args with
  | [r, q, d, c, s, k] =>
    match parseRole r with
    | some role =>
      let t : AgentHarness.Tuning :=
        { queue_size := toTuningNat q, dedupe_cap := toTuningNat d
        , crew_timeout := toTuningNat c, steps := toTuningNat s, step_cost := toTuningNat k }
      decide role t AgentHarness.juiceShop
    | none => IO.println s!"unknown-role: {r}"
  | [r, q, d, c, s, k, u] =>
    match parseRole r with
    | some role =>
      let t : AgentHarness.Tuning :=
        { queue_size := toTuningNat q, dedupe_cap := toTuningNat d
        , crew_timeout := toTuningNat c, steps := toTuningNat s, step_cost := toTuningNat k }
      decide role t { name := "SUT", url := u }
    | none => IO.println s!"unknown-role: {r}"
  | _ => IO.println "usage: Main.lean <role> queue_size dedupe_cap crew_timeout steps step_cost [sut_url]"