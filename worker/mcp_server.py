#!/usr/bin/env python3
"""Aigents MCP bus — the knowledge + control server for the testing agents.

A small, dependency-free **MCP** server (JSON-RPC 2.0 over HTTP, streamable
transport) that turns the three agent services into one coordinated team:

  * **knowledge exchange** — every role submits findings here and reads the
    others' findings before it runs (`submit_findings` / `get_findings`);
  * **test-case dispatch** — the test manager (tm CLI, Odysseus chat, or its
    crewAI tool) assigns a test case to the e2e and/or pentester role
    (`assign_test_case`) and the workers pull their next task (`get_next_task`);
  * **lifecycle control** — start/stop the agent user services and read their
    state (`start_agent` / `stop_agent` / `get_agent_status`);
  * **process reporting** — publish a live markdown *Testing process* document
    to the Odysseus document library (`publish_process`);
  * **result notes** — publish the test-results markdown into the Odysseus
    **Notes** panel (Google-Keep style web UI) and list those notes
    (`publish_note` / `list_notes`);
  * **report mail** — deliver the final report as mail through the Odysseus
    mail function (`mail_report`).

It runs on the host as a systemd **user** service (mcp-setup/) so that its
`systemctl --user` control and the Odysseus document API are reachable; agents
reach it over host networking at MCP_URL (default http://127.0.0.1:8765/mcp).

State lives in a tiny SQLite database (default /var/spool/aigents/mcp/mcp.db):
it is the shared bus, deliberately separate from the Postgres report store so
the control plane has no external dependencies.

Usage:
  python3 worker/mcp_server.py --port 8765 --db /var/spool/aigents/mcp/mcp.db
"""

from __future__ import annotations

import argparse
import http.cookiejar
import json
import os
import sqlite3
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


SERVER_NAME = "aigents-mcp-bus"
SERVER_VERSION = "1.0.0"
PROTOCOL_VERSION = "2025-06-18"

ROLES = ("e2e", "pentester", "manager")
ROLE_ALIASES = {
    "e2e": ("e2e",),
    "pentester": ("pentester",),
    "manager": ("manager",),
    "both": ("e2e", "pentester"),
    "all": ROLES,
}

SUT_NAME = os.environ.get("SUT_NAME", "OWASP Juice Shop")
SUT_URL = os.environ.get("TARGET_URL", "http://127.0.0.1:8080")

DEFAULT_DB = os.environ.get("MCP_DB", "/var/spool/aigents/mcp/mcp.db")
DEFAULT_ODYSSEUS_SECRETS = os.environ.get(
    "ODYSSEUS_SECRETS", "/var/spool/aigents/odysseus/secrets/credentials.env")
DEFAULT_UNIT_PREFIX = os.environ.get("MCP_UNIT_PREFIX", "agent-")
# Default report recipient(s) for the Odysseus mail function. May also be set
# as REPORT_MAIL_TO in the odysseus credentials.env file; the env var wins.
DEFAULT_REPORT_MAIL_TO = os.environ.get("REPORT_MAIL_TO", "")
# Declarative task seed: path to a JSON file of initial jobs ({role, test_case,
# instruction}) inserted on first boot, i.e. when the tasks table is empty. It
# is rendered by mcp-setup from the repo, so a fresh deploy deterministically
# arrives at the same task queue without any imperative assignment step.
DEFAULT_SEED_JOBS = os.environ.get("SEED_JOBS", "")
# How long a `running` task may stay claimed. A worker killed mid-run leaves its
# task `running` forever, which blocks re-dispatch; after this timeout the bus
# recycles it to `pending` so the role picks it up again. Env TASK_CLAIM_TIMEOUT.
STALE_TASK_SECONDS = int(os.environ.get("TASK_CLAIM_TIMEOUT", "1800"))
PROCESS_TITLE = "Testing process"
# Label of the notes the agents write into the Odysseus Notes panel. Stable per
# role title + this label is the dedupe key: re-publishing the same title
# updates the note instead of stacking duplicates.
NOTES_LABEL = "test-results"
MAX_INLINE = 4000  # cap on a findings blob embedded in the process doc


def now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def now_offset(seconds: int) -> str:
    """UTC ISO timestamp shifted by ``seconds`` (negative = in the past)."""
    return (datetime.now(timezone.utc) +
            timedelta(seconds=seconds)).isoformat(timespec="seconds")


def _expand(role: str) -> tuple:
    """Expand a role selector (e2e/pentester/manager/both/all) to concrete roles."""
    return ROLE_ALIASES.get(str(role).strip().lower(), ())


def _read_env_file(path: Path) -> dict:
    env: dict[str, str] = {}
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


