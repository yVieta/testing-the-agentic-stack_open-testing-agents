-- Crew definition for the e2e engineer: runs the e2e test engineer agent.
-- The worker mediates task fetch + findings submission, and the e2e agent
-- additionally talks to the team via its `custom:aigents_bus` tool.
--
-- Compile to JSON with:
--   dhall-to-json --omit-empty --file .dhall/crews/e2e.dhall \
--     --output build/e2e/crew.json

let Types = ../Types.dhall

in  { name = "e2e"
    , agents = [ "e2e_test_agent" ]
    , tasks =
        [ { name = "write_code_in_python_task"
          , description = "execute the test case the manager assigned against the fixed OWASP Juice Shop SUT at {target_url}: {test_case}. Extra direction: {instruction}. Findings the other agents already shared: {shared_knowledge}. Write python code using the pre-installed playwright library and run it; save the generated test as playwright_test.py, probe the homepage, main routes, and forms, collecting console errors and screenshots. Keep the whole team in the loop with the aigents_bus tool: action=findings to re-read the manager's direction and the pentester's latest findings before you finish"
          , expected_output = "playwright output with a list of issues found on the target web ui"
          , agent = "e2e_test_agent"
          }
        , { name = "not_the_results_and_task"
          , description = "review the collected playwright output, adjust playwright_test.py and re-run as needed, then write the final issues list into previous_output.md so the next agent can pick it up; publish your results to the bus with the aigents_bus tool (action=note with an 'e2e' title keeps your test-results note updated in the Odysseus web UI, action=submit closes your assigned task with the playlist of found issues)"
          , expected_output = "playwright running with final issues written to previous_output.md, plus the latest playwright_test.py in the working directory"
          , agent = "e2e_test_agent"
          }
        ]
    , process = Types.ProcessToJson (Types.ProcessType.Sequential {=})
    , verbose = False
    , memory = False
    } : Types.Crew