# User Manual: Running Sample Test Cases

A practical guide to dispatching test cases to the **e2e engineer** and **pentester** agents via the test manager CLI.

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Quick Start](#quick-start)
3. [Using the Interactive CLI](#using-the-interactive-cli)
4. [Running a Sample E2E Test Case](#running-a-sample-e2e-test-case)
5. [Running a Sample Pentester Test Case](#running-a-sample-pentester-test-case)
6. [Running Both Agents Together](#running-both-agents-together)
7. [Monitoring Progress in Real-Time](#monitoring-progress-in-real-time)
8. [Reading Results & Findings](#reading-results--findings)
9. [Common Commands Reference](#common-commands-reference)
10. [Troubleshooting](#troubleshooting)

---

## Prerequisites

Before running test cases, ensure the stack is deployed and healthy:

```bash
# 1. Deploy the entire stack (model, SUT, MCP bus, agents)
just deploy
# OR: tofu -chdir=deploy apply -var run_interval=60 -var report_mail_to=test-manager@aigents.local

# 2. Verify all services are running
just status
# OR: python3 worker/tm_cli.py --once "/status"

# Expected output:
# model: model phi-4-mini
# store: postgres: PostgreSQL 17.x
# bus:   http://127.0.0.1:8765/mcp (reachable)
```

**Required services:**
| Service | Port | Purpose |
|---------|------|---------|
| Juice Shop (SUT) | 8080 | Target application under test |
| phi-4-mini (model) | 18080 | Primary LLM for agents |
| MCP bus | 8765 | Knowledge/control bus |
| PostgreSQL | 15432 | Persistence & reports |

---

## Quick Start

Dispatch a test case in one command:

```bash
# E2E only
python3 worker/tm_cli.py --once "/case e2e test the login page for SQL injection and XSS"

# Pentester only
python3 worker/tm_cli.py --once "/case pentester run a security sweep on the login page"

# Both agents (sequential coordination)
python3 worker/tm_cli.py --once "/case both test the login for SQLi and XSS"
```

---

## Using the Interactive CLI

Start the interactive REPL for full control:

```bash
python3 worker/tm_cli.py
# OR: just tm
```

You'll see:
```
tm@aigents >
```

**Slash commands** (type `/help` for full list):
```
/case <role> <test case>    Assign a test case (e2e|pentester|both|all)
/agents                     Show agent service status
/tasks [role]               List assigned tasks
/findings [role]            Read findings shared on bus
/process                    Show live testing process markdown
/watch                      Real-time dashboard (Ctrl+C to exit)
/status                     Model + DB + bus connectivity
/start [role]               Start agent service(s)
/stop [role]                Stop agent service(s)
/save                       Persist transcript to Postgres
/latest                     Show most recent report
/clear                      Reset conversation
/exit                       Quit
```

---

## Running a Sample E2E Test Case

### Step 1: Start the Interactive CLI

```bash
python3 worker/tm_cli.py
```

### Step 2: Check Agent Status

```bash
tm@aigents > /agents
```

Expected output:
```
| role | unit | active | enabled |
|------|------|--------|---------|
| e2e | agent-e2e.service | active | generated |
| pentester | agent-pentester.service | active | generated |
| manager | agent-manager.service | active | generated |
```

### Step 3: Dispatch an E2E Test Case

```bash
tm@aigents > /case e2e test the login page for SQL injection and XSS vulnerabilities
```

The test manager will:
1. Create a task on the MCP bus for the e2e engineer
2. The e2e agent picks up the task on its next run cycle
3. Writes Playwright tests against the Juice Shop login page
4. Executes tests and shares findings on the bus

### Step 4: Monitor Progress

```bash
tm@aigents > /tasks e2e
```

Output shows task status:
```
| id | role | status | test case | created | finished |
|----|------|--------|-----------|---------|----------|
| 54 | e2e | running | test the login page for SQL injection... | 10:45:12 | |
```

### Step 5: Read Findings

Once the task completes (`status = done`):

```bash
tm@aigents > /findings e2e
```

Output example:
```
### e2e · findings · 2026-10-10T10:47:33+00:00

**Test Case:** test the login page for SQL injection and XSS vulnerabilities

**Playwright Test Results:**
- ✅ test_login_sql_injection - PASSED
- ✅ test_login_xss - PASSED
- ✅ test_login_valid_credentials - PASSED

**Coverage:** 3/3 tests passed
**Artifacts:** screenshots/evidence in agent workspace
```

---

## Running a Sample Pentester Test Case

### Step 1: Dispatch Pentester Test Case

```bash
tm@aigents > /case pentester run a comprehensive security scan on the login page including SQLi, XSS, and authentication bypass
```

### Step 2: Monitor Pentester Tasks

```bash
tm@aigents > /tasks pentester
```

Output:
```
| id | role | status | test case | created | finished |
|----|------|--------|-----------|---------|----------|
| 55 | pentester | running | run a comprehensive security scan... | 10:48:05 | |
```

### Step 3: Read Security Findings

```bash
tm@aigents > /findings pentester
```

Output example:
```
### pentester · findings · 2026-10-10T10:52:11+00:00

**Test Case:** run a comprehensive security scan on the login page

**Vulnerabilities Found:**

| Type | Severity | Location | Evidence |
|------|----------|----------|----------|
| SQL Injection | HIGH | Login form - email field | `' OR '1'='1` bypasses auth |
| XSS (Reflected) | MEDIUM | Search input | `<script>alert(1)</script>` executes |
| Auth Bypass | MEDIUM | Password reset | Token prediction possible |

**Tools Used:** nmap, nikto, sqlmap, custom scripts
**Remediation:** Input validation, parameterized queries, CSP headers
```

---

## Running Both Agents Together

### Coordinated Testing

Dispatch to both agents for end-to-end + security coverage:

```bash
tm@aigents > /case both test the user registration flow for functional correctness and security vulnerabilities
```

**What happens:**
1. Test manager creates **two tasks** (one per agent)
2. E2e engineer tests: registration works, validation messages, email verification
3. Pentester tests: SQLi in registration, XSS in username, weak password policy
4. Both share findings on the bus
5. Test manager produces consolidated report

### Monitor Both Agents

```bash
tm@aigents > /tasks
```

Shows all tasks across both roles:
```
| id | role | status | test case | created | finished |
|----|------|--------|-----------|---------|----------|
| 56 | e2e | done | test the user registration flow... | 10:50:00 | 10:52:30 |
| 57 | pentester | running | test the user registration flow... | 10:50:00 | |
```

---

## Monitoring Progress in Real-Time

### Launch the Live Dashboard

```bash
# From CLI
tm@aigents > /watch

# OR directly (non-interactive)
python3 worker/tm_cli.py --watch
python3 worker/tm_cli.py --watch --interval 2  # 2-second refresh
```

### Dashboard Layout

```
╔════════════════════════════════════════════════════════════════════╗
║  open-testing-agents  |  REAL-TIME STATUS DASHBOARD             ║
╠════════════════════════════════════════════════════════════════════╣
║  Last update: 10:55:23  MCP: http://127.0.0.1:8765/mcp          ║
╠════════════════════════════════════════════════════════════════════╣
║  AGENT SERVICES (systemd)                                         ║
    | role | unit | active | enabled |
    |------|------|--------|---------|
    | e2e  | agent-e2e.service | active | generated |
    | pentester | agent-pentester.service | active | generated |
╠════════════════════════════════════════════════════════════════════╣
║  TEST TASKS                                                       ║
    | 56 | e2e     | done     | test registration flow... | 10:50:00 | 10:52:30 |
    | 57 | pentester | running  | test registration flow... | 10:50:00 |          |
╠════════════════════════════════════════════════════════════════════╣
║  RECENT FINDINGS (shared on bus)                                  ║
    ▸ ### e2e · findings · 10:52:30
      Registration flow: 4/4 tests passed
    ▸ ### pentester · findings · 10:51:45
      XSS found in username field...
╚═════════════════════════════════════════════════════════════════════╝
Press Ctrl+C to return to CLI
```

**Color coding:**
- **Green** = active/done
- **Yellow** = running/pending
- **Red** = failed/inactive
- **Dim** = pending/not started

---

## Reading Results & Findings

### View the Live Testing Process

```bash
tm@aigents > /process
```

Shows the markdown process document with:
- Agent control table
- All test cases with status
- Summary statistics

### Get the Latest Consolidated Report

```bash
tm@aigents > /latest
```

Returns the most recent document from Postgres (agent report or CLI transcript).

### Save Your Session

```bash
tm@aigents > /save
```

Persists the current conversation to Postgres (`tm_cli` collection).

### Persisted Files (Test Reports & Artifacts)

When agents complete a task, they write results to the persistent `results/` directory under the stack spool:

| Role | Location | Files written |
|------|----------|--------------|
| Pentester | `/var/spool/aigents/results/pentester/` | `report_pentester_task<ID>_<timestamp>.md`, `task_pentester_task<ID>_<timestamp>.json` |
| E2E | `/var/spool/aigents/results/e2e/` | `report_e2e_task<ID>_<timestamp>.md`, `task_e2e_task<ID>_<timestamp>.json`, `playwright_test_e2e_task<ID>_<timestamp>.py`, plus screenshots/videos/traces if Playwright executed |
| Manager | `/var/spool/aigents/results/manager/` | `report_manager_task<ID>_<timestamp>.md`, `task_manager_task<ID>_<timestamp>.json` |

The `_save_results_to_disk()` helper in `worker/run_agent.py` also copies any generated `playwright_test.py`, and any screenshots (`*.png`), videos (`*.webm`/`*.mp4`), or traces (`trace.zip`) found under the crew working directory into the appropriate role subfolder. The `RESULTS_DIR=/results` env var is mounted into each agent container as read-write.

---

## Common Commands Reference

| Task | Command |
|------|---------|
| Check stack health | `python3 worker/tm_cli.py --once "/status"` |
| List all agent tasks | `python3 worker/tm_cli.py --once "/tasks"` |
| List e2e tasks only | `python3 worker/tm_cli.py --once "/tasks e2e"` |
| List pentester tasks | `python3 worker/tm_cli.py --once "/tasks pentester"` |
| View e2e findings | `python3 worker/tm_cli.py --once "/findings e2e"` |
| View pentester findings | `python3 worker/tm_cli.py --once "/findings pentester"` |
| View all findings | `python3 worker/tm_cli.py --once "/findings"` |
| Show process document | `python3 worker/tm_cli.py --once "/process"` |
| Start e2e agent | `python3 worker/tm_cli.py --once "/start e2e"` |
| Stop pentester | `python3 worker/tm_cli.py --once "/stop pentester"` |
| Launch dashboard | `python3 worker/tm_cli.py --watch --interval 2` |
| Dispatch to both | `python3 worker/tm_cli.py --once "/case both <test case>"` |

---

## Sample Test Cases to Try

### E2E Test Cases

```bash
# Basic login flow
/case e2e test the login page with valid and invalid credentials

# Registration flow
/case e2e test the user registration including email verification

# Shopping cart
/case e2e test adding items to cart and checkout flow

# Search functionality
/case e2e test the product search with various queries
```

### Pentester Test Cases

```bash
# Standard security sweep
/case pentester run the standard Juice Shop security sweep

# Authentication testing
/case pentester test authentication bypass and session management flaws

# Input validation
/case pentester test all input fields for SQL injection and XSS

# API security
/case pentester scan the REST API endpoints for vulnerabilities
```

### Combined Test Cases

```bash
# Full feature + security
/case both test the password reset functionality for correctness and security

# Checkout flow
/case both test the complete checkout process including payment

# Admin panel
/case both test the admin dashboard for access control and injection flaws
```

---

## Troubleshooting

### Agents Not Picking Up Tasks

```bash
# Check agent service status
python3 worker/tm_cli.py --once "/agents"

# If inactive, restart
python3 worker/tm_cli.py --once "/start e2e"
python3 worker/tm_cli.py --once "/start pentester"

# Check agent logs
journalctl --user -u agent-e2e -f
journalctl --user -u agent-pentester -f
```

### MCP Bus Unreachable

```bash
# Check MCP service
systemctl --user status aigents-mcp

# Restart MCP bus
systemctl --user restart aigents-mcp

# Verify connectivity
curl http://127.0.0.1:8765/mcp
```

### Model Not Responding

```bash
# Check model containers
podman ps | grep -E "phi-4-mini|phi-mini-moe"

# Check model health
curl http://127.0.0.1:18080/v1/models
curl http://127.0.0.1:18081/v1/models
```

### SUT (Juice Shop) Down

```bash
# Check SUT pod
systemctl --user status sut-pod
systemctl --user status juice-shop
systemctl --user status nginx-proxy

# Direct access
curl http://127.0.0.1:3000  # Juice Shop direct
curl http://127.0.0.1:8080  # Via nginx
```

### Database Connection Issues

```bash
# Check Postgres
podman exec -it aigents-postgres-1 psql -U aigents -c "\dt"

# Check credentials
cat /var/spool/aigents/database/secrets/credentials.env
```

### No Findings Appearing

1. Wait for the agent's run interval (default 900s / 15 min)
2. Or reduce interval for testing:
   ```bash
   just pace 60  # Run every 60 seconds
   ```
3. Check if Lean 4 harness is blocking:
   ```bash
   # Lean workspace must be writable
   ls -ld /workspace/lean
   # Should show drwxrwxrwx
   ```

---

## Known Issues

### CrewAI Custom Tool Compatibility (Resolved)

**Symptom (historical):** e2e and manager agents failed at crew construction:
```
crewai failed: Traceback (most recent call last):
  File '.../crewai/project/json_loader.py', line 2083, in _resolve_custom_tool
    return tool_cls()
  File '.../pydantic/main.py', line 250, in __init__
    validated_self = self.__pydantic_validator__.validate_python(data, self_instance=self)
```
Also misread as `Input 'role' isn't referenced by any {placeholder} in the crew.` — that
message is only a **warning** from `crewai_cli/run_crew.py` (`_resolve_crew_inputs`);
it does not fail the run.

**Cause:** crewai's JSON loader did not put the copied `tools/aigents_bus.py` module
into `sys.modules`, so pydantic could not resolve the deferred `type[BaseModel]` forward
reference in `args_schema` (`not fully defined`).

**Fix:** `worker/crew_tools/aigents_bus.py` ends with
`AigentsBusTool.model_rebuild(force=True, _types_namespace=globals())`, which makes the
class concrete under both the crewai JSON loader and a plain import. All three crews
(e2e, pentester, manager) now construct and run.

### Agent `systemctl start` Hangs / Apparent Restart Loop (Fixed)

**Symptom:** `systemctl --user start|restart agent-*.service` (and the bus's
`start_agent`) blocked past the 30s MCP timeout → `pentester: FAILED`; agents
flapped with status 137 (SIGKILL) during redeploys.

**Cause:** the podman user generator turns `Wants=network-online.target` in a quadlet
into a hard dependency on `podman-user-wait-network-online.service`, which never
completes in this environment (the user-level `network-online.target` is not present).
Every `start` job queued behind it until timeout.

**Fix:** removed `After/Wants=network-online.target` from the agent and Odysseus
quadlet templates (`agent-setup/quadlet/agent.container.tftpl`,
`odysseus-setup/quadlet/*.container.tftpl`) and from the MCP bus unit
(`mcp-setup/main.tf`) since the whole stack is on loopback. `systemctl start` is now
an instant no-op for already-running agents.

---

## Understanding Task Statuses

| Status | Meaning |
|--------|---------|
| `pending` | Task created, not yet picked up by agent |
| `running` | Agent is actively working on the task |
| `done` | Task completed successfully |
| `failed` | Task failed (check findings for error details) |

---

## Understanding Agent Run Intervals

- **Default:** 900 seconds (15 minutes) - production cadence
- **Development:** 60 seconds - faster feedback
- **Change interval:** `just pace 60` or `just pace 900` (or re-run `agent-setup`/`deploy` with `-var run_interval=<seconds>`)

```bash
# Check current interval (stored in quadlet env)
grep RUN_INTERVAL /home/vieta/.config/containers/systemd/agent-pentester.container
```

---

## Persistence & Data Locations

| Data | Location |
|------|----------|
| MCP bus state | `/var/spool/aigents/mcp/mcp.db` |
| MCP seed tasks | `/var/spool/aigents/mcp/seed-tasks.json` |
| PostgreSQL data | `/var/spool/aigents/database/postgres/` |
| Agent results (reports, artifacts) | `/var/spool/aigents/results/<role>/` (e2e/pentester/manager) |
| Agent workspaces | `/var/spool/aigents/agents/<role>/` |
| Lean 4 workspace | `/workspace/lean/` |
| Model weights | `/var/spool/aigents/models/` |

---

## Stopping the Stack

```bash
# Graceful shutdown (keeps all data)
just down
# OR: tofu -chdir=deploy apply -var service_state=stopped
```

All data persists: model weights, database, agent workspaces.

---

## Advanced: Custom Test Case Templates

Create reusable test cases by editing the seed file:

```bash
# View current seed tasks
cat /var/spool/aigents/mcp/seed-tasks.json

# Edit to add your own templates
# (requires redeploy: just redeploy)
```

---

## Getting Help

```bash
# CLI help
python3 worker/tm_cli.py --once "/help"

# Just commands
just --list

# Module-specific help
tofu -chdir=agent-setup --help
tofu -chdir=mcp-setup --help
```

---

## Appendix: Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        TEST MANAGER CLI                          │
│                  (worker/tm_cli.py — /case, /watch)             │
└──────────────────────────┬──────────────────────────────────────┘
                           │ MCP bus (HTTP/JSON-RPC)
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│                      MCP KNOWLEDGE BUS                           │
│  • Task queue (assign_test_case, list_tasks, get_next_task)     │
│  • Findings exchange (submit_findings, get_findings)            │
│  • Agent control (get_agent_status, start_agent, stop_agent)    │
└──────────────────────────┬──────────────────────────────────────┘
                           │
        ┌──────────────────┼──────────────────┐
        ▼                  ▼                  ▼
┌───────────────┐  ┌───────────────┐  ┌───────────────┐
│  E2E ENGINEER │  │  PENTESTER    │  │ TEST MANAGER  │
│  (agent-e2e)  │  │ (agent-pent.) │  │ (agent-mgr)   │
│  Playwright   │  │ nmap/nikto/   │  │ Coordination  │
│  tests        │  │ sqlmap        │  │ & reporting   │
└───────┬───────┘  └───────┬───────┘  └───────┬───────┘
        │                  │                  │
        └──────────────────┼──────────────────┘
                           ▼
              ┌───────────────────────┐
              │  JUICE SHOP (SUT)     │
              │  http://127.0.0.1:8080│
              └───────────────────────┘
```

---

*Manual version: 1.0 | Stack: open-testing-agents:selfhost | Last updated: 2026-10-10*