{-# OPTIONS --safe #-}

------------------------------------------------------------------------
-- AgentHarness.agda - the formal harness the crew is tuned against.
--
-- README, "Formal Verification with Agda":
--
--   harnessing - the action boundaries of an agent, the pre-conditions of
--     its tools and the state transitions of its worker are *types* here
--     (sections 1-3), so an action the harness does not grant cannot be
--     written down at all;
--
--   tuning - the knobs of worker/worker.py are the `Tuning` record
--     (sections 4-5). An agent proposes new values, the Agda service on
--     crew/proof/verify type-checks the proposal, and the parameters are
--     accepted only if the proofs below still hold for them.
--
-- How an agent uses this file
--   1. read it with FileReadTool (../../skills/agda/AgentHarness.agda)
--   2. copy it next to your findings, e.g. proposals/<run-id>.agda
--   3. change the `Tuning` values you need - nothing else
--   4. check it before you send it:
--        agda -i skills/agda skills/agda/AgentHarness.agda
--   5. publish the source to crew/proof/verify; the verdict - and the
--      type-checking log if it failed - arrives on crew/proof/feedback
--
-- How the statements are written
--   Everything is phrased the way the obligation is read out loud: `∀`
--   with explicit binders, premises as arguments, and `⊢` for the order
--   on ℕ. Each declaration is preceded by the same statement as a comment,
--   so the comment above a proof and the proof itself say one thing.
--
-- Dependencies
--   Only Agda.Builtin is imported, so a Pi needs neither the standard
--   library nor network access to check a proposal. `--safe` is load
--   bearing: no postulate and no unsolved meta survives it, so a clean
--   check really does establish the properties below for the proposed
--   parameters.
--
-- Sources it mirrors: worker/worker.py (the PIPELINE topics, the queue /
-- dedupe / timeout configuration, the idle-running-done-failed status)
-- and .dhall/*.dhall (the tools each agent is wired with).
------------------------------------------------------------------------
module AgentHarness where

open import Agda.Builtin.Equality using (_≡_; refl)
open import Agda.Builtin.FromNat using (Number)
open import Agda.Builtin.Nat using (Nat; zero; suc)
open import Agda.Builtin.Unit using (⊤; tt)

-- numeric literals for the tuning knobs. The standard library would hand us
-- this instance; the primitive library does not, and we stay stdlib-free.
instance
  numberNat : Number Nat
  Number.Constraint numberNat = λ _ → ⊤
  Number.fromNat numberNat = λ n → n

-- the empty type is not part of the primitive library either: every ⊥ in
-- this file is a boundary that has no inhabitant
data ⊥ : Set where

⊥-elim : ∀ (A : Set) → ⊥ → A
⊥-elim A ()

-- arithmetic is defined here rather than imported, because the builtin
-- operators are opaque on a variable argument and every proof below needs
-- `k + suc m` to compute as `suc (k + m)`

--  ∀ n .  0 + n ⊢ n
infixl 6 _+_
_+_ : Nat → Nat → Nat
zero  + m = m
suc n + m = suc (n + m)

--  ∀ n k .  n * k ⊢ k + n * k        (recursion in the number of steps)
infixl 7 _*_
_*_ : Nat → Nat → Nat
zero  * k = zero
suc n * k = k + n * k

------------------------------------------------------------------------
-- 0. Toolbox: order, decidability, monotonicity
--
-- The tuning proofs of section 5 are all "raise a knob, keep the
-- obligations", so the monotonicity lemmas below are the real content of
-- this section.
------------------------------------------------------------------------

-- the order on ℕ
infix 4 _≤_
data _≤_ : Nat → Nat → Set where
  z≤n : ∀ n → zero ≤ n
  s≤s : ∀ m n → m ≤ n → suc m ≤ suc n

-- the same relation read as a sequent: `m ⊢ n`
infix 4 _⊢_
_⊢_ : Nat → Nat → Set
m ⊢ n = m ≤ n

infix 3 ¬_
¬_ : Set → Set
¬ P = P → ⊥

data Dec (P : Set) : Set where
  yes : P → Dec P
  no  : ¬ P → Dec P

--  ∀ m n .  m ⊢ n ⊎ (m ⊬ n)          (the decision the service runs)
compare : ∀ m n → Dec (m ⊢ n)
compare zero    n       = yes z≤n
compare (suc _) zero    = no λ ()
compare (suc m) (suc n) with compare m n
... | yes p = yes (s≤s p)
... | no  np = no λ { (s≤s p) → np p }

--  ∀ m .  m ⊢ m
≤-refl : ∀ m → m ⊢ m
≤-refl zero    = z≤n
≤-refl (suc m) = s≤s (≤-refl m)

--  ∀ m n .  m ⊢ n  ⊢  m ⊢ suc n
≤-suc : ∀ m n → m ⊢ n → m ⊢ suc n
≤-suc zero    n         z≤n = z≤n
≤-suc (suc m) (suc n) p     = s≤s (≤-suc m n p)

--  ∀ m n o .  m ⊢ n  n ⊢ o  ⊢  m ⊢ o
≤-trans : ∀ m n o → m ⊢ n → n ⊢ o → m ⊢ o
≤-trans zero    n       o z≤n  _   = z≤n
≤-trans (suc m) (suc n) (suc o) (s≤s p) (s≤s q) =
  s≤s (≤-trans m n o p q)

--  ∀ k m .  m ⊢ k + m
≤-plus-left : ∀ k m → m ⊢ k + m
≤-plus-left k zero    = z≤n
≤-plus-left k (suc m) = s≤s (≤-plus-left k m)

--  ∀ m k .  m ⊢ m + k
≤-plus-right : ∀ m k → m ⊢ m + k
≤-plus-right zero    k = z≤n
≤-plus-right (suc m) k = s≤s (≤-plus-right m k)

--  ∀ m n .  m ⊢ n  ⊢  ∀ k .  m + k ⊢ n + k
+-monoˡ : ∀ m n → m ⊢ n → ∀ k → m + k ⊢ n + k
+-monoˡ zero    n       z≤n k = ≤-plus-left n k
+-monoˡ (suc m) (suc n) (s≤s p) k = s≤s (+-monoˡ m n p k)

--  ∀ m n .  m ⊢ n  ⊢  ∀ k .  k + m ⊢ k + n
+-monoʳ : ∀ m n → m ⊢ n → ∀ k → k + m ⊢ k + n
+-monoʳ zero    n       z≤n k = ≤-plus-right k n
+-monoʳ (suc m) (suc n) (s≤s p) k = s≤s (+-monoʳ m n p k)

--  ∀ m n .  m ⊢ n  ⊢  ∀ k .  m * k ⊢ n * k        (more steps)
*-monoˡ : ∀ m n → m ⊢ n → ∀ k → m * k ⊢ n * k
*-monoˡ zero    n       z≤n k = z≤n
*-monoˡ (suc m) (suc n) (s≤s p) k = +-monoʳ m n p k

--  ∀ m n .  m ⊢ n  ⊢  ∀ k .  k * m ⊢ k * n        (costlier steps)
*-monoʳ : ∀ m n → m ⊢ n → ∀ k → k * m ⊢ k * n
*-monoʳ zero    zero    z≤n       k       = z≤n
*-monoʳ zero    (suc n) z≤n       zero    = z≤n
*-monoʳ zero    (suc n) z≤n       (suc k) = z≤n
*-monoʳ (suc m) (suc n) (s≤s m≤n) zero    = z≤n
*-monoʳ (suc m) (suc n) (s≤s m≤n) (suc k) =
  ≤-trans (+-monoˡ (suc m) (suc n) (s≤s m≤n) (k * suc m))
        (+-monoʳ (k * suc m) (k * suc n)
                 (*-monoʳ (suc m) (suc n) (s≤s m≤n) k)
                 (suc n))

------------------------------------------------------------------------
-- 1. The crew: roles, MQTT topics, and the chain between them
------------------------------------------------------------------------

data Role : Set where
  e2e       : Role   -- pi1-e2e
  pentester : Role   -- pi2-pentester
  manager   : Role   -- pi3-manager

data Topic : Set where
  crew-start           : Topic  -- crew/start             kickoff
  crew-pentester-input : Topic  -- crew/pentester/input   e2e -> pentester
  crew-manager-input   : Topic  -- crew/manager/input     pentester -> manager
  crew-final           : Topic  -- crew/final             manager -> monitor
  crew-status          : Topic  -- crew/status/<role>     worker -> monitor
  crew-proof-verify    : Topic  -- crew/proof/verify      agent -> Agda
  crew-proof-feedback  : Topic  -- crew/proof/feedback    Agda -> agent

-- worker.py: the input topic of each role
listen : ∀ Role → Topic
listen e2e       = crew-start
listen pentester = crew-pentester-input
listen manager   = crew-manager-input

-- worker.py: the topic each role publishes its crew output to
publish : ∀ Role → Topic
publish e2e       = crew-pentester-input
publish pentester = crew-manager-input
publish manager   = crew-final

record Connected (from to : Role) : Set where
  constructor connected
  field wire : publish from ≡ listen to

open Connected public

--  ∀ from to .  publish from ≡ listen to  ⊢  the phases are wired
--
-- The PIPELINE of worker.py, proved rather than described: what a phase
-- publishes is exactly what the next phase listens on.

--  publish e2e ≡ listen pentester
e2e→pentester : Connected e2e pentester
e2e→pentester = connected refl

--  publish pentester ≡ listen manager
pentester→manager : Connected pentester manager
pentester→manager = connected refl

--  publish manager ≡ crew/final
manager→monitor : publish manager ≡ crew-final
manager→monitor = refl

--  ∀ r .  listen r ≡ crew/start  ⊢  r ≡ e2e
--
-- exactly one phase listens on the kickoff topic, so crew/start cannot be
-- delivered to the pentester or the manager
only-e2e-starts : ∀ r → listen r ≡ crew-start → r ≡ e2e
only-e2e-starts e2e       refl = refl
only-e2e-starts pentester ()
only-e2e-starts manager   ()

--  ∀ r .  publish r ≡ crew/proof/verify  ⊢  ⊥
--
-- the proof topics are out of band: an agent never publishes its own
-- verdict, the Agda service does
no-self-certification : ∀ r → publish r ≡ crew-proof-verify → ⊥
no-self-certification e2e       ()
no-self-certification pentester ()
no-self-certification manager   ()

------------------------------------------------------------------------
-- 2. Action boundaries and tool pre-conditions
--
-- .dhall/*.dhall wires every agent with FileReadTool + FileWriterTool.
-- What differs per role is which scanning tool may be driven and which
-- artefacts may be written.
------------------------------------------------------------------------

data Tool : Set where
  file-read   : Tool
  file-write  : Tool
  playwright  : Tool   -- e2e phase
  scanner     : Tool   -- pentester phase: nmap, nikto, nuclei, sqlmap, ffuf

--  ∀ r t .  the tool boundary of r
--
-- The missing cases are uninhabited, not merely unchecked.
permitted : ∀ Role → Tool → Set
permitted e2e       file-read  = ⊤
permitted e2e       file-write = ⊤
permitted e2e       playwright = ⊤
permitted e2e       scanner    = ⊥
permitted pentester file-read  = ⊤
permitted pentester file-write = ⊤
permitted pentester playwright = ⊥
permitted pentester scanner    = ⊤
permitted manager   file-read  = ⊤
permitted manager   file-write = ⊤
permitted manager   playwright = ⊥
permitted manager   scanner    = ⊥

-- the tool each role drives to test the target
scan-tool : ∀ Role → Tool
scan-tool e2e       = playwright
scan-tool pentester = scanner
scan-tool manager   = file-read

--  ∀ r .  scan-tool r ≡ playwright  ⊢  r ≡ e2e
only-e2e-playswright : ∀ r → scan-tool r ≡ playwright → r ≡ e2e
only-e2e-playswright e2e       refl = refl
only-e2e-playswright pentester ()
only-e2e-playswright manager   ()

--  permitted e2e scanner  ⊢  ⊥        the e2e phase has no scanner
e2e-cannot-scan : ¬ permitted e2e scanner
e2e-cannot-scan ()

--  permitted manager scanner  ⊢  ⊥    the manager runs no scanner
manager-cannot-scan : ¬ permitted manager scanner
manager-cannot-scan ()

data Artefact : Set where
  findings : Artefact   -- previous_output.md: what the worker hands on
  report   : Artefact   -- report.md: only the test manager writes it

--  ∀ r a .  the artefact boundary of r
owns : ∀ Role → Artefact → Set
owns e2e       findings = ⊤
owns e2e       report   = ⊥
owns pentester findings = ⊤
owns pentester report   = ⊥
owns manager   findings = ⊤
owns manager   report   = ⊤

--  ∀ r .  owns r report  ⊢  r ≡ manager
report-owner : ∀ r → owns r report → r ≡ manager
report-owner e2e       ()
report-owner pentester ()
report-owner manager   tt = refl

-- the handover token: which phase produced the payload the worker saved as
-- previous_output.md. worker.py writes that file only for a non-empty
-- payload, so the kickoff hands over nothing.
data Handover : Set where
  kick-off       : Handover
  from-e2e       : Handover
  from-pentester : Handover

--  ∀ r .  what worker.py hands to r
handover-of : ∀ Role → Handover
handover-of e2e       = kick-off
handover-of pentester = from-e2e
handover-of manager   = from-pentester

--  ∀ r h .  reading previous_output.md is granted to r for handover h
readable : ∀ Role → Handover → Set
readable e2e       kick-off       = ⊥
readable e2e       from-e2e       = ⊥
readable e2e       from-pentester = ⊥
readable pentester kick-off       = ⊥
readable pentester from-e2e       = ⊤
readable pentester from-pentester = ⊤
readable manager   kick-off       = ⊥
readable manager   from-e2e       = ⊥
readable manager   from-pentester = ⊤

--  ∀ r .  readable r (handover-of r)  ⊢  ⊤
--
-- the two downstream phases are handed a payload, so FileReadTool on
-- previous_output.md is typeable for them
reads-previous : ∀ r → readable r (handover-of r) → ⊤
reads-previous e2e       ()
reads-previous pentester tt = tt
reads-previous manager   tt = tt

--  ∀ h .  readable e2e h  ⊢  ⊥
--
-- the negative half: the e2e phase cannot name a readable handover at all,
-- because crew/start carries no payload
e2e-reads-nothing : ∀ h → ¬ readable e2e h
e2e-reads-nothing kick-off       ()
e2e-reads-nothing from-e2e       ()
e2e-reads-nothing from-pentester ()

------------------------------------------------------------------------
-- 3. State transitions of a worker
--
-- worker.py publishes the crew output between `_status("running")` and
-- `_status("done")`, and reports `failed` on any exception. The machine
-- below is the harness version of that code path.
------------------------------------------------------------------------

data Phase : Set where
  idle running done failed : Phase

data Event : Set where
  kickoff   : Event   -- a message arrived on the input topic
  published : Event   -- the crew output is handed to the next phase
  crashed   : Event   -- `crewai run` raised

--  ∀ p e .  the state machine of a worker
transition : ∀ Phase → Event → Phase
transition idle     kickoff   = running   -- worker.py: _status("running")
transition idle     published = failed   -- publishing without a run is a fault
transition idle     crashed   = idle      -- nothing to fail yet
transition running  kickoff   = running   -- queued while the crew is busy
transition running  published = running   -- the payload is on its way
transition running  crashed   = failed    -- worker.py: _status("failed")
transition done     kickoff   = done      -- terminal
transition done     published = done
transition done     crashed   = done
transition failed   kickoff   = failed    -- terminal
transition failed   published = failed
transition failed   crashed   = failed

--  ∀ p .  only a worker that is running a crew may hand a payload on
may-publish : ∀ Phase → Set
may-publish idle    = ⊥
may-publish running = ⊤
may-publish done    = ⊥
may-publish failed  = ⊥

--  may-publish (transition idle published)  ⊢  ⊥
--
-- 1. nothing can leave a worker whose crew never ran
no-publish-without-run : may-publish (transition idle published) → ⊥
no-publish-without-run ()

--  ∀ p e .  p ≡ failed  may-publish (transition p e)  ⊢  ⊥
--
-- 2. a failed worker never becomes publishable again, whatever arrives
no-zombie : ∀ p e → p ≡ failed → may-publish (transition p e) → ⊥
no-zombie failed e refl ()

--  ∀ e .  transition done e ≡ done
--
-- 3. terminal states are absorbing
done-is-final : ∀ e → transition done e ≡ done
done-is-final kickoff   = refl
done-is-final published = refl
done-is-final crashed   = refl

--  ∀ e .  transition failed e ≡ failed
failed-is-final : ∀ e → transition failed e ≡ failed
failed-is-final kickoff   = refl
failed-is-final published = refl
failed-is-final crashed   = refl

--  transition (transition (transition idle kickoff) published) published
--    ≡ running
--
-- 4. the honest path - kickoff, publish, publish again - never reaches
-- `failed`
never-failed : transition (transition (transition idle kickoff) published)
                             published ≡ running
never-failed = refl

--  may-publish (transition (transition idle kickoff) crashed)  ⊢  ⊥
--
-- 5. a crew that raised ends in failed, and still cannot publish
crashed-cannot-publish :
  may-publish (transition (transition idle kickoff) crashed) → ⊥
crashed-cannot-publish ()

------------------------------------------------------------------------
-- 4. Tuning: the parameters of worker/worker.py
--
-- These are the numbers an agent may propose to change. `WellTuned` is the
-- safety envelope:
--
--   * the dedupe window (DEDUPE_CAP) must not be shorter than the message
--     queue, or a message that is still queued is forgotten by `seen` and
--     handled twice;
--   * the crew must fit in CREW_TIMEOUT, or subprocess.run kills it
--     mid-flight and the phase never reports back.
------------------------------------------------------------------------

record Tuning : Set where
  constructor tuning
  field
    queue-size   : Nat   -- worker.py QUEUE          (32)
    dedupe-cap   : Nat   -- worker.py DEDUPE_CAP    (256)
    crew-timeout : Nat   -- worker.py crew_timeout  (3600 s)
    steps        : Nat   -- steps per crew run      (proposal knob)
    step-cost    : Nat   -- seconds per step        (proposal knob)

open Tuning public

-- the shipped configuration of build/<role> + worker.py
defaults : Tuning
defaults = tuning 32 256 3600 4 900

--  ∀ t .  the safety envelope of the parameters t
--
--    queue-size t   ⊢ dedupe-cap t          (the dedupe window)
--    steps t * step-cost t ⊢ crew-timeout t (the crew budget)
record WellTuned (t : Tuning) : Set where
  constructor tuned
  field
    dedupe-window : queue-size t ≤ dedupe-cap t
    crew-budget   : steps t * step-cost t ≤ crew-timeout t

open WellTuned public

--  ∀ t .  WellTuned t ⊎ ¬ WellTuned t
--
-- what the Agda service decides about a proposal
check : ∀ t → Dec (WellTuned t)
check t with compare (queue-size t) (dedupe-cap t)
         | compare (steps t * step-cost t) (crew-timeout t)
... | yes dw | yes bo = yes (tuned dw bo)
... | yes dw | no  bo = no λ { (tuned _ bo′) → bo bo′ }
... | no  dw | yes bo = no λ { (tuned dw′ _) → dw dw′ }
... | no  dw | no  bo = no λ { (tuned dw′ _) → dw dw′ }

--  WellTuned defaults          the shipped configuration is in envelope
defaults-tuned : WellTuned defaults
defaults-tuned = tuned z≤n (≤-refl (steps defaults * step-cost defaults))

------------------------------------------------------------------------
-- 5. The tuning loop
--
-- Every knob below comes with the proof that the change keeps the envelope.
-- An agent that wants a parameter outside the envelope has to prove it
-- here; that is what crew/proof/verify checks.
------------------------------------------------------------------------

--  ∀ n .  a queue of n messages with a matching dedupe window
widen : ∀ Nat → Tuning
widen n = tuning n (n + 256) 3600 4 900

--  ∀ n .  WellTuned (widen n)
--
-- more room in the queue is fine, as long as the dedupe window follows
widen-sound : ∀ n → WellTuned (widen n)
widen-sound n = tuned (≤-plus-right n 256)
                       (≤-refl (steps (widen n) * step-cost (widen n)))

--  ∀ t .  the same parameters with one more second of crew timeout
more-time : ∀ Tuning → Tuning
more-time t = tuning (queue-size t) (dedupe-cap t) (suc (crew-timeout t))
                              (steps t) (step-cost t)

--  ∀ t .  WellTuned t  ⊢  WellTuned (more-time t)
--
-- a bigger timeout is always admissible
more-time-sound : ∀ t → WellTuned t → WellTuned (more-time t)
more-time-sound t (tuned dw bo) = tuned dw (≤-suc (crew-timeout t) bo)

--  ∀ t o .  the same parameters with one more step and timeout o
raise-steps : ∀ Tuning → Nat → Tuning
raise-steps t o = tuning (queue-size t) (dedupe-cap t) o (suc (steps t))
                              (step-cost t)

--  ∀ t .  WellTuned t  suc (steps t) * step-cost t ⊢ crew-timeout t
--    ⊢  WellTuned (raise-steps t (suc (crew-timeout t)))
raise-steps-sound : ∀ t → WellTuned t →
                    suc (steps t) * step-cost t ≤ crew-timeout t →
                    WellTuned (raise-steps t (suc (crew-timeout t)))
raise-steps-sound t (tuned dw _) room = tuned dw room

--  ∀ t o .  suc (steps t) * step-cost t ⊢ o  ⊢  steps t * step-cost t ⊢ o
--
-- where the budget of a proposal goes: the product grows with the step
-- count, so one more step has to be paid for
more-steps-needs-time : ∀ t o → suc (steps t) * step-cost t ≤ o →
                       steps t * step-cost t ≤ o
more-steps-needs-time t o bo =
  ≤-trans (*-monoˡ (steps t) (suc (steps t)) (≤-refl (suc (steps t)))
                   (step-cost t))
          bo

--  ∀ t o .  steps t * suc (step-cost t) ⊢ o  ⊢  steps t * step-cost t ⊢ o
--
-- ... and the same holds for the cost of a single step
more-cost-needs-time : ∀ t o → steps t * suc (step-cost t) ≤ o →
                      steps t * step-cost t ≤ o
more-cost-needs-time t o bo =
  ≤-trans (*-monoʳ (step-cost t) (suc (step-cost t))
                   (≤-refl (suc (step-cost t))) (steps t))
          bo

--  a proposal that overruns: 8 steps of 900 s inside a 3600 s budget
greedy : Tuning
greedy = tuning 32 256 3600 8 900

--  ¬ WellTuned greedy           the checker rejects it: 7200 ⊬ 3600
greedy-rejected : ¬ WellTuned greedy
greedy-rejected (tuned _ bo) with compare (steps greedy * step-cost greedy)
                                     (crew-timeout greedy)
... | yes p = ⊥-elim Nat (p bo)
... | no  np = np bo

--  a proposal an agent could publish: 6 steps of 1200 s, twice the timeout
proposal : Tuning
proposal = tuning 32 512 7200 6 1200

--  WellTuned proposal           6 * 1200 ⊢ 7200
proposal-accepted : WellTuned proposal
proposal-accepted = tuned z≤n (≤-refl (steps proposal * step-cost proposal))

------------------------------------------------------------------------
-- 6. The reply on crew/proof/feedback
------------------------------------------------------------------------

data Verdict : Set where
  accepted : Verdict
  rejected : Verdict

--  ∀ t .  the verdict the service sends back for the parameters t
review : ∀ Tuning → Verdict
review t with check t
... | yes _ = accepted
... | no  _ = rejected

record Feedback : Set where
  constructor feedback
  field
    verdict : Verdict
    params  : Tuning   -- the parameters that were checked

--  review defaults ≡ accepted
defaults-verdict : review defaults ≡ accepted
defaults-verdict = refl

--  review greedy ≡ rejected
greedy-verdict : review greedy ≡ rejected
greedy-verdict = refl

------------------------------------------------------------------------
-- Checklist a proposal has to satisfy
--
--   [x] action boundaries    - permitted / owns / reads-previous
--   [x] tool pre-conditions  - readable, its empty cases uninhabited
--   [x] state transitions    - transition, no-zombie, done-is-final
--   [x] tuning envelope      - WellTuned, check, greedy-rejected
--   [x] verdict on the wire  - review / Feedback
--
-- If `agda` accepts a copy of this file, the proposed parameters are
-- inside the envelope and the agent may proceed.
------------------------------------------------------------------------