class Bus:
    """SQLite-backed knowledge + control bus; every method returns text."""

    def __init__(self, db_path: str, unit_prefix: str, odysseus_secrets: str,
                 seed_jobs: str = ""):
        self.db_path = db_path
        self.unit_prefix = unit_prefix
        self.odysseus_secrets = Path(odysseus_secrets)
        self.seed_jobs = seed_jobs

    # --- storage ------------------------------------------------------------

    def _db(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.db_path, timeout=30)
        conn.row_factory = sqlite3.Row
        return conn

    def init(self) -> None:
        Path(self.db_path).parent.mkdir(parents=True, exist_ok=True)
        with self._db() as conn:
            conn.executescript(
                """
                CREATE TABLE IF NOT EXISTS tasks (
                    id          INTEGER PRIMARY KEY AUTOINCREMENT,
                    role        TEXT    NOT NULL,
                    test_case   TEXT    NOT NULL,
                    instruction TEXT    NOT NULL DEFAULT '',
                    status      TEXT    NOT NULL DEFAULT 'pending',
                    result      TEXT    NOT NULL DEFAULT '',
                    created_at  TEXT    NOT NULL,
                    started_at  TEXT,
                    finished_at TEXT
                );
                CREATE TABLE IF NOT EXISTS knowledge (
                    id         INTEGER PRIMARY KEY AUTOINCREMENT,
                    role       TEXT    NOT NULL,
                    task_id    INTEGER,
                    kind       TEXT    NOT NULL DEFAULT 'findings',
                    content    TEXT    NOT NULL,
                    created_at TEXT    NOT NULL
                );
                """
            )
            self._seed_tasks(conn)

    def _seed_tasks(self, conn) -> None:
        """Insert the declarative initial jobs — and only on first boot.

        The seed file (written by mcp-setup from the repo) is the single source
        of truth for the initial task queue. It is applied exactly once, when
        the tasks table is still empty, so a wiped/rebuilt bus arrives at the
        same queue without any imperative assignment; once the table holds any
        row the seed is never re-applied (the manager owns dispatch from then
        on).
        """
        if not self.seed_jobs:
            return
        n = conn.execute("SELECT COUNT(*) AS n FROM tasks").fetchone()["n"]
        if n > 0:
            return
        try:
            jobs = json.loads(Path(self.seed_jobs).read_text())
        except (OSError, ValueError) as exc:
            print(f"mcp-bus: seed {self.seed_jobs} not loaded: {exc}",
                  file=sys.stderr)
            return
        if not isinstance(jobs, list) or not jobs:
            return
        inserted = 0
        created = now()
        for job in jobs:
            role = str(job.get("role", "")).strip().lower()
            case = str(job.get("test_case", "")).strip()
            if role not in ROLES or not case:
                continue
            conn.execute(
                "INSERT INTO tasks (role, test_case, instruction, status, created_at) "
                "VALUES (?, ?, ?, 'pending', ?)",
                (role, case, str(job.get("instruction", "") or "").strip(), created))
            inserted += 1
        if inserted:
            print(f"mcp-bus: seeded {inserted} initial task(s) from {self.seed_jobs}",
                  flush=True)

    # --- lifecycle ----------------------------------------------------------

    def _unit(self, role: str) -> str:
        return f"{self.unit_prefix}{role}.service"

    def _systemctl(self, action: str, role: str) -> tuple[bool, str]:
        unit = self._unit(role)
        env = os.environ.copy()
        env.setdefault("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
        try:
            r = subprocess.run(["systemctl", "--user", action, unit],
                               capture_output=True, text=True, timeout=30,
                               env=env)
        except (OSError, subprocess.SubprocessError) as exc:
            return False, str(exc)
        msg = (r.stdout + r.stderr).strip() or ("ok" if r.returncode == 0 else "")
        return r.returncode == 0, msg

    def start_agent(self, role: str = "all") -> str:
        roles = _expand(role)
        if not roles:
            return f"unknown role '{role}' (use e2e/pentester/manager/both/all)"
        lines = []
        for r in roles:
            ok, msg = self._systemctl("start", r)
            lines.append(f"- `{r}`: {'started' if ok else 'FAILED'} ({msg or 'ok'})")
        return "agent start\n" + "\n".join(lines)

    def stop_agent(self, role: str = "all") -> str:
        roles = _expand(role)
        if not roles:
            return f"unknown role '{role}' (use e2e/pentester/manager/both/all)"
        lines = []
        for r in roles:
            ok, msg = self._systemctl("stop", r)
            lines.append(f"- `{r}`: {'stopped' if ok else 'FAILED'} ({msg or 'ok'})")
        return "agent stop\n" + "\n".join(lines)

    def _unit_state(self, role: str) -> tuple[str, str]:
        env = os.environ.copy()
        env.setdefault("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
        unit = self._unit(role)

        def probe(verb: str) -> str:
            try:
                r = subprocess.run(["systemctl", "--user", verb, unit],
                                   capture_output=True, text=True, timeout=10,
                                   env=env)
                return r.stdout.strip() or "unknown"
            except (OSError, subprocess.SubprocessError):
                return "unknown"

        return probe("is-active"), probe("is-enabled")

    # --- tasks --------------------------------------------------------------

    def assign_test_case(self, role: str, test_case: str, instruction: str = "",
                         start: bool = True) -> str:
        roles = _expand(role)
        if not roles:
            return f"unknown role '{role}' (use e2e/pentester/manager/both/all)"
        if not str(test_case).strip():
            return "test_case must not be empty"
        created = now()
        ids = []
        with self._db() as conn:
            for r in roles:
                cur = conn.execute(
                    "INSERT INTO tasks (role, test_case, instruction, status, created_at) "
                    "VALUES (?, ?, ?, 'pending', ?)",
                    (r, str(test_case).strip(), str(instruction or "").strip(), created))
                ids.append((r, cur.lastrowid))
        lines = [f"- task #{i} → `{r}`" for r, i in ids]
        out = ("assigned test case\n" + "\n".join(lines)
               + f"\n\nSUT: {SUT_NAME} ({SUT_URL})")
        if start:
            out += "\n\n" + self.start_agent(role)
        return out

    def list_tasks(self, role: str = "", status: str = "", limit: int = 20) -> str:
        limit = max(1, min(int(limit or 20), 200))
        q = "SELECT * FROM tasks"
        clauses, params = [], []
        if role:
            roles = _expand(role) or (role,)
            clauses.append("role IN (" + ",".join("?" * len(roles)) + ")")
            params.extend(roles)
        if status:
            clauses.append("status = ?")
            params.append(status)
        if clauses:
            q += " WHERE " + " AND ".join(clauses)
        q += " ORDER BY id DESC LIMIT ?"
        params.append(limit)
        with self._db() as conn:
            rows = conn.execute(q, params).fetchall()
        if not rows:
            return "_no tasks_"
        out = ["| id | role | status | test case | created | finished |",
               "|----|------|--------|-----------|---------|----------|"]
        for t in rows:
            case = " ".join(str(t["test_case"]).split())[:80]
            out.append(f"| {t['id']} | {t['role']} | {t['status']} | {case} | "
                       f"{t['created_at'] or ''} | {t['finished_at'] or ''} |")
        return "\n".join(out)

    def get_next_task(self, role: str) -> str:
        role = str(role).strip().lower()
        if role not in ROLES:
            return json.dumps({"task": None, "error": f"unknown role '{role}'"})
        with self._db() as conn:
            conn.execute("BEGIN IMMEDIATE")
            # Self-healing: a `running` task whose claim expired (worker killed
            # or restarted mid-run) is recycled to `pending` so the role picks
            # it up again — the bus owns task state, no manual sqlite surgery.
            conn.execute(
                "UPDATE tasks SET status = 'pending', started_at = NULL "
                "WHERE role = ? AND status = 'running' "
                "AND started_at IS NOT NULL "
                "AND started_at <= ?",
                (role, now_offset(-STALE_TASK_SECONDS)))
            row = conn.execute(
                "SELECT * FROM tasks WHERE role = ? AND status = 'pending' "
                "ORDER BY id ASC LIMIT 1", (role,)).fetchone()
            if row is None:
                return json.dumps({"task": None})
            conn.execute("UPDATE tasks SET status = 'running', started_at = ? "
                         "WHERE id = ?", (now(), row["id"]))
            task = dict(row)
            task["status"] = "running"
        return json.dumps({"task": task})

    def has_open_task(self, role: str, test_case: str = "") -> str:
        roles = _expand(role)
        if not roles:
            return f"unknown role '{role}'"
        tc = str(test_case or "").strip().lower()
        with self._db() as conn:
            placeholders = ",".join("?" for _ in roles)
            row = conn.execute(
                f"SELECT COUNT(*) AS n FROM tasks WHERE role IN ({placeholders}) "
                "AND status IN ('pending','running')"
                " AND (? = '' OR lower(test_case) = lower(?))",
                (*roles, tc, tc)).fetchone()
            return "yes" if row["n"] > 0 else "no"

    def submit_findings(self, role: str, task_id, findings: str,
                        kind: str = "findings", success: bool = True) -> str:
        role = str(role).strip().lower()
        if role not in ROLES:
            return f"unknown role '{role}'"
        findings = str(findings or "").strip()
        if not findings:
            return "findings must not be empty"
        with self._db() as conn:
            conn.execute(
                "INSERT INTO knowledge (role, task_id, kind, content, created_at) "
                "VALUES (?, ?, ?, ?, ?)",
                (role, int(task_id) if task_id not in (None, "", "null") else None,
                 str(kind or "findings"), findings, now()))
            if task_id not in (None, "", "null"):
                # success=False records the run honestly instead of closing a
                # failed crew run as 'done' (the manager's monitoring sees it).
                conn.execute(
                    "UPDATE tasks SET status = ?, finished_at = ?, result = ? "
                    "WHERE id = ? AND role = ?",
                    ("done" if success else "failed", now(), findings,
                     int(task_id), role))
        return f"recorded {kind} for `{role}` ({len(findings)} chars)"

    def get_findings(self, role: str = "", limit: int = 10) -> str:
        limit = max(1, min(int(limit or 10), 100))
        q = "SELECT * FROM knowledge"
        params: list = []
        if role:
            roles = _expand(role) or (role,)
            q += " WHERE role IN (" + ",".join("?" * len(roles)) + ")"
            params.extend(roles)
        q += " ORDER BY id DESC LIMIT ?"
        params.append(limit)
        with self._db() as conn:
            rows = conn.execute(q, params).fetchall()
        if not rows:
            return "_no findings shared yet_"
        out = []
        for k in rows:
            content = str(k["content"])
            if len(content) > MAX_INLINE:
                content = content[:MAX_INLINE] + "\n...(truncated)"
            out.append(f"### {k['role']} · {k['kind']} · {k['created_at']}\n\n{content}")
        return "\n\n".join(out)

    # --- process ------------------------------------------------------------

    def process_markdown(self) -> str:
        lines = ["# Testing process", "",
                 f"_SUT: {SUT_NAME} — {SUT_URL} · updated {now()}_", ""]
        lines.append("## Agent control")
        lines.append("")
        lines.append("| role | unit | active | enabled | pending | running |")
        lines.append("|------|------|--------|---------|---------|---------|")
        with self._db() as conn:
            for role in ROLES:
                active, enabled = self._unit_state(role)
                pend = conn.execute(
                    "SELECT COUNT(*) FROM tasks WHERE role = ? AND status = 'pending'",
                    (role,)).fetchone()[0]
                run = conn.execute(
                    "SELECT COUNT(*) FROM tasks WHERE role = ? AND status = 'running'",
                    (role,)).fetchone()[0]
                lines.append(f"| {role} | {self._unit(role)} | {active} | {enabled} "
                             f"| {pend} | {run} |")
        lines += ["", "## Test cases", "", self.list_tasks(limit=50), "",
                  "## Findings", "", self.get_findings(limit=12), ""]
        return "\n".join(lines)

    def get_process(self) -> str:
        return self.process_markdown()

    def publish_process(self) -> str:
        markdown = self.process_markdown()
        try:
            doc_id = _publish_document(self.odysseus_secrets, PROCESS_TITLE, markdown)
        except Exception as exc:  # noqa: BLE001 - publishing must not break the bus
            return f"{markdown}\n\n---\n_Odysseus publish failed: {exc}_"
        return f"{markdown}\n\n---\n_published to Odysseus as “{PROCESS_TITLE}” (id={doc_id})_"

    # --- result notes (Odysseus Notes panel) --------------------------------

    def publish_note(self, title: str, content: str,
                     label: str = NOTES_LABEL) -> str:
        """Publish (or update) the test results as a note in the Odysseus UI.

        Same title + label overwrites the existing note, so each role keeps one
        note holding its latest results in the web Notes panel.
        """
        title = str(title or "").strip()
        content = str(content or "").strip()
        if not title or not content:
            return "publish_note requires both title and content"
        try:
            note_id = _publish_note(self.odysseus_secrets, title, content,
                                    str(label or NOTES_LABEL))
        except Exception as exc:  # noqa: BLE001 - failing publish must not halt the bus
            return f"note publish failed: {exc}"
        return f"published note “{title}” (id={note_id}, label={label or NOTES_LABEL})"

    def list_notes(self, label: str = "", limit: int = 50) -> str:
        """Return the notes currently on the Odysseus Notes panel."""
        try:
            notes = _list_notes(self.odysseus_secrets, str(label or ""))
        except Exception as exc:  # noqa: BLE001
            return f"note list failed: {exc}"
        if not notes:
            return "_no notes on Odysseus_"
        out = []
        for n in notes[: max(1, min(int(limit or 50), 200))]:
            title = n.get("title") or "(untitled)"
            updated = n.get("updated_at") or n.get("created_at") or ""
            content = " ".join(str(n.get("content") or "").split())
            if len(content) > 300:
                content = content[:300] + "…"
            out.append(f"### {title}  · label={n.get('label') or ''} · {updated}\n\n"
                       f"{content}")
        return "\n\n".join(out)

    # --- status -------------------------------------------------------------

    def get_agent_status(self, role: str = "") -> str:
        roles = _expand(role) or ROLES
        out = ["| role | unit | active | enabled |",
               "|------|------|--------|---------|"]
        for r in roles:
            active, enabled = self._unit_state(r)
            out.append(f"| {r} | {self._unit(r)} | {active} | {enabled} |")
        return "\n".join(out)

    # --- report mail (Odysseus mail function) -------------------------------

    def _report_recipient(self, to: str) -> str:
        """Resolve the mail recipient: explicit arg, env, then odysseus creds."""
        if str(to or "").strip():
            return str(to).strip()
        if DEFAULT_REPORT_MAIL_TO.strip():
            return DEFAULT_REPORT_MAIL_TO.strip()
        return (_read_env_file(self.odysseus_secrets).get("REPORT_MAIL_TO", "")
                .strip())

    def mail_report(self, to: str, subject: str, body: str) -> str:
        """Send the test report as mail through the Odysseus mail function.

        Best-effort like `publish_note`: an unreachable app or a mail account
        without SMTP is surfaced as text and never breaks the bus. The
        recipient defaults to REPORT_MAIL_TO (env or odysseus credentials.env).
        """
        recipient = self._report_recipient(to)
        subject = str(subject or "").strip() or (
            f"Test report: {SUT_NAME} ({SUT_URL})")
        body = str(body or "").strip()
        if not recipient:
            return ("mail_report requires a recipient — pass `to` or set "
                    "REPORT_MAIL_TO (env / odysseus credentials.env)")
        if not body:
            return "mail_report requires a body (the report markdown)"
        try:
            creds = _read_env_file(self.odysseus_secrets)
            opener, base = _ody_login(creds)
            resp = _ody_request(opener, base, "POST", "/api/email/send", {
                "to": recipient, "subject": subject, "body": body,
                "wait_for_delivery": True,
            })
        except Exception as exc:  # noqa: BLE001 - mail must not break the bus
            return f"mail_report failed: {exc}"
        if resp.get("success"):
            return (f"report mailed to {recipient} via Odysseus "
                    f"(subject: {subject!r})"
                    + (f" — {resp.get('message')}" if resp.get("message") else ""))
        error = resp.get("error") or resp.get("message") or resp
        return (f"report NOT mailed to {recipient}: {error}. "
                "Configure an SMTP-capable Email Account in the Odysseus UI "
                "(Settings → Email) or set SMTP_HOST/SMTP_USER/SMTP_PASSWORD/"
                "EMAIL_FROM on the odysseus-app container.")


# --- Odysseus document API (std-lib only) -------------------------------------


def _ody_request(opener, base: str, method: str, path: str, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(base + path, data=data, method=method,
                                 headers={"Content-Type": "application/json"})
    with opener.open(req, timeout=60) as resp:
        body = resp.read()
    return json.loads(body) if body else {}


def _ody_login(creds: dict):
    """Log into Odysseus and return an authed cookie opener + base URL."""
    password = creds.get("ODYSSEUS_ADMIN_PASSWORD", "")
    if not password:
        raise RuntimeError("odysseus creds unavailable")
    base = creds.get("ODYSSEUS_URL", "http://127.0.0.1:7000").rstrip("/")
    user = creds.get("ODYSSEUS_ADMIN_USER", "admin")
    opener = urllib.request.build_opener(
        urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
    _ody_request(opener, base, "POST", "/api/auth/login",
                 {"username": user, "password": password, "remember": True})
    return opener, base


def _publish_document(secrets: Path, title: str, content: str,
                      language: str = "markdown") -> object:
    creds = _read_env_file(secrets)
    opener, base = _ody_login(creds)
    library = _ody_request(opener, base, "GET", "/api/documents/library?limit=50")
    existing = {d.get("title"): d.get("id")
                for d in library.get("documents", [])}
    if existing.get(title):
        _ody_request(opener, base, "PUT", f"/api/document/{existing[title]}",
                     {"content": content})
        return existing[title]
    doc = _ody_request(opener, base, "POST", "/api/document",
                       {"title": title, "language": language,
                        "content": content})
    return doc.get("id")


def _list_notes_dict(opener, base: str, label: str = "") -> list:
    """Fetch the notes on the Odysseus Notes panel (archived excluded)."""
    path = "/api/notes?archived=false"
    if label:
        path += "&label=" + urllib.parse.quote(label)
    return _ody_request(opener, base, "GET", path).get("notes", [])


def _list_notes(secrets: Path, label: str = "") -> list:
    creds = _read_env_file(secrets)
    opener, base = _ody_login(creds)
    return _list_notes_dict(opener, base, label)


def _publish_note(secrets: Path, title: str, content: str,
                  label: str = NOTES_LABEL) -> object:
    """Write the test results as a note in the Odysseus Notes panel.

    Same title within the same label updates the existing note (deduped per
    `_list_notes_dict`), so re-running a role refreshes its note in place and
    the web UI always shows the latest results.
    """
    creds = _read_env_file(secrets)
    opener, base = _ody_login(creds)
    existing = {n.get("title"): n.get("id")
                for n in _list_notes_dict(opener, base, label)}
    if existing.get(title):
        _ody_request(opener, base, "PUT", f"/api/notes/{existing[title]}",
                     {"title": title, "content": content, "label": label})
        return existing[title]
    note = _ody_request(opener, base, "POST", "/api/notes",
                        {"title": title, "content": content, "label": label,
                         "note_type": "note", "source": "aigents"})
    return note.get("id")


# --- MCP protocol -------------------------------------------------------------

TOOLS = [
    {
        "name": "assign_test_case",
        "description": ("Assign a test case to the e2e tester and/or the pentester "
                        "for the set SUT (OWASP Juice Shop), optionally starting "
                        "the agents. This is the test manager's control function."),
        "inputSchema": {
            "type": "object",
            "properties": {
                "role": {"type": "string",
                         "enum": ["e2e", "pentester", "manager", "both", "all"],
                         "description": "which agent(s) should run the test case"},
                "test_case": {"type": "string",
                              "description": "the test case / scenario to execute"},
                "instruction": {"type": "string",
                                "description": "extra role-specific direction"},
                "start": {"type": "boolean", "default": True,
                          "description": "start the agent services after queuing"},
            },
            "required": ["role", "test_case"],
        },
    },
    {
        "name": "list_tasks",
        "description": "List assigned test-case tasks (optionally filtered).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "role": {"type": "string"},
                "status": {"type": "string",
                           "enum": ["pending", "running", "done", "failed", ""]},
                "limit": {"type": "integer", "default": 20},
            },
        },
    },
    {
        "name": "get_next_task",
        "description": ("Claim the oldest pending task for a role (marks it "
                        "running). Used by the workers."),
        "inputSchema": {
            "type": "object",
            "properties": {"role": {"type": "string", "enum": list(ROLES)}},
            "required": ["role"],
        },
    },
    {
        "name": "has_open_task",
        "description": ("Tell whether a role already has an open (pending or "
                        "running) task — optionally filtered to a specific test "
                        "case. Lets the test manager avoid dispatching duplicate "
                        "work to the team."),
        "inputSchema": {
            "type": "object",
            "properties": {
                "role": {"type": "string", "enum": list(ROLES)},
                "test_case": {"type": "string", "default": ""},
            },
            "required": ["role"],
        },
    },
    {
        "name": "submit_findings",
        "description": ("Share a role's findings/knowledge on the bus and close "
                        "the task (done on success, failed on a broken run). "
                        "This is how the agents exchange knowledge."),
        "inputSchema": {
            "type": "object",
            "properties": {
                "role": {"type": "string", "enum": list(ROLES)},
                "task_id": {"type": "integer"},
                "findings": {"type": "string"},
                "kind": {"type": "string", "default": "findings"},
                "success": {"type": "boolean", "default": True,
                            "description": "false records the run as failed"},
            },
            "required": ["role", "findings"],
        },
    },
    {
        "name": "get_findings",
        "description": "Read the knowledge other roles have shared (newest first).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "role": {"type": "string"},
                "limit": {"type": "integer", "default": 10},
            },
        },
    },
    {
        "name": "get_agent_status",
        "description": "Show the systemd state of the agent services.",
        "inputSchema": {
            "type": "object",
            "properties": {"role": {"type": "string"}},
        },
    },
    {
        "name": "start_agent",
        "description": "Start the e2e/pentester/manager agent services.",
        "inputSchema": {
            "type": "object",
            "properties": {"role": {"type": "string", "default": "all"}},
        },
    },
    {
        "name": "stop_agent",
        "description": "Stop the agent services.",
        "inputSchema": {
            "type": "object",
            "properties": {"role": {"type": "string", "default": "all"}},
        },
    },
    {
        "name": "publish_process",
        "description": ("Compose the live testing-process markdown and publish it "
                        "to the Odysseus document library."),
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "get_process",
        "description": "Return the live testing-process markdown.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "publish_note",
        "description": ("Publish (or overwrite) the test results as a note in the "
                        "Odysseus Notes panel (web UI). Same title + label updates "
                        "the existing note so each role keeps its latest results."),
        "inputSchema": {
            "type": "object",
            "properties": {
                "title": {"type": "string",
                          "description": "note title (stable titles update in place)"},
                "content": {"type": "string",
                            "description": "markdown body of the note"},
                "label": {"type": "string", "default": NOTES_LABEL},
            },
            "required": ["title", "content"],
        },
    },
    {
        "name": "list_notes",
        "description": ("List the notes on the Odysseus Notes panel — the latest "
                        "test results each role published (optionally one label)."),
        "inputSchema": {
            "type": "object",
            "properties": {
                "label": {"type": "string", "default": ""},
                "limit": {"type": "integer", "default": 50},
            },
        },
    },
    {
        "name": "mail_report",
        "description": ("Send the final test report as mail through the Odysseus "
                        "mail function (/api/email/send). The report body is "
                        "markdown; the recipient defaults to REPORT_MAIL_TO "
                        "(env or odysseus credentials.env). An SMTP-capable "
                        "Email Account must be configured in Odysseus."),
        "inputSchema": {
            "type": "object",
            "properties": {
                "to": {"type": "string",
                       "description": "recipient address (defaults to REPORT_MAIL_TO)"},
                "subject": {"type": "string",
                            "description": "mail subject (defaults to a SUT test report title)"},
                "body": {"type": "string",
                         "description": "markdown report to deliver as mail"},
            },
            "required": ["body"],
        },
    },
]

