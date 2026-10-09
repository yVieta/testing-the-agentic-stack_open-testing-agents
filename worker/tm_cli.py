#!/usr/bin/env python3
"""Interactive terminal CLI for the *test manager* agent.

Talks to the self-hosted model (OpenAI-compatible /v1, llama.cpp) using the
test manager persona compiled from `.dhall/test_manager_agent.dhall`, and
persists transcripts in the local PostgreSQL store when reachable.

Intended to feel like working with an agent in a terminal (opencode-style):
streamed answers, slash commands, session history.

Usage:
  ./worker/tm_cli.py                       # interactive REPL
  ./worker/tm_cli.py --once "how are the last test results"   # single query
  ./worker/tm_cli.py --model-url http://127.0.0.1:18080/v1

Slash commands:
  /help      show this help
  /status    model + postgres connectivity
  /save      persist the current transcript to postgres (collection tm_cli)
  /latest    print the most recent stored report (from the agents or this CLI)
  /clear     reset the conversation (the test-manager persona stays)
  /exit      quit (Ctrl+D / Ctrl+C works too)

Env vars honoured (defaults in parentheses):
  MODEL_URL        base of the OpenAI-compatible API (http://127.0.0.1:18081/v1,
                   the phi4-cli instance dedicated to this CLI; the crew-facing
                   server stays on 18080)
  MODEL_NAME       model alias as served by llama-server (phi-4-mini)
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

# Defaults mirror .dhall/test_manager_agent.dhall, used when the dhall->json
# artifact has not been compiled (run `nix develop -c just` to produce it).
FALLBACK_PERSONA = {
    "role": "test manager",
    "goal": (
        "coordinate and review all testing activities, verify coverage and "
        "quality, track the progress of the e2e and pentester agents (each "
        "role writes previous_output.md for the next one), and produce a final "
        "consolidated report of end-to-end and security test results"
    ),
    "backstory": (
        "an experienced test manager with a track record of running end-to-end "
        "and security testing programs across large web applications"
    ),
    "tools": ["FileReadTool", "FileWriterTool"],
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
        f"You are the {persona.get('role', 'test manager')} agent of the "
        "open-testing-agents stack, served by the local model "
        f"{model_name}.\n"
        f"Goal: {persona.get('goal', '')}\n"
        f"Backstory: {persona.get('backstory', '')}\n"
        f"Tools available: {tools}\n"
        "Answer as the test manager: coordinate, review and report on testing "
        "activities. Produce markdown reports when the user asks for a report, "
        "and keep answers actionable."
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
{CYAN}  /status    {RESET}model + postgres connectivity
{CYAN}  /save      {RESET}persist the current transcript to postgres (collection tm_cli)
{CYAN}  /latest    {RESET}print the most recent stored document (latest agent report or session)
{CYAN}  /clear     {RESET}reset the conversation (test-manager persona stays)
{CYAN}  /exit      {RESET}quit (Ctrl+D / Ctrl+C works too)"""


def print_assistant(text: str) -> None:
    print(f"{GREEN}tm ▸{RESET} {text}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Test manager agent CLI")
    parser.add_argument("--once", help="ask a single question and exit")
    parser.add_argument("--model-url", default=os.environ.get(
        "MODEL_URL", "http://127.0.0.1:18081/v1"), help="OpenAI-compatible API base")
    parser.add_argument("--model-name", default=os.environ.get("MODEL_NAME", "phi-4-mini"))
    parser.add_argument("--persona", default=str(AGENT_JSON), help="path to the agent JSON")
    parser.add_argument("--temp", type=float, default=0.2)
    parser.add_argument("--max-tokens", type=int, default=2048)
    parser.add_argument("--no-stream", action="store_true")
    args = parser.parse_args()

    read_dsn_from_env()
    persona = load_persona(Path(args.persona))
    client = ModelClient(args.model_url or os.environ.get("MODEL_URL", "http://127.0.0.1:18081/v1"), args.model_name)
    store = Store()

    messages = [{"role": "system", "content": system_prompt(persona, args.model_name)}]

    def ask(question: str, save: bool = False) -> None:
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

    if args.once:
        ask(args.once)
        return 0

    ok, status = client.check()
    print(f"{BOLD}test manager CLI{RESET}  model={args.model_name}  "
          f"api={args.model_url}\n{DIM}persona: {persona.get('role')}{RESET}")
    print(f"model: {status}")
    print(f"store: {store.status()}")
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

        cmd, _, rest = line.partition(" ")
        if cmd == "/exit":
            break
        if cmd == "/help":
            print(HELP)
        elif cmd == "/status":
            ok, status = client.check()
            print(f"model: {status}")
            print(f"store: {store.status()}")
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
            ask(line)

    return 0


if __name__ == "__main__":
    sys.exit(main())