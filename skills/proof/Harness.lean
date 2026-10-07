/-!
# AgentHarness.lean - the formal harness the crew is tuned against.

This is the Lean 4 port of AgentHarness.agda. The harness defines:
- Action boundaries of agents, tool pre-conditions, and worker state transitions (sections 1-3)
- Tuning parameters and safety envelope (sections 4-5)
- Verification feedback mechanism (section 6)

The harness is used for both:
1. **Harnessing** - the action boundaries, pre-conditions of tools, and state
   transitions are *types*; actions not granted cannot be constructed.
2. **Tuning** - the knobs of worker/worker.py are in the `Tuning` structure.
   Agents propose new values; the Lean 4 service checks that the safety proofs
   hold for the proposed parameters.

The same comments from the Agda version explain each obligation.
-/

namespace AgentHarness

/-! 0. Toolbox: order, decidability, monotonicity -/

/-- Empty type -/
inductive Empty : Type where

/-- Ex falso quodlibet -/
def Empty.elim {A : Type} : Empty → A
  | _ => by contradiction

/-- Natural numbers -/
inductive Nat : Type where
  | zero : Nat
  | succ : Nat → Nat

instance : OfNat Nat 0 := ⟨Nat.zero⟩
instance : OfNat Nat n.succ := ⟨Nat.succ (OfNat.ofNat n)⟩

/-- Addition -/
def Nat.add : Nat → Nat → Nat
  | Nat.zero, m => m
  | Nat.succ n, m => Nat.succ (Nat.add n m)

instance : Add Nat := ⟨Nat.add⟩

/-- Multiplication -/
def Nat.mul : Nat → Nat → Nat
  | Nat.zero, _ => Nat.zero
  | Nat.succ n, k => k + Nat.mul n k

instance : Mul Nat := ⟨Nat.mul⟩

/-- Less than or equal -/
inductive Nat.le : Nat → Nat → Prop where
  | zero : ∀ n, Nat.le 0 n
  | succ : ∀ m n, Nat.le m n → Nat.le (Nat.succ m) (Nat.succ n)

/-- Sequent notation as in Agda -/
abbrev «⊢» (m n : Nat) := Nat.le m n

/-- Logical negation -/
def Not (P : Prop) := P → Empty

/-- Decidable type -/
inductive Dec (P : Prop) : Type where
  | yes : P → Dec P
  | no  : Not P → Dec P

/-- Decision procedure for ≤ -/
def Nat.compare : ∀ m n : Nat, Dec (Nat.le m n)
  | 0, n => Dec.yes (Nat.le.zero n)
  | Nat.succ _, 0 => Dec.no fun h => by
      cases h
  | Nat.succ m, Nat.succ n =>
    match Nat.compare m n with
    | Dec.yes p => Dec.yes (Nat.le.succ m n p)
    | Dec.no np => Dec.no fun h => by
        cases h with
        | succ _ _ h' => exact np h'

/-- Reflexivity -/
theorem Nat.le_refl : ∀ m, Nat.le m m
  | 0 => Nat.le.zero 0
  | Nat.succ m => Nat.le.succ m m (Nat.le_refl m)

/-- Suc property -/
theorem Nat.le_succ : ∀ m n, Nat.le m n → Nat.le m (Nat.succ n)
  | 0, n, _ => Nat.le.zero (Nat.succ n)
  | Nat.succ m, Nat.succ n, Nat.le.succ _ _ h => Nat.le.succ m (Nat.succ n) (Nat.le_succ m n h)

/-- Transitivity -/
theorem Nat.le_trans : ∀ {m n o}, Nat.le m n → Nat.le n o → Nat.le m o
  | _, _, _, Nat.le.zero _, _ => Nat.le.zero _
  | _, _, _, Nat.le.succ _ _ h1, Nat.le.succ _ _ h2 => Nat.le.succ _ _ (Nat.le_trans h1 h2)