RESOURCES = [
    {"uri": "testing://process", "name": "Testing process",
     "description": "Live markdown of tasks, agent state and findings.",
     "mimeType": "text/markdown"},
    {"uri": "testing://tasks", "name": "Test-case tasks",
     "description": "Assigned test cases per role.", "mimeType": "text/markdown"},
    {"uri": "testing://findings/e2e", "name": "e2e findings",
     "mimeType": "text/markdown"},
    {"uri": "testing://findings/pentester", "name": "pentester findings",
     "mimeType": "text/markdown"},
    {"uri": "testing://findings/manager", "name": "manager findings",
     "mimeType": "text/markdown"},
]


def _tool_result(text: str, is_error: bool = False) -> dict:
    return {"content": [{"type": "text", "text": text}], "isError": is_error}


def _dispatch(bus: Bus, name: str, args: dict) -> dict:
    def arg(key, default=None):
        return args.get(key, default)

    table = {
        "assign_test_case": lambda: bus.assign_test_case(
            arg("role", ""), arg("test_case", ""), arg("instruction", ""),
            bool(arg("start", True))),
        "list_tasks": lambda: bus.list_tasks(
            arg("role", ""), arg("status", ""), arg("limit", 20)),
        "get_next_task": lambda: bus.get_next_task(arg("role", "")),
        "has_open_task": lambda: bus.has_open_task(
            arg("role", ""), arg("test_case", "")),
        "submit_findings": lambda: bus.submit_findings(
            arg("role", ""), arg("task_id"), arg("findings", ""),
            arg("kind", "findings"), bool(arg("success", True))),
        "get_findings": lambda: bus.get_findings(arg("role", ""), arg("limit", 10)),
        "get_agent_status": lambda: bus.get_agent_status(arg("role", "")),
        "start_agent": lambda: bus.start_agent(arg("role", "all")),
        "stop_agent": lambda: bus.stop_agent(arg("role", "all")),
        "publish_process": lambda: bus.publish_process(),
        "get_process": lambda: bus.get_process(),
        "publish_note": lambda: bus.publish_note(
            arg("title", ""), arg("content", ""), arg("label", NOTES_LABEL)),
        "list_notes": lambda: bus.list_notes(arg("label", ""), arg("limit", 50)),
        "mail_report": lambda: bus.mail_report(
            arg("to", ""), arg("subject", ""), arg("body", "")),
    }
    fn = table.get(name)
    if fn is None:
        return _tool_result(f"unknown tool '{name}'", is_error=True)
    try:
        return _tool_result(fn())
    except Exception as exc:  # noqa: BLE001 - report tool failures as MCP errors
        return _tool_result(f"{name} failed: {exc}", is_error=True)


