"""crewAI tool: each agent's control/knowledge line to the aigents MCP bus.

Referenced from the `.dhall/*_agent.dhall` files as ``custom:aigents_bus``
(every role — e2e engineer, pentester, test manager — carries it). crewAI's
custom-tool loader executes this file, takes the first ``BaseTool`` subclass,
and instantiates it with no arguments — so everything it needs has a default.
The class is deliberately self-contained (stdlib HTTP JSON-RPC only) because it
is copied into each crew's ``tools/`` directory, away from the rest of
``worker/``.

The worker already mediates task fetch + findings submission for every role;
this tool lets the *agents themselves* talk to each other over the bus — read
the manager's direction and the other roles' findings, submit/close a task,
publish a test-results note, and, for the manager, dispatch and mail reports.
See ``worker/mcp_server.py`` for the server and ``worker/mcp_bus.py`` for the
host client.
"""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.request

try:  # crewai >= 0.100
    from crewai.tools import BaseTool
except Exception:  # pragma: no cover - older layout
    from langchain.tools import BaseTool  # type: ignore

from pydantic import BaseModel, Field

DEFAULT_URL = os.environ.get("MCP_URL", "http://127.0.0.1:8765/mcp")


def _call(name: str, arguments: dict, timeout: float = 60.0) -> str:
    """One MCP ``tools/call``; always returns text, never raises."""
    payload = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": {"name": name, "arguments": arguments},
    }
    req = urllib.request.Request(
        DEFAULT_URL,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = json.loads(resp.read() or b"{}")
    except (urllib.error.URLError, OSError) as exc:
        return f"MCP bus unreachable at {DEFAULT_URL}: {exc}"
    if data.get("error"):
        return f"MCP error: {data['error']}"
    result = data.get("result", {})
    text = "\n".join(
        block.get("text", "")
        for block in result.get("content", [])
        if block.get("type") == "text"
    )
    return text or "(no content)"


def _require_manager(tool: str, what: str, arguments: dict) -> str:
    """Only the test manager crew may start/stop agent services.

    The workers would otherwise be able to shut each other down mid-run (a
    runaway e2e/pentester crew calling action=stop on a sibling), which breaks
    the team's liveness. The manager is still free to control every unit.
    """
    me = os.environ.get("CREW_ROLE", "")
    if me != "test_manager_agent":
        return ("`%s` refused: only the test manager may %s "
                "(this crew runs as %r) — ask the manager to do it") % (
                    what, what, me)
    return _call(tool, arguments)


class AigentsBusInput(BaseModel):
    """Arguments for the bus tool (one action per call)."""

    action: str = Field(
        ...,
        description=(
            "One of: get_status, start, stop, assign, tasks, next, findings, "
            "submit, process, publish, note, notes, mail."
        ),
    )
    role: str = Field(
        "",
        description="e2e | pentester | manager | both | all (default: all where relevant).",
    )
    test_case: str = Field("", description="The test case to assign (action=assign).")
    instruction: str = Field("", description="Extra direction for the assigned role.")
    findings: str = Field("", description="Findings/knowledge to share (action=submit), note content (action=note), or the report to mail (action=mail).")
    title: str = Field("", description="Note title (action=note) or mail subject (action=mail).")
    to: str = Field("", description="Mail recipient (action=mail; defaults to REPORT_MAIL_TO).")
    task_id: int = Field(0, description="Task id to close when submitting findings.")
    limit: int = Field(20, description="Max rows to return for list actions.")


class AigentsBusTool(BaseTool):
    name: str = "aigents_bus"
    description: str = (
        "Exchange knowledge with the other testing agents and control the team. "
        "action=assign gives the e2e tester and/or pentester a concrete test "
        "case for the fixed OWASP Juice Shop SUT; action=findings reads what "
        "they already found; action=submit shares your own findings; "
        "action=note publishes a test-results note to the Odysseus web UI; "
        "action=mail sends the final report as mail through the Odysseus mail "
        "function; action=start/stop/get_status control the agent services "
        "(start/stop are test-manager only); action=tasks lists the assigned "
        "test-case tasks; action=open checks whether a role already has an open "
        "task for a case; "
        "action=process/publish show/publish the live testing-process document."
    )
    args_schema: type[BaseModel] = AigentsBusInput

    def _run(self, action: str = "", role: str = "", test_case: str = "",
             instruction: str = "", findings: str = "", title: str = "",
             to: str = "", task_id: int = 0, limit: int = 20) -> str:
        action = (action or "").strip().lower()
        if action in ("get_status", "status"):
            return _call("get_agent_status", {"role": role})
        if action == "start":
            return _require_manager(
                "start_agent", f"start agent services {role!r}",
                {"role": role or "all"})
        if action == "stop":
            return _require_manager(
                "stop_agent", f"stop agent services {role!r}",
                {"role": role or "all"})
        if action in ("assign", "assign_test_case", "case"):
            return _call("assign_test_case", {
                "role": role, "test_case": test_case,
                "instruction": instruction, "start": True,
            })
        if action in ("tasks", "list_tasks"):
            return _call("list_tasks", {"role": role, "limit": limit})
        if action in ("open", "has_open_task"):
            return _call("has_open_task", {"role": role, "test_case": test_case})
        if action in ("next", "get_next_task"):
            return _call("get_next_task", {"role": role})
        if action in ("findings", "get_findings", "knowledge"):
            return _call("get_findings", {"role": role, "limit": limit})
        if action in ("submit", "submit_findings"):
            return _call("submit_findings", {
                "role": role, "task_id": task_id or None, "findings": findings,
            })
        if action in ("process", "get_process"):
            return _call("get_process", {})
        if action in ("publish", "publish_process"):
            return _call("publish_process", {})
        if action in ("note", "publish_note"):
            # The manager pushes a test-results note into the Odysseus web UI;
            # a missing title defaults to the role label so it updates in place.
            return _call("publish_note", {
                "title": title or f"Test results: {role or 'manager'}",
                "content": findings, "label": "test-results",
            })
        if action in ("notes", "list_notes"):
            return _call("list_notes", {"label": "test-results", "limit": limit})
        if action in ("mail", "mail_report"):
            # The manager mails the final report through the Odysseus mail
            # function; subject defaults from the title arg, body from findings.
            return _call("mail_report", {
                "to": to, "subject": title or "", "body": findings,
            })
        return (
            f"unknown action '{action}' — use get_status/start/stop/assign/"
            "tasks/next/findings/submit/process/publish/note/notes/mail"
        )


# crewai >= 1.15 doesn't put modules loaded from a JSON project's tools/ dir
# into sys.modules; pydantic then can't resolve the deferred `type[BaseModel]`
# forward ref in args_schema and construction fails with "not fully defined".
# Rebuild with an explicit namespace so the class is concrete under both the
# crewai JSON loader and a regular Python import.
AigentsBusTool.model_rebuild(force=True, _types_namespace=globals())
