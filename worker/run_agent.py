#!/usr/bin/env python3
"""Local testing agent (MCP bus, no MQTT).

Runs one role's crew against the local phi-4-mini model (the primary agent
brain), checks its tuning
proposal against the Lean4 harness (scoped to the one deployed SUT), pulls the
test case the test manager assigned to this role from the MCP bus, feeds it the
other roles' shared findings (condensed by the fast phi-mini-moe helper model
when it is available), and publishes its own findings back to the bus and to
the Odysseus web UI as a note (`publish_results_note`).

Runs inside the agent quadlet container (agent-setup/), with the repo mounted
read-only at /repo and the model/postgres/MCP bus reachable on 127.0.0.1.
"""

import hashlib
import http.cookiejar
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
import urllib.request
from pathlib import Path

REPO = Path(os.environ.get("REPO_DIR", "/repo"))
ROLE = os.environ.get("CREW_ROLE", "e2e_test_agent")
CREW_DIR = Path(os.environ.get("CREW_DIR", REPO / "build" / ROLE))
WORK = Path(os.environ.get("WORK_DIR", "/tmp/crew"))  # writable scratch (repo is ro)

MODEL_URL = os.environ.get("MODEL_URL", "http://127.0.0.1:18080/v1").rstrip("/")
if not MODEL_URL.endswith("/v1"):
    MODEL_URL += "/v1"
MODEL_NAME = os.environ.get("MODEL_NAME", "phi-4-mini")

# Secondary fast model (phi-mini-moe): condenses shared findings before they
# enter the primary's context. Optional — empty URL disables the condense step.
FAST_MODEL_URL = os.environ.get("MODEL_FAST_URL", "").rstrip("/")
FAST_MODEL_NAME = os.environ.get("MODEL_FAST_NAME", "phi-mini-moe")
if FAST_MODEL_URL and not FAST_MODEL_URL.endswith("/v1"):
    FAST_MODEL_URL += "/v1"
TARGET_URL = os.environ.get("TARGET_URL", "")
DSN = os.environ.get("POSTGRES_DSN", "")
HARNESS = Path(os.environ.get("HARNESS_DIR", "/opt/harness"))  # lean project, baked in image
SECRETS = Path("/run/secrets/credentials.env")
# credentials.env written by odysseus-setup; mounted read-only (may be absent
# until that module has applied on a fresh deploy).
ODYSSEUS_SECRETS = Path(os.environ.get("ODYSSEUS_SECRETS",
                                       "/run/secrets/odysseus/credentials.env"))

# --- MCP bus client (worker/mcp_bus.py sits next to this file) ----------------
# The bus is where the roles exchange findings and the manager dispatches test
# cases. It is optional: if the module/endpoint is absent every call degrades to
# a no-op and the worker still runs its default, SUT-focused test case.
sys.path.insert(0, str(Path(__file__).resolve().parent))
try:
    import mcp_bus
except Exception:  # pragma: no cover - bus is optional
    mcp_bus = None

MCP_URL = os.environ.get("MCP_URL", "http://127.0.0.1:8765/mcp")

# AgentHarness default Tuning per role: queue_size dedupe_cap crew_timeout
# steps step_cost. The e2e crew runs many quick playwright tests, the pentester
# runs slow nmap/nikto/sqlmap scans, the manager reviews and shapes the report;
# the per-role envelopes live in skills/lean/AgentHarness.lean.
DEFAULT_TUNING = {
    "e2e":       [32, 256, 3600, 4, 600],
    "pentester": [32, 256, 4800, 4, 1200],
    "manager":   [32, 256, 3600, 4, 900],
}
# build/<role> dir names and agent names -> harness Role (Main.lean arg).
HARNESS_ROLE = {
    "e2e": "e2e",             "e2e_test_agent": "e2e",
    "pentester": "pentester", "pentester_agent": "pentester",
    "manager": "manager",     "test_manager_agent": "manager",
}
INTERVAL = int(os.environ.get("RUN_INTERVAL", "900"))  # seconds between runs

