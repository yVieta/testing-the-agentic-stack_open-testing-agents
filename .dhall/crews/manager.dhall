-- Crew definition for the test manager: the controller and monitor of the
-- whole team. It drives the e2e/pentester agents over the MCP bus, tracks
-- their state and tasks, verifies coverage, shapes the final report, and
-- publishes the process + results (notes and mail).
--
-- Compile to JSON with:
--   dhall-to-json --omit-empty --file .dhall/crews/manager.dhall \
--     --output build/manager/crew.json

let Types = ../Types.dhall

in  { name = "manager"
    , agents = [ "test_manager_agent" ]
    , tasks =
        [ { name = "monitor_agents_task"
          , description = "monitor the e2e engineer and the pentester for the fixed OWASP Juice Shop SUT at {target_url} against the assigned test case ({test_case}, extra direction: {instruction}). Use the aigents_bus tool to see the live team state: action=get_status for who is active, action=tasks for what is assigned and its status, action=findings for what they already shared. Live agent status:\n{agent_status}\nAssigned tasks:\n{task_list}"
          , expected_output = "snapshot of which agents are running, which test tasks are pending/running/done, and the latest findings"
          , agent = "test_manager_agent"
          }
        , { name = "assign_and_review_task"
          , description = "verify the e2e/pentester coverage of the test case ({test_case}, extra direction: {instruction}) against the fixed OWASP Juice Shop SUT. Talk to the team via the aigents_bus tool: action=assign to dispatch any test case a role still has to run (or a follow-up pass when the previous findings are thin), action=tasks/action=findings to re-check progress. Read the shared findings ({shared_knowledge}) and the results in previous_output.md, then write the final markdown report summarizing all end-to-end and security test results into the file report.md."
          , expected_output = "final consolidated report.md covering e2e and security results, with the team's assignments/tasks confirmed done"
          , agent = "test_manager_agent"
          }
        , { name = "report_and_release_task"
          , description = "close the testing loop with the aigents_bus tool: action=publish to publish the live testing process (tasks, agent state, findings) to the Odysseus document library, action=note (title 'Test results: manager', label test-results) to refresh the test-results note in the Odysseus web UI, and action=mail to send the final report.md as mail to the configured recipient through the Odysseus mail function. Then summarize what was tested and what the final verdict is."
          , expected_output = "testing process published to Odysseus, the manager test-results note refreshed, and the final report sent by mail"
          , agent = "test_manager_agent"
          }
        ]
    , process = Types.ProcessToJson (Types.ProcessType.Sequential {=})
    , verbose = False
    , memory = False
    } : Types.Crew