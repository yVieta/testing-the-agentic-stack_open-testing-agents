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
          , description = "read the e2e and security results from previous_output.md in the working directory, verify coverage and quality, then write the final markdown report summarizing all end-to-end and security test results into the file report.md; reference the agent lifecycle statuses you can observe (crew/status/<role>) to note whether each phase completed"
          , expected_output = "markdown report summarizing all test results in report.md"
          , agent = "test_manager_agent"
          }
        ]
    , process = Types.ProcessToJson (Types.ProcessType.Sequential {=})
    , verbose = False
    , memory = False
    } : Types.Crew