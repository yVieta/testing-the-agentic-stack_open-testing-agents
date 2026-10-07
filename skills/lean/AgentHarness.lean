/-
# AgentHarness.lean - the formal harness the crew is tuned against.

Lean 4 port of AgentHarness.agda. Built on the standard library (no axioms).
- section 1: the crew roles and the chain between them (no MQTT; local files)
- section 2: action boundaries + tool pre-conditions
- section 3: worker state transitions
- section 4: tuning parameters + safety envelope (WellTuned)
- section 5: the tuning loop (safe widening/more-step lemmas)
- section 6: verification feedback (review : Tuning → Verdict)

Worker usage (worker/run_agent.py):
    lake env lean --run Main.lean queue_size dedupe_cap crew_timeout steps step_cost
-/

namespace AgentHarness

/-! 1. The crew: roles, topics, and the chain between them -/

inductive Role : Type where
  | e2e       : Role  -- pi1-e2e
  | pentester : Role  -- pi2-pentester
  | manager   : Role  -- pi3-manager

inductive Topic : Type where
  | crew_start            : Topic  -- crew/start
  | crew_pentester_input  : Topic  -- crew/pentester/input
  | crew_manager_input    : Topic  -- crew/manager/input
  | crew_final            : Topic  -- crew/final
  | crew_status           : Topic  -- crew/status/<role>
  | crew_proof_verify     : Topic  -- crew/proof/verify
  | crew_proof_feedback   : Topic  -- crew/proof/feedback

/-- Input topic of each role -/
def listen : Role → Topic
  | Role.e2e       => Topic.crew_start
  | Role.pentester => Topic.crew_pentester_input
  | Role.manager   => Topic.crew_manager_input

/-- Output topic of each role -/
def publish : Role → Topic
  | Role.e2e       => Topic.crew_pentester_input
  | Role.pentester => Topic.crew_manager_input
  | Role.manager   => Topic.crew_final

structure Connected (src dst : Role) : Prop where
  wire : publish src = listen dst

/-- The chain is wired edge-to-edge. -/
def e2e_to_pentester : Connected Role.e2e Role.pentester :=
  ⟨rfl⟩

def pentester_to_manager : Connected Role.pentester Role.manager :=
  ⟨rfl⟩

def manager_to_monitor : publish Role.manager = Topic.crew_final :=
  rfl

/-- Only e2e starts. -/
theorem only_e2e_starts : ∀ r, listen r = Topic.crew_start → r = Role.e2e
  | Role.e2e, _ => rfl
  | Role.pentester, h => by cases h
  | Role.manager, h => by cases h

/-- No role publishes onto the proof-verify topic (no self certification). -/
theorem no_self_certification : ∀ r, publish r = Topic.crew_proof_verify → False
  | Role.e2e, h => by cases h
  | Role.pentester, h => by cases h
  | Role.manager, h => by cases h

/-! 2. Action boundaries and tool pre-conditions -/

inductive Tool : Type where
  | file_read   : Tool
  | file_write  : Tool
  | playwright  : Tool
  | scanner     : Tool

/-- Tool permissions -/
def permitted : Role → Tool → Prop
  | Role.e2e, Tool.file_read  => True
  | Role.e2e, Tool.file_write => True
  | Role.e2e, Tool.playwright => True
  | Role.e2e, Tool.scanner    => False
  | Role.pentester, Tool.file_read  => True
  | Role.pentester, Tool.file_write => True
  | Role.pentester, Tool.playwright => False
  | Role.pentester, Tool.scanner    => True
  | Role.manager, Tool.file_read  => True
  | Role.manager, Tool.file_write => True
  | Role.manager, Tool.playwright => False
  | Role.manager, Tool.scanner    => False

/-- The scan-grade tool per role. -/
def scan_tool : Role → Tool
  | Role.e2e       => Tool.playwright
  | Role.pentester => Tool.scanner
  | Role.manager   => Tool.file_read

theorem only_e2e_playwright : ∀ r, scan_tool r = Tool.playwright → r = Role.e2e
  | Role.e2e, _ => rfl
  | Role.pentester, h => by cases h
  | Role.manager, h => by cases h

theorem e2e_cannot_scan : ¬ permitted Role.e2e Tool.scanner := by
  simp [permitted]

