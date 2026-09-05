-- Crew definition for PI 3: runs the test manager agent.
--
-- The pentester results are handed over over MQTT and written to
-- previous_output.md by the worker before this crew runs.
--
-- Compile to JSON with:
--   dhall-to-json --omit-empty --file .dhall/crews/pi3_manager.dhall \
--     --output build/pi3-manager/crew.json

let Types = ../Types.dhall

in  { name = "pi3-manager"
    , agents = [ "test_manager_agent" ]
    , tasks =
        [ { name = "review_and_final_report_task"
          , description = "read the security and e2e results from previous_output.md in the working directory, verify coverage and quality, and write the final markdown report summarizing all end-to-end and security test results into a file report.md"
          , expected_output = "markdown report summarizing all test results"
          , agent = "test_manager_agent"
          }
        ]
    , process = Types.ProcessToJson (Types.ProcessType.Sequential {=})
    , verbose = False
    , memory = False
    } : Types.Crew