# Fallback test case per role for when the manager has not assigned one. Every
# run still focuses on the one deployed SUT (OWASP Juice Shop).
DEFAULT_CASES = {
    "e2e": (
        "Run the standard Juice Shop end-to-end regression against the SUT: load "
        "the home page, register/login, browse the product catalogue, search, add "
        "an item to the basket and reach checkout. Assert there are no page or "
        "console errors and save the test as playwright_test.py."
    ),
    "pentester": (
        "Run the standard Juice Shop security sweep against the SUT: fingerprint "
        "the app, probe the login for SQL injection and XSS, check the REST API "
        "and the /administration area, and record each finding with evidence and "
        "severity."
    ),
    "manager": (
        "Review the e2e and pentester findings for the fixed OWASP Juice Shop "
        "SUT, verify coverage against the assigned test case, and consolidate "
        "them into the final report."
    ),
}

stop = False


def load_secrets() -> None:
    """Sneak in POSTGRES_DSN etc from the mounted credentials.env file."""
    if DSN or not SECRETS.exists():
        return
    for line in SECRETS.read_text().splitlines():
        if "=" not in line or line.startswith("#"):
            continue
        k, _, v = line.partition("=")
        os.environ.setdefault(k.strip(), v.strip())


def harness_role() -> str:
    """Map this worker's role to the Lean4 harness Role name.

    The quadlet units set CREW_DIR=/repo/build/<role>, which is exactly the
    harness Role; fall back to the agent name for direct runs.
    """
    name = Path(CREW_DIR).name
    if name in HARNESS_ROLE:
        return HARNESS_ROLE[name]
    return HARNESS_ROLE.get(ROLE, "e2e")


def lean_verdict(tuning):
    """Run the Lean4 harness check for this role's tuning; accepted/rejected/error.

    The configured TARGET_URL is passed as the optional SUT argument: the
    harness rejects any target other than the deployed OWASP Juice Shop, so the
    crew is provably scoped to the one SUT.
    """
    cmd = ["lake", "env", "lean", "--run", "Main.lean",
           harness_role()] + [str(v) for v in tuning]
    if TARGET_URL:
        cmd.append(TARGET_URL)
    r = subprocess.run(cmd, cwd=HARNESS, capture_output=True, text=True, timeout=300)
    out = r.stdout.strip().lower()
    if out in ("accepted", "rejected"):
        return out
    return f"lean-error: {out} {r.stderr.strip()[:200]}"


def patch_llm(adir: Path) -> None:
    """Point dhall's llm field at the local model (litellm `openai/` provider)."""
    target = f"openai/{MODEL_NAME}"
    for f in adir.rglob("*.json"):
        try:
            doc = f.read_text()
        except OSError:
            continue
        if '"llm"' not in doc:
            continue
        # Rewrite whatever alias the dhall compiled in (phi-4-mini today,
        # phi-mini-moe/old exports historically) to the locally served model.
        doc = re.sub(r'("llm"\s*:\s*)"[^"]*"', rf'\1"{target}"', doc)
        f.write_text(doc)


def refresh_crew_dir() -> None:
    """Copy the compiled crew under build/ into the writable WORK dir.

    The installed `.venv` and uv lockfile are kept across runs so crewai's
    uv runner treats the environment as ready (otherwise every cycle
    rebuilds a bare venv that crashes on `import click`).
    """
    WORK.mkdir(parents=True, exist_ok=True)
    for entry in WORK.iterdir():
        if entry.name in (".venv", "uv.lock", "poetry.lock"):
            continue
        if entry.is_dir():
            shutil.rmtree(entry, ignore_errors=True)
        else:
            entry.unlink(missing_ok=True)
    for entry in CREW_DIR.iterdir():
        dst = WORK / entry.name
        if entry.is_dir():
            if dst.exists():
                shutil.rmtree(dst, ignore_errors=True)
            shutil.copytree(entry, dst)
        else:
            shutil.copy2(entry, dst)
    # crewAI's `custom:<name>` tools resolve to <WORK>/tools/<name>.py.
    tools_src = REPO / "worker" / "crew_tools"
    if tools_src.is_dir():
        tools_dst = WORK / "tools"
        if tools_dst.exists():
            shutil.rmtree(tools_dst, ignore_errors=True)
        shutil.copytree(tools_src, tools_dst)


