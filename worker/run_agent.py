#!/usr/bin/env python3
"""Local testing agent (no MQTT).

Runs one role's crew against the local phi-4-mini model, checks its tuning
proposal against the Lean4 harness and stores the outcome in postgres.

Runs inside the agent quadlet container (agent-setup/), with the repo mounted
read-only at /repo and the model/postgres reachable on 127.0.0.1.
"""

import hashlib
import http.cookiejar
import json
import os
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
TARGET_URL = os.environ.get("TARGET_URL", "")
DSN = os.environ.get("POSTGRES_DSN", "")
HARNESS = Path(os.environ.get("HARNESS_DIR", "/opt/harness"))  # lean project, baked in image
SECRETS = Path("/run/secrets/credentials.env")
# credentials.env written by odysseus-setup; mounted read-only (may be absent
# until that module has applied on a fresh deploy).
ODYSSEUS_SECRETS = Path(os.environ.get("ODYSSEUS_SECRETS",
                                       "/run/secrets/odysseus/credentials.env"))

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
    """Run the Lean4 harness check for this role's tuning; accepted/rejected/error."""
    cmd = ["lake", "env", "lean", "--run", "Main.lean",
           harness_role()] + [str(v) for v in tuning]
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
        doc = doc.replace('"openai/phi-4-mini"', f'"{target}"')
        doc = doc.replace('"local/phi"', f'"{target}"')
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


def run_crew() -> str:
    """Run the compiled crew when present, else a direct model call."""
    if not (CREW_DIR / "crew.json").is_file():
        return direct_call()
    refresh_crew_dir()
    patch_llm(WORK)
    ensure_venv()
    env = os.environ.copy()
    env.update({"OPENAI_API_BASE": MODEL_URL, "OPENAI_MODEL_NAME": MODEL_NAME,
                "OPENAI_API_KEY": "local"})
    inputs = json.dumps({"target_url": TARGET_URL, "role": ROLE})
    r = subprocess.run(["crewai", "run", "--inputs", inputs],
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


def direct_call() -> str:
    """No compiled crew for this role: ask the model directly."""
    prompt = (f"You are the {ROLE} agent. Test the web service at {TARGET_URL} "
              "following your role's goal and produce a markdown report of "
              "what you found.")
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

    stop_ev = None
    watcher = None
    if role == "e2e":
        stop_ev = threading.Event()
        watcher = threading.Thread(target=watch_playwright, args=(stop_ev,),
                                   daemon=True)
        watcher.start()
    report = run_crew()
    if watcher is not None:
        stop_ev.set()
        watcher.join(timeout=15)
    print(report[-2000:], flush=True)
    if role == "e2e":
        result = run_playwright()
        print(result, flush=True)
        report = f"{report}\n\n--- playwright_test.py run ---\n{result}"
    store(ROLE, report, {"target": TARGET_URL, "tuning": tuning, "verdict": verdict})
    if role == "e2e":
        publish_to_odysseus()
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