def _resource_read(bus: Bus, uri: str) -> dict:
    if uri == "testing://process":
        text = bus.get_process()
    elif uri == "testing://tasks":
        text = bus.list_tasks(limit=100)
    elif uri.startswith("testing://findings/"):
        text = bus.get_findings(uri.rsplit("/", 1)[-1], limit=20)
    else:
        return {"contents": []}
    return {"contents": [{"uri": uri, "mimeType": "text/markdown", "text": text}]}


def handle_message(bus: Bus, msg: dict) -> dict | None:
    """Handle one JSON-RPC message; None for notifications."""
    if not isinstance(msg, dict) or "method" not in msg:
        return {"jsonrpc": "2.0", "id": None,
                "error": {"code": -32600, "message": "invalid request"}}
    method = msg["method"]
    params = msg.get("params") or {}
    is_notification = "id" not in msg
    if method in ("notifications/initialized", "notifications/cancelled"):
        return None
    if method == "initialize":
        result = {
            "protocolVersion": params.get("protocolVersion", PROTOCOL_VERSION),
            "capabilities": {
                "tools": {"listChanged": False},
                "resources": {"subscribe": False, "listChanged": False},
            },
            "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
            "instructions": (
                "Aigents testing bus. The test manager assigns test cases for the "
                f"set SUT ({SUT_NAME}, {SUT_URL}) to the e2e and pentester roles "
                "and reads their shared findings."),
        }
    elif method == "ping":
        result = {}
    elif method == "tools/list":
        result = {"tools": TOOLS}
    elif method == "tools/call":
        result = _dispatch(bus, params.get("name", ""), params.get("arguments") or {})
    elif method == "resources/list":
        result = {"resources": RESOURCES}
    elif method == "resources/read":
        result = _resource_read(bus, params.get("uri", ""))
    else:
        if is_notification:
            return None
        return {"jsonrpc": "2.0", "id": msg.get("id"),
                "error": {"code": -32601, "message": f"method not found: {method}"}}
    if is_notification:
        return None
    return {"jsonrpc": "2.0", "id": msg.get("id"), "result": result}


