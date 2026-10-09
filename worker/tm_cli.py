#!/usr/bin/env python3
"""Interactive terminal console for the *test manager* agent (and controller).

Talks to the self-hosted model (OpenAI-compatible /v1, llama.cpp) using the
test manager persona compiled from `.dhall/test_manager_agent.dhall`, and drives
the other agents through the MCP knowledge/control bus (worker/mcp_server.py):

  * assign a test case to the e2e tester and/or pentester      (/case)
  * start/stop the agent services and read their state         (/start /stop /agents)
  * read the shared findings and task queue                    (/findings /tasks)
  * show / publish the live testing-process document           (/process /publish)
  * request the latest results from the Odysseus Notes panel   (/notes)
  * push a test-results note into the Odysseus web UI          (/note)
  * mail the latest report through the Odysseus mail function  (/mail)

Live bus state is injected into the model context on every turn, so ordinary
questions like "how far along is the security test?" are answered with the real
task queue and agent state.

Usage:
  ./worker/tm_cli.py                       # interactive REPL
  ./worker/tm_cli.py --once "how are the last test results"
  ./worker/tm_cli.py --once "/case both test the login for sqli and xss"
  ./worker/tm_cli.py --model-url http://127.0.0.1:18080/v1

Slash commands:
  /help              show this help
  /status            model + postgres + MCP bus connectivity
  /case <role> <tc>  assign a test case (role: e2e|pentester|both|all)
  /agents            agent service state (systemd user units)
  /start [role]      start the agent service(s) (default all)
  /stop [role]       stop the agent service(s) (default all)
  /tasks [role]      list assigned test-case tasks
  /findings [role]   read the findings the agents shared
  /process           show the live testing-process markdown
  /publish           publish the process document to Odysseus
  /notes [label]     request the note(s) on the Odysseus Notes panel (test results)
  /note <title> <..> publish a note to the Odysseus web UI (label test-results)
  /mail [to]         mail the latest test report via the Odysseus mail function
  /save              persist the current transcript to postgres (collection tm_cli)
  /latest            print the most recent stored report (from the agents or this CLI)
  /clear             reset the conversation (the test-manager persona stays)
  /exit              quit (Ctrl+D / Ctrl+C works too)

Env vars honoured (defaults in parentheses):
  MODEL_URL        base of the OpenAI-compatible API (http://127.0.0.1:18080/v1,
                   the shared phi-4-mini instance that serves the crews and
                   this CLI)
  MODEL_NAME       model alias as served by llama-server (phi-4-mini)
  MCP_URL          MCP bus endpoint (http://127.0.0.1:8765/mcp)
  POSTGRES_DSN     full postgres DSN; else read from
                   /var/spool/aigents/database/secrets/credentials.env
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
AGENT_JSON = REPO / "build" / "agents" / "test_manager_agent.json"
DEFAULT_CREDENTIALS = Path("/var/spool/aigents/database/secrets/credentials.env")

# MCP bus client (worker/mcp_bus.py sits next to this file); stdlib-only.
sys.path.insert(0, str(Path(__file__).resolve().parent))
try:
    import mcp_bus
except Exception:  # pragma: no cover - bus is optional
    mcp_bus = None

MCP_URL = os.environ.get("MCP_URL", "http://127.0.0.1:8765/mcp")

# Defaults mirror .dhall/test_manager_agent.dhall, used when the dhall->json
# artifact has not been compiled (run `nix develop -c just` to produce it).
FALLBACK_PERSONA = {
    "role": "test manager",
    "goal": (
        "act as the test manager and controller for the fixed OWASP Juice Shop "
        "SUT: take the test case the user gives and assign it to the e2e tester "
        "and/or the pentester over the MCP bus, start and track those agents, "
        "read the findings they share, monitor their state and dispatched tasks "
        "and dispatch follow-ups when coverage is missing, verify coverage and "
        "quality, and produce a final consolidated report of end-to-end and "
        "security results, published to Odysseus and mailed to the report "
        "recipients through the Odysseus mail function"
    ),
    "backstory": (
        "an experienced test manager with a track record of running end-to-end "
        "and security testing programs across large web applications; you "
        "control the other agents through the MCP knowledge bus, monitor their "
        "state and dispatched test cases, and shape the final markdown report "
        "that is published to Odysseus and mailed to the report recipients"
    ),
    "tools": ["FileReadTool", "FileWriterTool", "custom:aigents_bus"],
}

CYAN = "\033[36m"
BOLD = "\033[1m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
RED = "\033[31m"
DIM = "\033[2m"
RESET = "\033[0m"


def load_persona(path: Path) -> dict:
    if path.is_file():
        try:
            return json.loads(path.read_text())
        except (OSError, json.JSONDecodeError) as exc:
            print(f"{YELLOW}warning: {path} unreadable ({exc}); using fallback persona{RESET}",
                  file=sys.stderr)
    return dict(FALLBACK_PERSONA)


def system_prompt(persona: dict, model_name: str) -> str:
    tools = ", ".join(persona.get("tools", []))
    return (
        f"You are the {persona.get('role', 'test manager')} agent and controller "
        "of the open-testing-agents stack, served by the local model "
        f"{model_name}.\n"
        f"Goal: {persona.get('goal', '')}\n"
        f"Backstory: {persona.get('backstory', '')}\n"
        f"Tools available: {tools}\n"
        "The one system under test is the OWASP Juice Shop at "
        f"{os.environ.get('TARGET_URL', 'http://127.0.0.1:8080')}.\n"
        "You control the e2e tester and the pentester through the MCP bus "
        "(custom:aigents_bus): assign them a test case, read their findings, "
        "monitor their state and dispatched tasks, and dispatch follow-ups when "
        "coverage is missing. Answer as the test manager: coordinate, review and "
        "report on testing activities. Produce markdown reports when the user "
        "asks for a report, send them as mail through the Odysseus mail function "
        "when asked, and keep answers actionable."
    )


class ModelClient:
    """Minimal OpenAI-compatible client over http.client (stdlib only)."""

    def __init__(self, url: str, model: str):
        self.url = url.rstrip("/")
        self.model = model
        if "/v1" in self.url:
            self.base = self.url[: self.url.index("/v1") + 3]
        else:
            self.base = self.url

    def _request(self, method: str, path: str, body: dict | None = None, timeout: float = 180):
        import http.client
        from urllib.parse import urlparse

        parsed = urlparse(self.url)
        host = parsed.hostname
        port = parsed.port or (443 if parsed.scheme == "https" else 80)
        base_path = parsed.path.rstrip("/")
        conn = http.client.HTTPConnection(host, port, timeout=timeout)
        headers = {"Content-Type": "application/json"}
        payload = json.dumps(body) if body is not None else None
        conn.request(
            method,
            f"{base_path}/{path.lstrip('/')}",
            body=payload,
            headers=headers,
        )
        return conn

    def check(self) -> tuple[bool, str]:
        try:
            conn = self._request("GET", "/models", timeout=10)
            resp = conn.getresponse()
            data = json.loads(resp.read() or b"{}")
            conn.close()
            if resp.status != 200:
                return False, f"HTTP {resp.status}"
            names = [m.get("id") for m in data.get("data", [])]
            return True, "model " + (self.model if self.model in names else f"unknown (have {names})")
        except Exception as exc:  # noqa: BLE001
            return False, f"{exc}"

    def chat(self, messages: list[dict], temp: float, max_tokens: int, stream: bool = True):
        """Yield (delta, full_text_so_far). Supports SSE streaming and plain JSON."""
        body = {
            "model": self.model,
            "messages": messages,
            "temperature": temp,
            "max_tokens": max_tokens,
            "stream": stream,
        }
        try:
            conn = self._request("POST", "/chat/completions", body)
            resp = conn.getresponse()
        except Exception as exc:  # noqa: BLE001
            raise RuntimeError(f"model unreachable: {exc}") from exc

        chunks = []
        try:
            if stream and resp.getheader("Content-Type", "").startswith("text/event-stream"):
                for line in resp:
                    line = line.decode("utf-8", "replace").strip()
                    if not line.startswith("data:"):
                        continue
                    data = line[5:].strip()
                    if data == "[DONE]":
                        break
                    chunk = json.loads(data)
                    delta = chunk["choices"][0].get("delta", {}).get("content", "")
                    if delta:
                        chunks.append(delta)
                        yield delta, "".join(chunks)
            else:
                data = json.loads(resp.read() or b"{}")
                content = data["choices"][0]["message"]["content"]
                chunks.append(content)
                yield content, content
        except KeyError as exc:
            raise RuntimeError(f"unexpected model response: {exc}") from exc
        finally:
            conn.close()


class Store:
    """Optional postgres persistence for transcripts + report lookups."""

    def __init__(self) -> None:
        self.dsn = os.environ.get("POSTGRES_DSN", "")
        if not self.dsn and DEFAULT_CREDENTIALS.is_file():
            for line in DEFAULT_CREDENTIALS.read_text().splitlines():
                if line.startswith("POSTGRES_DSN="):
                    self.dsn = line.split("=", 1)[1].strip()
                    break

    def available(self) -> bool:
        if not self.dsn:
            return False
        try:
            import psycopg  # noqa: F401
        except ImportError:
            return False
        return True

    def _connect(self):
        import psycopg
        return psycopg.connect(self.dsn)

    def status(self) -> str:
        if not self.dsn:
            return "no POSTGRES_DSN configured (set it or start the stack)"
        try:
            with self._connect() as conn:
                ver = conn.execute("SELECT version()").fetchone()[0]
            return "postgres: " + ver.split(" on ")[0]
        except Exception as exc:  # noqa: BLE001
            return f"postgres unreachable: {exc}"

    def save_transcript(self, messages: list[dict], model_name: str) -> str:
        transcript = "\n\n".join(
            f"### {m['role']}\n{m['content']}" for m in messages if m["role"] != "system"
        )
        if not transcript.strip():
            return "nothing to save (conversation is empty)"
        metadata = {"kind": "tm_cli_session", "model": model_name, "turns": sum(1 for m in messages if m["role"] != "system")}
        try:
            with self._connect() as conn:
                cur = conn.execute(
                    "INSERT INTO documents (collection, source, content, metadata) "
                    "VALUES ('tm_cli', 'cli:test_manager', %s, %s) RETURNING id",
                    (transcript, json.dumps(metadata)),
                )
                row = cur.fetchone()
                conn.commit()
        except Exception as exc:  # noqa: BLE001
            return f"save failed: {exc}"
        return f"saved transcript as document id={row[0]}"

    def latest_report(self) -> str:
        try:
            with self._connect() as conn:
                rows = conn.execute(
                    "SELECT collection, source, content, created_at FROM documents "
                    "ORDER BY created_at DESC LIMIT 1"
                ).fetchall()
            if not rows:
                return "no documents stored yet"
            col, source, content, created = rows[0]
            return f"{DIM}[{created.isoformat()} | {col} / {source}]{RESET}\n{content}"
        except Exception as exc:  # noqa: BLE001
            return f"lookup failed: {exc}"


def read_dsn_from_env() -> None:
    """Pull MODEL_URL/MODEL_NAME/POSTGRES_DSN from credentials.env if unset."""
    if os.environ.get("MODEL_URL") or not DEFAULT_CREDENTIALS.is_file():
        return
    for line in DEFAULT_CREDENTIALS.read_text().splitlines():
        if "=" not in line or line.startswith("#"):
            continue
        k, _, v = line.partition("=")
        os.environ.setdefault(k.strip(), v.strip())


HELP = f"""{BOLD}commands{CYAN}
  /help      {RESET}show this help
{CYAN}  /status    {RESET}model + postgres + MCP bus connectivity
{CYAN}  /case      {RESET}<role> <test case>  assign a test case (e2e|pentester|both|all)
{CYAN}  /agents    {RESET}agent service state (systemd user units)
{CYAN}  /start     {RESET}[role]  start the agent service(s) (default all)
{CYAN}  /stop      {RESET}[role]  stop the agent service(s) (default all)
{CYAN}  /tasks     {RESET}[role]  list assigned test-case tasks
{CYAN}  /findings  {RESET}[role]  read the findings the agents shared
{CYAN}  /process   {RESET}show the live testing-process markdown
{CYAN}  /publish   {RESET}publish the process document to Odysseus
{CYAN}  /notes     {RESET}[label]  request the note(s) on the Odysseus Notes panel (latest results)
{CYAN}  /note      {RESET}<title> <text>  publish a note to the Odysseus web UI (label test-results)
{CYAN}  /save      {RESET}persist the current transcript to postgres (collection tm_cli)
{CYAN}  /latest    {RESET}print the most recent stored document (latest agent report or session)
{CYAN}  /clear     {RESET}reset the conversation (test-manager persona stays)
{CYAN}  /exit      {RESET}quit (Ctrl+D / Ctrl+C works too)"""


def bus_context() -> str:
    """Live MCP-bus state injected into the model so it can answer progress Qs."""
    if mcp_bus is None:
        return ""
    try:
        status = mcp_bus.get_agent_status()
        tasks = mcp_bus.list_tasks(limit=8)
        findings = mcp_bus.get_findings(limit=3)
    except Exception as exc:  # noqa: BLE001
        return f"MCP bus unavailable at {MCP_URL}: {exc}"
    text = (
        "Live state from the MCP bus (use it to answer questions about progress "
        "and to decide what to assign next):\n\n"
        f"Agents:\n{status}\n\nTest-case tasks:\n{tasks}\n\n"
        f"Recent shared findings:\n{findings}"
    )
    return text[:3000]


def bus_ready() -> bool:
    return mcp_bus is not None and mcp_bus.available()


def print_assistant(text: str) -> None:
    print(f"{GREEN}tm ▸{RESET} {text}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Test manager agent CLI / controller")
    parser.add_argument("--once", help="ask a single question (or run one /command) and exit")
    parser.add_argument("--model-url", default=os.environ.get(
        "MODEL_URL", "http://127.0.0.1:18080/v1"), help="OpenAI-compatible API base")
    parser.add_argument("--model-name", default=os.environ.get("MODEL_NAME", "phi-4-mini"))
    parser.add_argument("--mcp-url", default=MCP_URL, help="MCP bus endpoint")
    parser.add_argument("--persona", default=str(AGENT_JSON), help="path to the agent JSON")
    parser.add_argument("--temp", type=float, default=0.2)
    parser.add_argument("--max-tokens", type=int, default=2048)
    parser.add_argument("--no-stream", action="store_true")
    args = parser.parse_args()

    read_dsn_from_env()
    persona = load_persona(Path(args.persona))
    client = ModelClient(args.model_url or os.environ.get("MODEL_URL", "http://127.0.0.1:18080/v1"), args.model_name)
    store = Store()

    messages = [{"role": "system", "content": system_prompt(persona, args.model_name)}]

    def ask(question: str, save: bool = False) -> None:
        # Refresh the live bus state in the model context so progress questions
        # ("what is the pentester doing?") are answered from real task/agent data.
        ctx = bus_context()
        if ctx:
            if len(messages) > 1 and messages[1].get("role") == "system":
                messages[1] = {"role": "system", "content": ctx}
            else:
                messages.insert(1, {"role": "system", "content": ctx})
        messages.append({"role": "user", "content": question})
        try:
            full = ""
            for delta, full in client.chat(messages, args.temp, args.max_tokens, stream=not args.no_stream):
                print(delta, end="", flush=True)
            print()
            messages.append({"role": "assistant", "content": full})
            if save and store.available():
                print(DIM + store.save_transcript(messages, args.model_name) + RESET)
        except RuntimeError as exc:
            print(f"{RED}error: {exc}{RESET}")
            messages.pop()
        except KeyboardInterrupt:
            print(f"\n{DIM}stopped{RESET}")

    def bus_call(name: str, **kwargs) -> None:
        """Call an mcp_bus wrapper and print its text result (never raises)."""
        if mcp_bus is None:
            print(f"{YELLOW}MCP bus client unavailable (worker/mcp_bus.py not found){RESET}")
            return
        try:
            print(getattr(mcp_bus, name)(url=args.mcp_url, **kwargs))
        except Exception as exc:  # noqa: BLE001
            print(f"{RED}bus error: {exc}{RESET}")

    def run_command(line: str) -> bool:
        """Handle a /command; return True when the line was one."""
        nonlocal messages
        cmd, _, rest = line.partition(" ")
        rest = rest.strip()
        if cmd == "/help":
            print(HELP)
        elif cmd == "/status":
            ok, status = client.check()
            print(f"model: {status}")
            print(f"store: {store.status()}")
            print(f"bus:   {args.mcp_url} ({'reachable' if bus_ready() else 'unreachable'})")
        elif cmd == "/case":
            role, _, case = rest.partition(" ")
            if not role or not case.strip():
                print(f"{YELLOW}usage: /case <e2e|pentester|both|all> <test case>{RESET}")
            else:
                bus_call("assign_test_case", role=role, test_case=case.strip())
        elif cmd == "/agents":
            bus_call("get_agent_status")
        elif cmd == "/start":
            bus_call("start_agent", role=rest or "all")
        elif cmd == "/stop":
            bus_call("stop_agent", role=rest or "all")
        elif cmd == "/tasks":
            bus_call("list_tasks", role=rest, limit=20)
        elif cmd == "/findings":
            bus_call("get_findings", role=rest, limit=10)
        elif cmd == "/process":
            bus_call("get_process")
        elif cmd == "/publish":
            bus_call("publish_process")
        elif cmd == "/notes":
            bus_call("list_notes", label=rest, limit=50)
        elif cmd == "/note":
            title, _, body = rest.partition(" ")
            if not title or not body.strip():
                print(f"{YELLOW}usage: /note <title> <text> — publishes a note to Odysseus{RESET}")
            else:
                bus_call("publish_note", title=title, content=body.strip(),
                         label="test-results")
        elif cmd == "/mail":
            # Mail the latest test report via the Odysseus mail function.
            # `to` defaults to REPORT_MAIL_TO (env or odysseus creds). Prefer the
            # full testing-process markdown (the Notes list truncates content);
            # fall back to the manager's test-results note.
            to = rest.strip()
            subject = f"Test report: {os.environ.get('TARGET_URL', 'aigents SUT')}"
            body = ""
            if mcp_bus is not None:
                try:
                    body = mcp_bus.get_process()
                except Exception as exc:  # noqa: BLE001
                    print(f"{RED}bus error while reading the process: {exc}{RESET}")
            if not body.strip() and mcp_bus is not None:
                try:
                    notes = mcp_bus.list_notes(label="test-results", limit=100)
                    for block in notes.split("\n\n### "):
                        if block.strip().startswith("Test results: manager"):
                            body = block.split("\n\n", 1)[1].strip() if "\n\n" in block else ""
                            break
                except Exception as exc:  # noqa: BLE001
                    print(f"{RED}bus error while reading notes: {exc}{RESET}")
            if not body.strip():
                print(f"{YELLOW}no report to mail yet — run /case and let the agents finish first{RESET}")
            else:
                bus_call("mail_report", to=to, subject=subject, body=body)
        elif cmd == "/save":
            if not store.available():
                print(f"{YELLOW}postgres not available; transcript not stored{RESET}")
            else:
                print(store.save_transcript(messages, args.model_name))
        elif cmd == "/latest":
            print(store.latest_report() if store.available() else f"{YELLOW}postgres not available{RESET}")
        elif cmd == "/clear":
            messages = [messages[0]]
            print("conversation reset")
        else:
            return False
        return True

    if args.once:
        if not run_command(args.once):
            ask(args.once)
        return 0

    ok, status = client.check()
    print(f"{BOLD}test manager console{RESET}  model={args.model_name}  "
          f"api={args.model_url}\n{DIM}persona: {persona.get('role')}{RESET}")
    print(f"model: {status}")
    print(f"store: {store.status()}")
    print(f"bus:   {args.mcp_url} ({'reachable' if bus_ready() else 'unreachable'})")
    print(HELP)
    print()

    while True:
        try:
            line = input(f"{CYAN}tm{DIM}@{RESET}{CYAN}aigents{DIM} > {RESET}").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            break
        if not line:
            continue
        if line == "/exit":
            break
        if not run_command(line):
            ask(line)

    return 0


if __name__ == "__main__":
    sys.exit(main())