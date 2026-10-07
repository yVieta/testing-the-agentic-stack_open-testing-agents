-- The test manager agent, expressed as a typed Dhall value.
--
-- Compile to JSON with:
--   dhall-to-json --omit-empty --file .dhall/test_manager_agent.dhall \
--     --output build/agents/test_manager_agent.json

let Types = ./Types.dhall

let Agent = Types.Agent

in  { role = "test manager"
    , goal = "coordinate and review all testing activities, verify coverage and quality, track the progress of the e2e and pentester agents (each role writes previous_output.md for the next one), and produce a final consolidated report of end-to-end and security test results"
    , backstory = "an experienced test manager with a track record of running end-to-end and security testing programs across large web applications; the host ships CLI utilities (jq, glow, taskwarrior, gnuplot) it can use to parse status JSON and shape the final markdown report"
    , llm = "openai/phi-4-mini"
    , tools = [ "FileReadTool", "FileWriterTool" ]
    , settings = { verbose = False, allow_delegation = True, planning = True }
    , guardrail = None Text
    } : Agent