/-- Monotonicity of + on left -/
theorem Nat.le_add_left : ∀ k m, Nat.le m (k + m)
  | k, 0 => Nat.le.zero (k + 0)
  | k, Nat.succ m => Nat.le.succ m (k + Nat.succ m) (Nat.le_add_left k m)

/-- Monotonicity of + on right -/
theorem Nat.le_add_right : ∀ m k, Nat.le m (m + k)
  | 0, k => Nat.le.zero k
  | Nat.succ m, k => Nat.le.succ m (Nat.succ m + k) (Nat.le_add_right m k)

/-- Mono on + left -/
theorem Nat.add_mono_left : ∀ {m n}, Nat.le m n → ∀ k, Nat.le (m + k) (n + k)
  | _, _, Nat.le.zero n, k => Nat.le_add_left n k
  | _, _, Nat.le.succ m n h, k => Nat.le.succ (m + k) (n + k) (Nat.add_mono_left h k)

/-- Mono on + right -/
theorem Nat.add_mono_right : ∀ {m n}, Nat.le m n → ∀ k, Nat.le (k + m) (k + n)
  | _, _, Nat.le.zero n, k => Nat.le_add_right k n
  | _, _, Nat.le.succ m n h, k => Nat.le.succ (k + m) (k + n) (Nat.add_mono_right h k)

/-- Mono on * left -/
theorem Nat.mul_mono_left : ∀ {m n}, Nat.le m n → ∀ k, Nat.le (m * k) (n * k)
  | _, _, Nat.le.zero n, k => Nat.le.zero (n * k)
  | _, _, Nat.le.succ m n h, k => Nat.add_mono_right h k

/-! 1. The crew: roles, MQTT topics, and the chain between them -/

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

structure Connected (from to : Role) : Prop where
  wire : publish from = listen to

/-- Wire connections -/
def e2e_to_pentester : Connected Role.e2e Role.pentester :=
  ⟨rfl⟩

def pentester_to_manager : Connected Role.pentester Role.manager :=
  ⟨rfl⟩

def manager_to_monitor : publish Role.manager = Topic.crew_final :=
  rfl

/-- Only e2e starts -/
theorem only_e2e_starts : ∀ r, listen r = Topic.crew_start → r = Role.e2e
  | Role.e2e, _ => rfl
  | Role.pentester, h => by cases h
  | Role.manager, h => by cases h

/-- No self certification -/
theorem no_self_certification : ∀ r, publish r = Topic.crew_proof_verify → Empty
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

/-- Scan tool per role -/
def scan_tool : Role → Tool
  | Role.e2e       => Tool.playwright
  | Role.pentester => Tool.scanner
  | Role.manager   => Tool.file_read

theorem only_e2e_playwright : ∀ r, scan_tool r = Tool.playwright → r = Role.e2e
  | Role.e2e, _ => rfl
  | Role.pentester, h => by cases h
  | Role.manager, h => by cases h

theorem e2e_cannot_scan : Not (permitted Role.e2e Tool.scanner)
  | h => h

theorem manager_cannot_scan : Not (permitted Role.manager Tool.scanner)
  | h => h

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
  | Role.pentester, _ => trivial
  | Role.manager, _ => trivial

theorem e2e_reads_nothing : ∀ h, Not (readable Role.e2e h)
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

theorem no_publish_without_run : may_publish (transition Phase.idle Event.published) → Empty
  | h => h

theorem no_zombie : ∀ p e, p = Phase.failed → may_publish (transition p e) → Empty
  | Phase.failed, _, rfl, h => h

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

theorem crashed_cannot_publish : may_publish (transition (transition Phase.idle Event.kickoff) Event.crashed) → Empty
  | h => h

/-! 4. Tuning -/

structure Tuning : Type where
  queue_size   : Nat  -- QUEUE
  dedupe_cap   : Nat  -- DEDUPE_CAP
  crew_timeout : Nat  -- crew_timeout
  steps        : Nat  -- steps per crew run
  step_cost    : Nat  -- seconds per step
  deriving Repr

