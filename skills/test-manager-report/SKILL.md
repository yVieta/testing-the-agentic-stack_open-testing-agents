---
name: test-manager-report
description: Consolidate the e2e and security test artefacts into one markdown report that narrates the test process and presents the results. Use when the test manager must read previous_output.md in the working directory and write the final report.md.
---

# Test Manager report

Produce the final test report for a run: a single markdown document that
describes **how the testing was performed** (the process) and **what it found**
(the results). The report is the deliverable the manager owns; the other agents
do not write it.

## Inputs and output

- **Input:** `previous_output.md` in the working directory. It is the running
  handover file: the e2e agent writes its issue list there, then the pentester
  appends/replaces it with the security report (findings, commands run,
  remediation). The copy you receive is the final pentester handover.
- **Also acceptable:** any role result files present in the working directory
  (e.g. `report.json`, scan logs, screenshots paths) — read them to corroborate.
- **Output:** `report.md` in the working directory, valid markdown, following
  the structure below.
- **After writing:** print a short confirmation to stdout naming `report.md`
  and the headline counts (tests run, failures, open findings).

## Process

1. **Read** `previous_output.md` in full before writing anything. Note which
   sections came from the e2e phase and which from the security phase.
2. **Reconstruct the test process** from the evidence: what was in scope, which
   suites/tools ran (playwright for e2e; nmap, nikto, nuclei, sqlmap, whatweb,
   gobuster/ffuf for security), against which target, and in what order. Write
   this as a short narrative — it explains *how* the results were obtained.
3. **Extract the results**: separate e2e functional results (passed/failed
   checks, console errors) from security findings (vulnerability, severity,
   evidence, affected URL/parameter). Do not merge the two.
4. **Cross-check coverage and quality**: did both phases actually run? Are the
   findings specific and evidenced, or vague? Flag gaps (e.g. "no injection
   testing performed") instead of implying coverage that did not happen.
5. **Write `report.md`** using the structure below. Keep it self-contained —
   a reader who never saw `previous_output.md` should understand it.
6. **Confirm** by printing the output path and the headline counts.

## Report structure

```markdown
# Test Report — <target url> — <date>

## 1. Executive summary
Two or three sentences: what was tested, overall outcome, the single most
important finding.

## 2. Scope and environment
- Target: <url>
- Date / duration, model, and how the run was triggered
- What was in scope and explicitly out of scope

## 3. Test process
### 3.1 End-to-end testing
How the e2e phase ran: the tooling (playwright), the routes/flows exercised,
how results were collected (console errors, screenshots).

### 3.2 Security testing
How the security phase ran: each tool and the commands used, what each looked
for, and any phase that could not be completed.

## 4. Results
### 4.1 End-to-end results
| Check / route | Result | Evidence |
|---------------|--------|----------|
| ...           | pass/fail | console error, screenshot, note |

### 4.2 Security findings
| # | Finding | Severity | Evidence (tool / command) | Remediation |
|---|---------|----------|---------------------------|-------------|
| 1 | ...     | High/Med/Low | ...                   | ...         |

## 5. Findings and risks
The narrative behind the tables: what the findings mean, likely impact, and
which ones block release.

## 6. Coverage gaps
What was not tested or could not be verified. State unknowns plainly.

## 7. Verdict and recommendations
Prioritised next actions (fix first / re-test / accept).
```

## Conventions

- Use fenced code blocks, tables and headings; the output is rendered, so keep
  the markdown clean.
- Every result must be traceable to evidence in the artefacts — cite the tool
  or command that produced it (e.g. `nmap -sV`, "playwright console error on
  `/cart`"). Never invent a result that is not in the inputs.
- When a value is missing, write `not tested` or `not reported`; do not guess.
- Prefer concrete URLs, parameters and messages over generic phrasing.
- The host ships `jq`, `glow`, `taskwarrior` and `gnuplot` if you need to parse
  status JSON or render the report.
- Keep the report as a single file; do not split it into multiple documents.

## Quality bar

Before finishing, check that:

- `report.md` exists in the working directory and is valid markdown;
- both the process (section 3) and the results (section 4) are present;
- e2e results and security findings are clearly separated;
- every row in the results tables has evidence and, for findings, a severity;
- coverage gaps are explicit rather than hidden;
- the executive summary matches the tables.
