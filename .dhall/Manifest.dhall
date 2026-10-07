-- Manifest.dhall: the crew build plan.
--
-- Each entry maps a role directory under build/ to its agent and crew
-- Dhall sources under .dhall/:
--
--   role  -> build/<role>/ (also the crew name)
--   agent -> .dhall/<agent>.dhall compiled to build/<role>/agents/<agent>.json
--   crew  -> .dhall/<crew>.dhall compiled to build/<role>/crew.json

let Role = { role : Text, agent : Text, crew : Text }

in  [ { role = "e2e", agent = "e2e_test_agent", crew = "crews/e2e" }
    , { role = "pentester", agent = "pentester_agent", crew = "crews/pentester" }
    , { role = "manager", agent = "test_manager_agent", crew = "crews/manager" }
    ] : List Role