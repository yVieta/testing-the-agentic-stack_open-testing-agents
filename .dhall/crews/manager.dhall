-- Crew definition for the test manager: reviews and writes the final report.
--
-- The pentester results are written to previous_output.md by the worker
-- before this crew runs.
--
-- Compile to JSON with:
--   dhall-to-json --omit-empty --file .dhall/crews/manager.dhall \
--     --output build/manager/crew.json

let Types = ../Types.dhall

in  { name = "manager"
    , agents = [ "test_manager_agent" ]
    , tasks =
        [ { name = "review_and_final_report_task"
          , description = "read the e2e and security results from previous_output.md in the working directory, verify coverage and quality, then write the final markdown report summarizing all end-to-end and security test results into the file report.md"
          , expected_output = "markdown report summarizing all test results in report.md"
          , agent = "test_manager_agent"
          }
        ]
    , process = Types.ProcessToJson (Types.ProcessType.Sequential {=})
    , verbose = False
    , memory = False
    } : Types.Crew