theorem manager_cannot_scan : ¬ permitted Role.manager Tool.scanner := by
  simp [permitted]

inductive Artefact : Type where
  | findings : Artefact
  | report   : Artefact

def owns : Role → Artefact → Prop
  | Role.e2e, Artefact.findings => True
  | Role.e2e, Artefact.report   => False
  | Role.pentester, Artefact.findings => True
  | Role.pentester, Artefact.report   => False
  | Role.manager, Artefact.findings => True
  | Role.manager, Artefact.report   => True

theorem report_owner : ∀ r, owns r Artefact.report → r = Role.manager
  | Role.e2e, h => False.elim h
  | Role.pentester, h => False.elim h
  | Role.manager, _ => rfl

/-- Handover between roles goes through the shared file previous_output.md. -/
inductive Handover : Type where
  | kick_off       : Handover
  | from_e2e       : Handover
  | from_pentester : Handover

def handover_of : Role → Handover
  | Role.e2e       => Handover.kick_off
  | Role.pentester => Handover.from_e2e
  | Role.manager   => Handover.from_pentester

def readable : Role → Handover → Prop
  | Role.e2e, Handover.kick_off       => False
  | Role.e2e, Handover.from_e2e       => False
  | Role.e2e, Handover.from_pentester => False
  | Role.pentester, Handover.kick_off       => False
  | Role.pentester, Handover.from_e2e       => True
  | Role.pentester, Handover.from_pentester => True
  | Role.manager, Handover.kick_off       => False
  | Role.manager, Handover.from_e2e       => False
  | Role.manager, Handover.from_pentester => True

theorem reads_previous : ∀ r, readable r (handover_of r) → True
  | Role.e2e, h => False.elim h
  | Role.pentester, _ => True.intro
  | Role.manager, _ => True.intro

theorem e2e_reads_nothing : ∀ h, ¬ readable Role.e2e h
  | Handover.kick_off, h => h
  | Handover.from_e2e, h => h
  | Handover.from_pentester, h => h

/-! 3. State transitions -/

inductive Phase : Type where
  | idle : Phase
  | running : Phase
  | done : Phase
  | failed : Phase

inductive Event : Type where
  | kickoff   : Event
  | published : Event
  | crashed   : Event

def transition : Phase → Event → Phase
  | Phase.idle,    Event.kickoff   => Phase.running
  | Phase.idle,    Event.published => Phase.failed
  | Phase.idle,    Event.crashed   => Phase.idle
  | Phase.running, Event.kickoff   => Phase.running
  | Phase.running, Event.published => Phase.running
  | Phase.running, Event.crashed   => Phase.failed
  | Phase.done,    Event.kickoff   => Phase.done
  | Phase.done,    Event.published => Phase.done
  | Phase.done,    Event.crashed   => Phase.done
  | Phase.failed,  Event.kickoff   => Phase.failed
  | Phase.failed,  Event.published => Phase.failed
  | Phase.failed,  Event.crashed   => Phase.failed

def may_publish : Phase → Prop
  | Phase.idle    => False
  | Phase.running => True
  | Phase.done    => False
  | Phase.failed  => False

theorem no_publish_without_run : may_publish (transition Phase.idle Event.published) → False
  | h => h

theorem no_zombie : ∀ p e, p = Phase.failed → may_publish (transition p e) → False
  | _, Event.kickoff, rfl, h => h
  | _, Event.published, rfl, h => h
  | _, Event.crashed, rfl, h => h

theorem done_is_final : ∀ e, transition Phase.done e = Phase.done
  | Event.kickoff   => rfl
  | Event.published => rfl
  | Event.crashed   => rfl

theorem failed_is_final : ∀ e, transition Phase.failed e = Phase.failed
  | Event.kickoff   => rfl
  | Event.published => rfl
  | Event.crashed   => rfl

theorem never_failed : transition (transition (transition Phase.idle Event.kickoff) Event.published) Event.published = Phase.running :=
  rfl

/-- Crashed workers cannot publish. -/
theorem crashed_cannot_publish : may_publish (transition (transition Phase.idle Event.kickoff) Event.crashed) → False
  | h => h

/-! 4. Tuning -/

structure Tuning : Type where
  queue_size   : Nat  -- QUEUE
  dedupe_cap   : Nat  -- DEDUPE_CAP
  crew_timeout : Nat  -- crew_timeout (seconds)
  steps        : Nat  -- steps per crew run
  step_cost    : Nat  -- seconds per step
  deriving Repr

