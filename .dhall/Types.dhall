-- Well-typed schema for the crewAI JSON-first configuration.
--
-- These types mirror the fields crewAI reads from crew.json and
-- agents/<name>.json.  Optional fields are omitted from the generated
-- JSON when set to None (use dhall-to-json --omitNull).

-- Execution process for the crew.
let ProcessType
    : Type
    = < Sequential : {} | Hierarchical : {} >

-- Serialize a ProcessType value to the string crewAI expects.
let ProcessToJson
    : ∀(process : ProcessType) → Text
    = λ(process : ProcessType)
    → merge
      { Sequential = λ(_ : {}) → "sequential"
      , Hierarchical = λ(_ : {}) → "hierarchical"
      }
      process

-- A single task assigned to one agent.
let Task
    : Type
    = { name : Text
      , description : Text
      , expected_output : Text
      , agent : Text
      }

-- Behavior settings nested under an Agent.
let AgentSettings
    : Type
    = { verbose : Bool
      , allow_delegation : Bool
      , planning : Bool
      }

-- An agent definition (matches agents/<name>.json).
let Agent
    : Type
    = { role : Text
      , goal : Text
      , backstory : Text
      , llm : Text
      , tools : List Text
      , settings : AgentSettings
      , guardrail : Optional Text
      }

-- The crew definition (matches crew.json).
-- `process` should be built with `ProcessToJson` (e.g.
-- ProcessToJson ProcessType.Sequential {=}) so it serializes to the
-- "sequential"/"hierarchical" strings crewAI expects.
let Crew
    : Type
    = { name : Text
      , agents : List Text
      , tasks : List Task
      , process : Text
      , verbose : Bool
      , memory : Bool
      }

in  { ProcessType
    , ProcessToJson
    , Task
    , AgentSettings
    , Agent
    , Crew
    }