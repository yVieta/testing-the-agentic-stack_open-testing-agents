-- Crew definition for the e2e engineer: runs the e2e test engineer agent.
--
-- Compile to JSON with:
--   dhall-to-json --omit-empty --file .dhall/crews/e2e.dhall \
--     --output build/e2e/crew.json

let Types = ../Types.dhall

in  { name = "e2e"
    , agents = [ "e2e_test_agent" ]
    , tasks =
        [ { name = "write_code_in_python_task"
          , description = "write python code using the pre-installed playwright library and run it against the OWASP Juice Shop web ui at {target_url}; save the generated test as playwright_test.py, probe the homepage, main routes, and forms, collecting console errors and screenshots"
          , expected_output = "playwright output with a list of issues found on the target web ui"
          , agent = "e2e_test_agent"
          }
        , { name = "not_the_results_and_task"
          , description = "review the collected playwright output, adjust playwright_test.py and re-run as needed, then write the final issues list into previous_output.md so the next agent can pick it up"
          , expected_output = "playwright running with final issues written to previous_output.md, plus the latest playwright_test.py in the working directory"
          , agent = "e2e_test_agent"
          }
        ]
    , process = Types.ProcessToJson (Types.ProcessType.Sequential {=})
    , verbose = False
    , memory = False
    } : Types.Crew