-- Manifest.dhall: the per-PI crew build plan.
--
-- This is the role table that used to live as bash literals inside
-- compile.sh, now expressed as typed Dhall data instead. The Makefile
-- consumes it as JSON:
--
--   dhall-to-json --file .dhall/Manifest.dhall --output build/.manifest.json
--
-- Each entry maps a role directory under build/ to its agent and crew
-- Dhall sources under .dhall/:
--
--   role  -> build/<role>/ (also the crew name)
--   agent -> .dhall/<agent>.dhall compiled to build/<role>/agents/<agent>.json
--   crew  -> .dhall/<crew>.dhall compiled to build/<role>/crew.json

let Role = { role : Text, agent : Text, crew : Text }

in  [ { role = "pi1-e2e", agent = "e2e_test_agent", crew = "crews/pi1_e2e" }
    , { role = "pi2-pentester", agent = "pentester_agent", crew = "crews/pi2_pentester" }
    , { role = "pi3-manager", agent = "test_manager_agent", crew = "crews/pi3_manager" }
    ] : List Role