def ensure_venv() -> None:
    """Give crewai's uv runner a venv that can see the image's site-packages.

    crewai >= 1.15 shells out to `uv sync` which builds a fresh, isolated
    venv by default; that venv lacks crewai/click/litellm and dies with
    `ModuleNotFoundError: No module named 'click'`. Pre-seeding a
    `--system-site-packages` venv that uv then reuses fixes it.
    """
    if not (WORK / ".venv").is_dir():
        subprocess.run(
            ["python3", "-m", "venv", "--system-site-packages",
             str(WORK / ".venv")],
            check=True, timeout=120)


def run_crew(inputs_extra: dict | None = None) -> str:
    """Run the compiled crew when present, else a direct model call."""
    if not (CREW_DIR / "crew.json").is_file():
        return direct_call(inputs_extra or {})
    refresh_crew_dir()
    patch_llm(WORK)
    ensure_venv()
    env = os.environ.copy()
    env.update({"OPENAI_API_BASE": MODEL_URL, "OPENAI_MODEL_NAME": MODEL_NAME,
                "OPENAI_API_KEY": "local", "MCP_URL": MCP_URL})
    inputs = {"target_url": TARGET_URL, "role": ROLE}
    inputs.update(inputs_extra or {})
    r = subprocess.run(["crewai", "run", "--inputs", json.dumps(inputs)],
                       cwd=WORK, env=env, capture_output=True, text=True, timeout=5400)
    if r.returncode != 0:
        return f"crewai failed: {r.stderr.strip()[:400]}"
    return r.stdout.strip() or "crew ran, empty output"


