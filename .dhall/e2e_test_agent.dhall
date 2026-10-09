-- The e2e test agent, expressed as a typed Dhall value.
--
-- Compile to JSON with:
--   dhall-to-json --omitNull --file .dhall/e2e_test_agent.dhall \
--     --output build/agents/e2e_test_agent.json

let Types = ./Types.dhall

let Agent = Types.Agent

in  { role = "e2e test agent"
    , goal = "test the OWASP Juice Shop web ui at {target_url} by writing and running playwright tests, capture screenshots and console/page errors, save the generated test as playwright_test.py (published to Odysseus) and the failures to previous_output.md for the pentester and the test manager to read"
    , backstory = "a highly skilled automation test engineer who knows playwright + python deeply; playwright and a headless chromium are pre-installed in this agent's image (PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright, launch with --no-sandbox), so always write and run real playwright tests against the live Juice Shop server"
    , llm = "openai/phi-4-mini"
    , tools = [ "FileReadTool", "FileWriterTool" ]
    , skills = Some [ "/repo/skills" ]
    , settings = { verbose = False, allow_delegation = True, planning = True }
    , guardrail = None Text
    } : Agent