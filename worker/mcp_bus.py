#!/usr/bin/env python3
"""Client for the aigents MCP bus (worker/mcp_server.py).

The bus is a small MCP (JSON-RPC 2.0) server that the testing agents use to
exchange knowledge and that the test manager uses to control them:

  * test-case tasks per role          (assign_test_case / get_next_task)
  * shared findings / knowledge       (submit_findings / get_findings)
  * agent lifecycle                   (start_agent / stop_agent / get_agent_status)
  * testing-process markdown          (publish_process / get_process)
  * test-results notes in Odysseus    (publish_note / list_notes)
  * report mail in Odysseus           (mail_report)

Only the standard library is used, so this works both inside the agent
container (repo mounted at /repo) and on the host (tm CLI).

Environment:
  MCP_URL   MCP endpoint (http://127.0.0.1:8765/mcp)
"""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request


DEFAULT_URL = os.environ.get("MCP_URL", "http://127.0.0.1:8765/mcp")

# Tool names exposed by the server; kept here so callers never hardcode strings.
TOOL_ASSIGN = "assign_test_case"
TOOL_TASKS = "list_tasks"
TOOL_NEXT = "get_next_task"
TOOL_SUBMIT = "submit_findings"
TOOL_FINDINGS = "get_findings"
TOOL_STATUS = "get_agent_status"
TOOL_START = "start_agent"
TOOL_STOP = "stop_agent"
TOOL_PUBLISH = "publish_process"
TOOL_PROCESS = "get_process"
TOOL_NOTE = "publish_note"
TOOL_NOTES = "list_notes"
TOOL_MAIL = "mail_report"

# Label under which the agents' test-results notes live in Odysseus.
NOTES_LABEL = "test-results"


class MCPError(RuntimeError):
    """Raised when the bus is unreachable or returns a JSON-RPC error."""


def _rpc(method: str, params: dict | None = None, url: str | None = None,
         timeout: float = 30.0, request_id: int = 1) -> dict:
    """POST one JSON-RPC request and return the ``result`` object."""
    endpoint = url or DEFAULT_URL
    payload = {"jsonrpc": "2.0", "id": request_id, "method": method,
               "params": params or {}}
    req = urllib.request.Request(
        endpoint, data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json",
                 "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read()
    except urllib.error.URLError as exc:
        raise MCPError(f"MCP bus unreachable at {endpoint}: {exc}") from exc
    except OSError as exc:
        raise MCPError(f"MCP bus unreachable at {endpoint}: {exc}") from exc
    data = json.loads(body or b"{}")
    if data.get("error"):
        raise MCPError(str(data["error"]))
    return data.get("result", {})


def call_tool(name: str, arguments: dict | None = None, url: str | None = None,
              timeout: float = 60.0) -> str:
    """Invoke an MCP tool and return its text payload."""
    result = _rpc("tools/call", {"name": name, "arguments": arguments or {}},
                  url=url, timeout=timeout)
    parts = []
    for block in result.get("content", []):
        if block.get("type") == "text":
            parts.append(block.get("text", ""))
    text = "\n".join(parts)
    if result.get("isError"):
        raise MCPError(text or f"tool {name} failed")
    return text


def call_tool_json(name: str, arguments: dict | None = None, url: str | None = None,
                   timeout: float = 60.0):
    """Invoke a tool whose payload is JSON and decode it."""
    return json.loads(call_tool(name, arguments, url=url, timeout=timeout) or "{}")


def available(url: str | None = None, timeout: float = 3.0) -> bool:
    """Cheap liveness probe; never raises."""
    try:
        _rpc("ping", {}, url=url, timeout=timeout)
        return True
    except Exception:  # noqa: BLE001
        return False


# --- convenience wrappers -----------------------------------------------------


def assign_test_case(role: str, test_case: str, instruction: str = "",
                     start: bool = True, url: str | None = None) -> str:
    """Queue a test case for one role (or ``both``/``all``) and start the agents."""
    return call_tool(TOOL_ASSIGN, {"role": role, "test_case": test_case,
                                   "instruction": instruction, "start": start},
                     url=url)


def list_tasks(role: str = "", status: str = "", limit: int = 20,
               url: str | None = None) -> str:
    return call_tool(TOOL_TASKS, {"role": role, "status": status, "limit": limit},
                     url=url)


def get_next_task(role: str, url: str | None = None) -> dict | None:
    """Return the oldest pending task for ``role`` (marks it running), or None."""
    payload = call_tool_json(TOOL_NEXT, {"role": role}, url=url)
    return payload.get("task") or None


def submit_findings(role: str, task_id: int | None, findings: str,
                    kind: str = "findings", url: str | None = None) -> str:
    return call_tool(TOOL_SUBMIT, {"role": role, "task_id": task_id,
                                   "findings": findings, "kind": kind}, url=url)


def get_findings(role: str = "", limit: int = 10, url: str | None = None) -> str:
    return call_tool(TOOL_FINDINGS, {"role": role, "limit": limit}, url=url)


def get_agent_status(role: str = "", url: str | None = None) -> str:
    return call_tool(TOOL_STATUS, {"role": role}, url=url)


def start_agent(role: str = "all", url: str | None = None) -> str:
    return call_tool(TOOL_START, {"role": role}, url=url, timeout=30.0)


def stop_agent(role: str = "all", url: str | None = None) -> str:
    return call_tool(TOOL_STOP, {"role": role}, url=url, timeout=30.0)


def publish_process(url: str | None = None) -> str:
    return call_tool(TOOL_PUBLISH, {}, url=url, timeout=60.0)


def get_process(url: str | None = None) -> str:
    return call_tool(TOOL_PROCESS, {}, url=url)


def publish_note(title: str, content: str, label: str = NOTES_LABEL,
                 url: str | None = None) -> str:
    """Publish (or update) the test results as a note in the Odysseus UI."""
    return call_tool(TOOL_NOTE, {"title": title, "content": content,
                                 "label": label}, url=url, timeout=60.0)


def list_notes(label: str = "", limit: int = 50,
               url: str | None = None) -> str:
    """List the notes on the Odysseus Notes panel (optionally by label)."""
    return call_tool(TOOL_NOTES, {"label": label, "limit": limit}, url=url)


def mail_report(to: str = "", subject: str = "", body: str = "",
                url: str | None = None) -> str:
    """Send the test report as mail through the Odysseus mail function.

    The recipient defaults to REPORT_MAIL_TO (env or odysseus credentials.env)
    when ``to`` is empty. Best-effort: an unreachable app or a mail account
    without SMTP is surfaced as text, never raised.
    """
    return call_tool(TOOL_MAIL, {"to": to, "subject": subject, "body": body},
                     url=url, timeout=90.0)


if __name__ == "__main__":  # tiny debugging CLI: `mcp_bus.py <tool> [json]`
    tool = sys.argv[1] if len(sys.argv) > 1 else "get_process"
    args = json.loads(sys.argv[2]) if len(sys.argv) > 2 else {}
    print(call_tool(tool, args))