def run_playwright(timeout: int = 1800) -> str:
    """Execute the crew's generated playwright_test.py against the SUT.

    The crew agents only carry crewAI's file tools (the framework ships no local
    code-execution tool), so the runner is what actually drives the browser.
    Best-effort: a missing or failing test must not abort the loop.
    """
    script = WORK / "playwright_test.py"
    if not script.is_file():
        return "no playwright_test.py generated"
    env = os.environ.copy()
    env.setdefault("PLAYWRIGHT_BROWSERS_PATH", "/opt/ms-playwright")
    try:
        r = subprocess.run(["python3", str(script)], cwd=WORK, env=env,
                           capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return f"playwright_test.py timed out after {timeout}s"
    status = "passed" if r.returncode == 0 else f"failed (exit {r.returncode})"
    tail = (r.stdout + "\n" + r.stderr).strip()
    return f"playwright_test.py {status}\n{tail[-1500:]}"


def condense(text: str, max_chars: int = 4000) -> str:
    """Compress long shared findings with the fast model into a short brief.

    The fast model (phi-mini-moe) is cheap and fast on short windows, so it is
    ideal for this grunt work — that is how it supports the primary agent
    brain: keeping the knowledge injected into the crew small. Falls back to
    the raw text when the fast model is not configured or unreachable, so the
    primary model alone always works.
    """
    if not FAST_MODEL_URL or not (text or "").strip() or len(text) <= 800:
        return text
    prompt = (
        "Condense the following testing findings into a terse bullet brief. "
        "Keep every distinct finding, the affected feature/area, and its "
        "severity; drop filler and duplicates. Output only the brief.\n\n"
        f"{text[:16000]}\n"
    )
    body = json.dumps({"model": FAST_MODEL_NAME, "messages": [
        {"role": "system", "content": prompt}], "stream": False,
        "max_tokens": 700}).encode()
    req = urllib.request.Request(f"{FAST_MODEL_URL}/chat/completions", data=body,
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=600) as resp:
            data = json.load(resp)
        condensed = data["choices"][0]["message"]["content"].strip()
    except Exception as e:  # noqa: BLE001 - fast model may be warming up
        print(f"fast-model condense failed ({e}); using raw findings",
              file=sys.stderr)
        return text
    return condensed[:max_chars] if condensed else text


def direct_call(inputs: dict | None = None) -> str:
    """No compiled crew for this role: ask the model directly."""
    inputs = inputs or {}
    prompt = (
        f"You are the {ROLE} agent. The system under test is the OWASP Juice "
        f"Shop at {TARGET_URL}.\n"
        f"Test case: {inputs.get('test_case', '')}\n"
        f"{inputs.get('instruction', '')}\n"
        "Findings the other agents have already shared:\n"
        f"{inputs.get('shared_knowledge') or '(none yet)'}\n"
        "Following your role's goal, produce a markdown report of what you found."
    )
    body = json.dumps({"model": MODEL_NAME, "messages": [
        {"role": "system", "content": prompt}], "stream": False}).encode()
    req = urllib.request.Request(f"{MODEL_URL}/chat/completions", data=body,
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=900) as resp:
            data = json.load(resp)
        return data["choices"][0]["message"]["content"]
    except Exception as e:  # model may still be warming up
        return f"model-unavailable: {e}"


def store(collection: str, content: str, metadata: dict) -> None:
    if not DSN:
        print("POSTGRES_DSN unset, skipping storage", file=sys.stderr)
        return
    import psycopg  # shipped in the agent image
    with psycopg.connect(DSN) as conn:
        conn.execute(
            "INSERT INTO documents (collection, source, content, metadata) "
            "VALUES (%s, %s, %s, %s)",
            (collection, f"role:{ROLE}", content, json.dumps(metadata)))
        conn.commit()


# --- publish generated Playwright code to Odysseus ---------------------------

PLAYWRIGHT_MARKERS = ("playwright", "sync_playwright", "async_playwright",
                      "page.goto")
_ODY_LANGUAGE = {".py": "python", ".ts": "typescript", ".js": "javascript"}


def _read_env_file(path: Path) -> dict:
    """Parse a shell-style KEY="value" file into a dict (best effort)."""
    env = {}
    try:
        lines = path.read_text().splitlines()
    except OSError:
        return env
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        env[key.strip()] = val.strip().strip('"').strip("'")
    return env


def _ody_request(opener, base: str, method: str, path: str, payload=None):
    """JSON request through an authed opener; returns the decoded body."""
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(base + path, data=data, method=method,
                                 headers={"Content-Type": "application/json"})
    with opener.open(req, timeout=60) as resp:
        body = resp.read()
    return json.loads(body) if body else {}


def playwright_files() -> list:
    """Generated Playwright tests the e2e crew wrote into the scratch dir.

    `playwright_test.py` is the filename the skill fixes as the contract, so it
    is always included; any other .py/.ts/.js file that references playwright is
    picked up too.
    """
    found = []
    for p in sorted(WORK.rglob("*")):
        if not p.is_file() or ".venv" in p.parts:
            continue
        if p.suffix not in (".py", ".ts", ".js"):
            continue
        try:
            text = p.read_text(errors="ignore")
        except OSError:
            continue
        if p.name == "playwright_test.py" or any(m in text for m in PLAYWRIGHT_MARKERS):
            found.append(p)
        if len(found) >= 20:
            break
    return found


def publish_files(paths) -> None:
    """Publish the given generated files to the Odysseus document library.

    Documents are keyed by title, so re-publishing updates the same entry
    instead of piling up new versions. Raises on any failure so callers decide
    whether to swallow it.
    """
    creds = _read_env_file(ODYSSEUS_SECRETS)
    password = creds.get("ODYSSEUS_ADMIN_PASSWORD", "")
    if not password:
        raise RuntimeError("odysseus creds unavailable")
    base = creds.get("ODYSSEUS_URL", "http://127.0.0.1:7000").rstrip("/")
    user = creds.get("ODYSSEUS_ADMIN_USER", "admin")
    opener = urllib.request.build_opener(
        urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
    _ody_request(opener, base, "POST", "/api/auth/login",
                 {"username": user, "password": password, "remember": True})
    library = _ody_request(opener, base, "GET",
                           "/api/documents/library?limit=50")
    existing = {d.get("title"): d.get("id")
                for d in library.get("documents", [])}
    for path in paths:
        content = path.read_text(errors="ignore")
        title = f"Playwright: {path.name}"
        language = _ODY_LANGUAGE.get(path.suffix, "text")
        if existing.get(title):
            _ody_request(opener, base, "PUT",
                         f"/api/document/{existing[title]}",
                         {"content": content})
            print(f"odysseus: updated document {title}", flush=True)
        else:
            doc = _ody_request(opener, base, "POST", "/api/document",
                               {"title": title, "language": language,
                                "content": content})
            existing[title] = doc.get("id")
            print(f"odysseus: published document {title}", flush=True)


def publish_to_odysseus() -> None:
    """Publish the current generated Playwright code (best effort)."""
    if harness_role() != "e2e":
        return
    files = playwright_files()
    if not files:
        print("no generated playwright code to publish", file=sys.stderr)
        return
    try:
        publish_files(files)
    except Exception as e:  # noqa: BLE001 - publishing must not break testing
        print(f"odysseus publish failed: {e}", file=sys.stderr)


def watch_playwright(stop_event) -> None:
    """Publish generated code as it changes *while the crew is still running*.

    crewai is synchronous and a full run can take many minutes, so without this
    the generated test would only surface in Odysseus after the whole crew
    finished. Republishing only when the file content changes avoids version
    churn.
    """
    seen = {}
    while not stop_event.is_set():
        for p in playwright_files():
            try:
                digest = hashlib.sha256(p.read_bytes()).hexdigest()
            except OSError:
                continue
            if seen.get(p) == digest:
                continue
            seen[p] = digest
            try:
                publish_files([p])
            except Exception as e:  # noqa: BLE001
                print(f"odysseus publish failed: {e}", file=sys.stderr)
        stop_event.wait(10)


# --- MCP bus: task fetch, knowledge exchange, progress -----------------------

def fetch_task(role: str):
    """Pull this role's next assigned test case from the bus (marks it running).

    Returns ``(task_or_None, test_case)``; falls back to the role's default,
    SUT-focused test case when the manager has not assigned anything.
    """
    if mcp_bus is None:
        return None, DEFAULT_CASES.get(role, "")
    try:
        task = mcp_bus.get_next_task(role)
    except Exception as e:  # noqa: BLE001
        print(f"mcp: get_next_task({role}) failed: {e}", file=sys.stderr)
        task = None
    if task and task.get("test_case"):
        return task, task["test_case"]
    return task, DEFAULT_CASES.get(role, "")


def fetch_knowledge(limit: int = 6) -> str:
    """Read the findings the other roles have shared on the bus."""
    if mcp_bus is None:
        return ""
    try:
        text = mcp_bus.get_findings(limit=limit)
    except Exception as e:  # noqa: BLE001
        print(f"mcp: get_findings failed: {e}", file=sys.stderr)
        return ""
    if text.strip().startswith("_no findings"):
        return ""
    return text


def _run_failed(report: str) -> bool:
    """Heuristic: a broken crew/execution must not close the task as 'done'.

    Matches the failure strings produced by run_crew()/run_playwright(). A
    failed run is recorded on the bus as status 'failed' instead, so the
    manager's monitoring and the final report stay honest.
    """
    text = report or ""
    lowered = text.lower()
    return (lowered.lstrip().startswith("crewai failed:")
            or "playwright_test.py failed" in lowered
            or "playwright_test.py timed out" in lowered
            or "no playwright_test.py generated" in lowered)


def share_findings(role: str, task, report: str) -> None:
    """Submit this run's report as shared knowledge and close the task.

    success=False records a broken run as task status 'failed' (the bus marks
    it 'done' only when the run actually passed).
    """
    if mcp_bus is None or not (report or "").strip():
        return
    task_id = task.get("id") if task else None
    try:
        mcp_bus.submit_findings(role, task_id, report, kind="findings",
                                success=not _run_failed(report))
        print(f"mcp: submitted findings for {role} (task {task_id})", flush=True)
    except Exception as e:  # noqa: BLE001
        print(f"mcp: submit_findings failed: {e}", file=sys.stderr)


def manager_ensure_team_case(test_case: str, instruction: str) -> list[str]:
    """The test manager commands the team: dispatch the assigned test case to
    any worker that does not already have it open (pending/running).

    This makes the manager agent the deterministic commander of the e2e
    engineer and the pentester: a case assigned to the manager is guaranteed to
    reach both workers over the bus (with the manager's extra direction), even
    if the manager crew itself never calls the assign action. Returns the
    roles that received a fresh task.
    """
    if mcp_bus is None or not (test_case or "").strip():
        return []
    dispatched = []
    for role in ("e2e", "pentester"):
        try:
            if mcp_bus.has_open_task(role, test_case).strip().lower() == "no":
                mcp_bus.assign_test_case(role, test_case,
                                         instruction or "", start=False)
                dispatched.append(role)
        except Exception as e:  # noqa: BLE001
            print(f"mcp: manager dispatch to {role} failed: {e}", file=sys.stderr)
    return dispatched


def publish_process() -> None:
    """Publish the live testing-process markdown to Odysseus (best effort)."""
    if mcp_bus is None:
        return
    try:
        mcp_bus.publish_process()
        print("mcp: published testing process to Odysseus", flush=True)
    except Exception as e:  # noqa: BLE001
        print(f"mcp: publish_process failed: {e}", file=sys.stderr)


def publish_results_note(report: str) -> None:
    """Publish this run's test results as a note in the Odysseus web UI.

    The web Notes panel is where the results are visible to the user; unlike
    the Playwright code documents, this is the human-facing report per role.
    The stable title (per harness role) means the note is refreshed in place
    instead of stacking duplicates. Best-effort: never breaks the run.
    """
    if mcp_bus is None or not (report or "").strip():
        return
    role = harness_role()
    title = f"Test results: {role}"
    try:
        mcp_bus.publish_note(title, report, label="test-results")
        print(f"mcp: published results note {title!r} to Odysseus", flush=True)
    except Exception as e:  # noqa: BLE001
        print(f"mcp: publish_results_note failed: {e}", file=sys.stderr)


def mail_final_report(report: str, workdir: Path | None = None) -> None:
    """Send the final report as mail through the Odysseus mail function.

    The manager delivers report.md (written by the manager crew) when present,
    else the crew's markdown output. Best-effort like every other publish step:
    an unreachable bus/app or a missing SMTP account only prints a warning.
    """
    if mcp_bus is None or not (report or "").strip():
        return
    body = report
    if workdir is not None:
        for candidate in ("report.md", "report.txt"):
            p = workdir / candidate
            try:
                text = p.read_text(errors="ignore")
            except OSError:
                continue
            if text.strip():
                body = text
                break
    try:
        out = mcp_bus.mail_report(to="",
                                  subject=f"Test report: {TARGET_URL or 'aigents SUT'}",
                                  body=body)
        print(f"mcp: mail: {out}", flush=True)
    except Exception as e:  # noqa: BLE001
        print(f"mcp: mail_report failed: {e}", file=sys.stderr)


def run_once() -> int:
    role = harness_role()
    defaults = DEFAULT_TUNING[role]
    tuning = tuple(int(os.environ.get(k, defaults[i]))
                   for i, k in enumerate(["QUEUE_SIZE", "DEDUPE_CAP",
                                          "CREW_TIMEOUT", "STEPS", "STEP_COST"]))
    verdict = lean_verdict(tuning)
    print(f"role={ROLE} harness_role={role} tuning={tuning} verdict={verdict}", flush=True)
    if verdict != "accepted":
        print("tuning rejected by the Lean4 harness, crew skipped", file=sys.stderr)
        store(ROLE, f"tuning rejected: {tuning} ({verdict})", {"verdict": verdict})
        return 1

    # Pull the manager-assigned test case and the other roles' shared knowledge.
    task, test_case = fetch_task(role)
    knowledge = fetch_knowledge()
    condensed = condense(knowledge)  # fast model shrinks the injected brief
    if task:
        print(f"mcp: task #{task.get('id')} for {role}: {test_case[:160]}", flush=True)
    else:
        print(f"mcp: no assigned task for {role}; using the default test case",
              flush=True)
    if knowledge:
        print(f"mcp: feeding {len(condensed)} chars of prior findings to the crew"
              f" ({len(knowledge)} raw)",
              flush=True)

    # The manager is the team monitor: give it the live agent/task state as a
    # crew input (in addition to bus tools) so it can report who ran and when.
    inputs_extra = {
        "test_case": test_case,
        "instruction": (task or {}).get("instruction", ""),
        "shared_knowledge": condensed,
    }
    if role == "manager":
        # The manager crew's monitor task interpolates {agent_status} and
        # {task_list}, so always provide them (fallback when the bus is down).
        agent_status = "bus unavailable"
        task_list = "bus unavailable"
        if mcp_bus is not None:
            try:
                agent_status = mcp_bus.get_agent_status()
                task_list = mcp_bus.list_tasks(limit=30)
            except Exception as e:  # noqa: BLE001
                print(f"mcp: manager monitoring inputs failed: {e}", file=sys.stderr)
        inputs_extra["agent_status"] = agent_status
        inputs_extra["task_list"] = task_list

        # The manager is the team's commander: a case assigned to the manager
        # is dispatched to the e2e engineer and the pentester over the bus, so
        # it is guaranteed to reach them even if the crew does not call assign.
        if task and test_case:
            dispatched = manager_ensure_team_case(
                test_case, (task or {}).get("instruction", ""))
            if dispatched:
                print(f"mcp: manager commanded {', '.join(dispatched)} with "
                      f"'{test_case[:100]}'", flush=True)

    stop_ev = None
    watcher = None
    if role == "e2e":
        stop_ev = threading.Event()
        watcher = threading.Thread(target=watch_playwright, args=(stop_ev,),
                                   daemon=True)
        watcher.start()
    report = run_crew(inputs_extra)
    if watcher is not None:
        stop_ev.set()
        watcher.join(timeout=15)
    print(report[-2000:], flush=True)
    if role == "e2e":
        result = run_playwright()
        print(result, flush=True)
        report = f"{report}\n\n--- playwright_test.py run ---\n{result}"
    store(ROLE, report, {"target": TARGET_URL, "tuning": tuning, "verdict": verdict})
    # Exchange knowledge: publish this run to the bus (closes the task).
    share_findings(role, task, report)
    # Send the test results to the Odysseus web UI as a note (user-facing copy).
    publish_results_note(report)
    if role == "e2e":
        publish_to_odysseus()
    if role == "manager":
        publish_process()
        # Mail the final report through the Odysseus mail function (best effort).
        mail_final_report(report, WORK)
    return 0


def on_signal(signum, _frame):
    global stop
    stop = True


def main() -> int:
    load_secrets()
    global DSN
    DSN = os.environ.get("POSTGRES_DSN", DSN)

    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)

    while not stop:
        run_once()
        for _ in range(INTERVAL):
            if stop:
                break
            time.sleep(1)
    return 0


if __name__ == "__main__":
    sys.exit(main())