#!/usr/bin/env python3
"""Local testing agent (no MQTT).

Runs one role's crew against the local phi-4-mini model, checks its tuning
proposal against the Lean4 harness and stores the outcome in postgres.

Runs inside the agent quadlet container (agent-setup/), with the repo mounted
read-only at /repo and the model/postgres reachable on 127.0.0.1.
"""

import json
import os
import shutil
import signal
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

REPO = Path(os.environ.get("REPO_DIR", "/repo"))
ROLE = os.environ.get("CREW_ROLE", "e2e_test_agent")
CREW_DIR = Path(os.environ.get("CREW_DIR", REPO / "build" / ROLE))
WORK = Path(os.environ.get("WORK_DIR", "/tmp/crew"))  # writable scratch (repo is ro)

MODEL_URL = os.environ.get("MODEL_URL", "http://127.0.0.1:18080/v1")
MODEL_URL = MODEL_URL.rstrip("/") + ("/v1" if MODEL_URL.rstrip("/").endswith("/v1") == False else "")
MODEL_NAME = os.environ.get("MODEL_NAME", "phi-4-mini")
TARGET_URL = os.environ.get("TARGET_URL", "")
DSN = os.environ.get("POSTGRES_DSN", "")
HARNESS = Path(os.environ.get("HARNESS_DIR", "/opt/harness"))  # lean project, baked in image
SECRETS = Path("/run/secrets/credentials.env")

# AgentHarness default Tuning: queue_size dedupe_cap crew_timeout steps step_cost.
DEFAULT_TUNING = [32, 256, 3600, 4, 900]
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


def lean_verdict(tuning):
    """Run the Lean4 harness check for the tuning; accepted/rejected/error."""
    cmd = ["lake", "env", "lean", "--run", "Main.lean"] + [str(v) for v in tuning]
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


def run_crew() -> str:
    """Run the compiled crew when present, else a direct model call."""
    if not (CREW_DIR / "crew.json").is_file():
        return direct_call()
    shutil.rmtree(WORK, ignore_errors=True)
    shutil.copytree(CREW_DIR, WORK)
    patch_llm(WORK)
    env = os.environ.copy()
    env.update({"OPENAI_API_BASE": MODEL_URL, "OPENAI_MODEL_NAME": MODEL_NAME,
                "OPENAI_API_KEY": "local"})
    inputs = json.dumps({"target_url": TARGET_URL, "role": ROLE})
    r = subprocess.run(["crewai", "run", "--inputs", inputs],
                       cwd=WORK, env=env, capture_output=True, text=True, timeout=5400)
    if r.returncode != 0:
        return f"crewai failed: {r.stderr.strip()[:400]}"
    return r.stdout.strip() or "crew ran, empty output"


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


def run_once() -> int:
    tuning = tuple(int(os.environ.get(k, DEFAULT_TUNING[i]))
                   for i, k in enumerate(["QUEUE_SIZE", "DEDUPE_CAP",
                                          "CREW_TIMEOUT", "STEPS", "STEP_COST"]))
    verdict = lean_verdict(tuning)
    print(f"role={ROLE} tuning={tuning} verdict={verdict}", flush=True)
    if verdict != "accepted":
        print("tuning rejected by the Lean4 harness, crew skipped", file=sys.stderr)
        store(ROLE, f"tuning rejected: {tuning} ({verdict})", {"verdict": verdict})
        return 1

    report = run_crew()
    print(report[-2000:], flush=True)
    store(ROLE, report, {"target": TARGET_URL, "tuning": tuning, "verdict": verdict})
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