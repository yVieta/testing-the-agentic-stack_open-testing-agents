-- Crew definition for PI 1: runs the e2e test engineer agent.
--
-- Compile to JSON with:
--   dhall-to-json --omit-empty --file .dhall/crews/pi1_e2e.dhall \
--     --output build/pi1-e2e/crew.json

let Types = ../Types.dhall

in  { name = "pi1-e2e"
    , agents = [ "e2e_test_agent" ]
    , tasks =
        [ { name = "write_code_in_python_task"
          , description = "write code in python for playwright and run it against the web ui at {target_url}"
          , expected_output = "output from playwright"
          , agent = "e2e_test_agent"
          }
        , { name = "not_the_results_and_task"
          , description = "not the results and change the code if needed"
          , expected_output = "playwright running"
          , agent = "e2e_test_agent"
          }
        ]
    , process = Types.ProcessToJson (Types.ProcessType.Sequential {=})
    , verbose = False
    , memory = False
    } : Types.Crew