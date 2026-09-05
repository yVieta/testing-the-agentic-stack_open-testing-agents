-- The e2e test agent, expressed as a typed Dhall value.
--
-- Compile to JSON with:
--   dhall-to-json --omitNull --file .dhall/e2e_test_agent.dhall \
--     --output build/agents/e2e_test_agent.json

let Types = ./Types.dhall

let Agent = Types.Agent

in  { role = "e2e test agent"
    , goal = "test web ui interface it has issues with the ui to report the errors in there"
    , backstory = "a highly skilled automation test engineer"
    , llm = "local/phi"
    , tools = [ "FileReadTool", "FileWriterTool" ]
    , settings = { verbose = False, allow_delegation = True, planning = True }
    , guardrail = None Text
    } : Agent