def defaults : Tuning :=
  { queue_size := 32, dedupe_cap := 256, crew_timeout := 3600, steps := 4, step_cost := 900 }

/-- A tuning is safe when the dedupe window is big enough for the queue and
the crew budget fits inside the timeout. -/
structure WellTuned (t : Tuning) : Prop where
  dedupe_window : t.queue_size ≤ t.dedupe_cap
  crew_budget   : t.steps * t.step_cost ≤ t.crew_timeout

-- Decidable because both obligations are decidable Nat comparisons.
instance (t : Tuning) : Decidable (WellTuned t) :=
  match Nat.decLe t.queue_size t.dedupe_cap,
        Nat.decLe (t.steps * t.step_cost) t.crew_timeout with
  | isTrue h1, isTrue h2 => isTrue ⟨h1, h2⟩
  | isFalse h1, _ => isFalse fun w => h1 w.dedupe_window
  | _, isFalse h2 => isFalse fun w => h2 w.crew_budget

theorem defaults_tuned : WellTuned defaults := by
  constructor
  · native_decide
  · native_decide

/-! 5. Tuning loop -/

-- Safe operations the worker may apply on an accepted tuning.
def widen_queue (n : Nat) : Tuning :=
  { queue_size := n, dedupe_cap := n + 256, crew_timeout := 3600, steps := 4, step_cost := 900 }

theorem widen_queue_sound (n : Nat) : WellTuned (widen_queue n) := by
  constructor
  · exact Nat.le_add_right n 256
  · change 4 * 900 ≤ 3600
    native_decide

def give_more_time (t : Tuning) : Tuning :=
  { t with crew_timeout := t.crew_timeout + 1 }

theorem give_more_time_sound {t : Tuning} (h : WellTuned t) : WellTuned (give_more_time t) := by
  constructor
  · exact h.dedupe_window
  · rw [give_more_time]
    rw [← Nat.succ_eq_add_one t.crew_timeout]
    exact Nat.le_trans h.crew_budget (Nat.le_succ t.crew_timeout)

def raise_steps (t : Tuning) (o : Nat) : Tuning :=
  { queue_size := t.queue_size, dedupe_cap := t.dedupe_cap, crew_timeout := o, steps := t.steps + 1, step_cost := t.step_cost }

theorem more_steps_needs_more_time {t : Tuning} {o : Nat}
    (h : (t.steps + 1) * t.step_cost ≤ o) : t.steps * t.step_cost ≤ o := by
  rw [← Nat.succ_eq_add_one t.steps] at h
  exact Nat.le_trans (Nat.mul_le_mul_right t.step_cost (Nat.le_succ t.steps)) h

theorem more_cost_needs_more_time {t : Tuning} {o : Nat}
    (h : t.steps * (t.step_cost + 1) ≤ o) : t.steps * t.step_cost ≤ o := by
  rw [← Nat.succ_eq_add_one t.step_cost] at h
  exact Nat.le_trans (Nat.mul_le_mul_left t.steps (Nat.le_succ t.step_cost)) h

/-- An overspending tuning is rejected. -/
def greedy : Tuning :=
  { queue_size := 32, dedupe_cap := 256, crew_timeout := 3600, steps := 8, step_cost := 900 }

theorem greedy_rejected : ¬ WellTuned greedy := by
  native_decide

/-- A balanced proposal is accepted. -/
def proposal : Tuning :=
  { queue_size := 32, dedupe_cap := 512, crew_timeout := 7200, steps := 4, step_cost := 1800 }

theorem proposal_accepted : WellTuned proposal := by
  constructor
  · native_decide
  · native_decide

/-! 6. Feedback -/

inductive Verdict : Type where
  | accepted : Verdict
  | rejected : Verdict
  deriving Repr, DecidableEq

def review (t : Tuning) : Verdict :=
  if (WellTuned t) then Verdict.accepted else Verdict.rejected

structure Feedback : Type where
  verdict : Verdict
  params  : Tuning
  deriving Repr

theorem defaults_verdict : review defaults = Verdict.accepted := by
  native_decide

theorem greedy_verdict : review greedy = Verdict.rejected := by
  native_decide

end AgentHarness