def _make_handler(bus: Bus):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        server_version = f"{SERVER_NAME}/{SERVER_VERSION}"

        def log_message(self, fmt, *args):  # quieter default logging
            sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

        def _send_json(self, status: int, payload) -> None:
            body = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _send_empty(self, status: int) -> None:
            self.send_response(status)
            self.send_header("Content-Length", "0")
            self.end_headers()

        def do_GET(self):  # noqa: N802
            if self.path.split("?", 1)[0] in ("/health", "/"):
                self._send_json(200, {"status": "ok", "server": SERVER_NAME,
                                      "sut": {"name": SUT_NAME, "url": SUT_URL}})
            else:
                self._send_json(404, {"error": "not found"})

        def do_POST(self):  # noqa: N802
            if self.path.split("?", 1)[0] not in ("/mcp", "/"):
                self._send_json(404, {"error": "not found"})
                return
            length = int(self.headers.get("Content-Length", "0") or 0)
            raw = self.rfile.read(length) if length else b""
            try:
                payload = json.loads(raw or b"{}")
            except json.JSONDecodeError:
                self._send_json(400, {"jsonrpc": "2.0", "id": None,
                                      "error": {"code": -32700,
                                                "message": "parse error"}})
                return
            if isinstance(payload, list):
                responses = [r for r in (handle_message(bus, m) for m in payload)
                             if r is not None]
                if not responses:
                    self._send_empty(202)
                else:
                    self._send_json(200, responses)
                return
            response = handle_message(bus, payload)
            if response is None:
                self._send_empty(202)
            else:
                self._send_json(200, response)

    return Handler


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Aigents MCP knowledge/control bus")
    parser.add_argument("--host", default=os.environ.get("MCP_HOST", "127.0.0.1"))
    parser.add_argument("--port", type=int,
                        default=int(os.environ.get("MCP_PORT", "8765")))
    parser.add_argument("--db", default=DEFAULT_DB)
    parser.add_argument("--odysseus-secrets", default=DEFAULT_ODYSSEUS_SECRETS)
    parser.add_argument("--unit-prefix", default=DEFAULT_UNIT_PREFIX)
    parser.add_argument("--seed-jobs", default=DEFAULT_SEED_JOBS)
    args = parser.parse_args(argv)

    bus = Bus(args.db, args.unit_prefix, args.odysseus_secrets,
              seed_jobs=args.seed_jobs)
    bus.init()
    httpd = ThreadingHTTPServer((args.host, args.port), _make_handler(bus))
    print(f"{SERVER_NAME} listening on http://{args.host}:{args.port}/mcp "
          f"(db={args.db}, sut={SUT_URL})", flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