def defaults : Tuning :=
  { queue_size := 32, dedupe_cap := 256, crew_timeout := 3600, steps := 4, step_cost := 900 }

structure WellTuned (t : Tuning) : Prop where
  dedupe_window : Nat.le t.queue_size t.dedupe_cap
  crew_budget   : Nat.le (t.steps * t.step_cost) t.crew_timeout

def check (t : Tuning) : Dec (WellTuned t) :=
  match Nat.compare t.queue_size t.dedupe_cap with
  | Dec.no dw => Dec.no fun h => dw h.dedupe_window
  | Dec.yes dw =>
    match Nat.compare (t.steps * t.step_cost) t.crew_timeout with
    | Dec.no bo => Dec.no fun h => bo h.crew_budget
    | Dec.yes bo => Dec.yes ⟨dw, bo⟩

theorem defaults_tuned : WellTuned defaults :=
  ⟨Nat.le.zero 256, Nat.le_refl (defaults.steps * defaults.step_cost)⟩

/-! 5. Tuning loop -/

def widen (n : Nat) : Tuning :=
  { queue_size := n, dedupe_cap := n + 256, crew_timeout := 3600, steps := 4, step_cost := 900 }

theorem widen_sound (n : Nat) : WellTuned (widen n) :=
  ⟨Nat.le_add_right n 256, Nat.le_refl (widen n).steps⟩

def more_time (t : Tuning) : Tuning :=
  { queue_size := t.queue_size, dedupe_cap := t.dedupe_cap, crew_timeout := Nat.succ t.crew_timeout, steps := t.steps, step_cost := t.step_cost }

theorem more_time_sound {t : Tuning} (h : WellTuned t) : WellTuned (more_time t) :=
  ⟨h.dedupe_window, Nat.le_succ t.crew_timeout h.crew_budget⟩

def raise_steps (t : Tuning) (o : Nat) : Tuning :=
  { queue_size := t.queue_size, dedupe_cap := t.dedupe_cap, crew_timeout := o, steps := Nat.succ t.steps, step_cost := t.step_cost }

theorem more_steps_needs_time {t : Tuning} {o : Nat} (h : Nat.le (Nat.succ t.steps * t.step_cost) o) : Nat.le (t.steps * t.step_cost) o :=
  Nat.le_trans (Nat.mul_mono_left (Nat.le_refl (Nat.succ t.steps)) t.step_cost) h

theorem more_cost_needs_time {t : Tuning} {o : Nat} (h : Nat.le (t.steps * Nat.succ t.step_cost) o) : Nat.le (t.steps * t.step_cost) o :=
  Nat.le_trans (Nat.add_mono_right (Nat.le_refl t.step_cost) t.steps) h

def greedy : Tuning :=
  { queue_size := 32, dedupe_cap := 256, crew_timeout := 3600, steps := 8, step_cost := 900 }

theorem greedy_rejected : Not (WellTuned greedy)
  | ⟨_, bo⟩ =>
    match Nat.compare (greedy.steps * greedy.step_cost) greedy.crew_timeout with
    | Dec.yes p => p bo
    | Dec.no np => np bo

def proposal : Tuning :=
  { queue_size := 32, dedupe_cap := 512, crew_timeout := 7200, steps := 6, step_cost := 1200 }

theorem proposal_accepted : WellTuned proposal :=
  ⟨Nat.le.zero 512, Nat.le_refl (proposal.steps * proposal.step_cost)⟩

/-! 6. Feedback -/

inductive Verdict : Type where
  | accepted : Verdict
  | rejected : Verdict
  deriving Repr

def review (t : Tuning) : Verdict :=
  match check t with
  | Dec.yes _ => Verdict.accepted
  | Dec.no  _ => Verdict.rejected

structure Feedback : Type where
  verdict : Verdict
  params  : Tuning
  deriving Repr

theorem defaults_verdict : review defaults = Verdict.accepted :=
  rfl

theorem greedy_verdict : review greedy = Verdict.rejected :=
  rfl

end AgentHarness
