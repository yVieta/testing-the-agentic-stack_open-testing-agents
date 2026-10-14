"""crewAI tool: run an allow-listed command inside the agent container.

This is the *controlled execution path* that lets a role actually use the CLI
tools installed in its image layer (the pentester's nmap/nikto/sqlmap/nuclei/…,
see ``agent-setup/tools.tf``). It is deliberately conservative:

* Only binaries named in ``/etc/aigents/allowed-commands.txt`` (generated from
  the declarative tool catalog, one command per line) may run. Override/extend
  with the ``ALLOWED_COMMANDS`` env var (space/comma separated).
* No shell: the command line is tokenised with :mod:`shlex` and executed with
  ``shell=False``, so ``;`` ``|`` ``&`` ``$()`` etc. are inert. Tokens carrying
  shell control characters are rejected outright.
* Arguments that address a host are checked against ``ALLOWED_TARGETS`` when
  that is set (the worker derives it from the fixed SUT ``TARGET_URL``), so a
  scan cannot be pointed at an arbitrary machine.
* Bounded: a per-call timeout and a capped output size.

Everything it needs has a default, because crewAI instantiates the tool with no
arguments (see ``worker/crew_tools/aigents_bus.py`` for the same constraint).
"""

from __future__ import annotations

import os
import shlex
import shutil
import subprocess
from urllib.parse import urlparse

try:  # crewai >= 0.100
    from crewai.tools import BaseTool
except Exception:  # pragma: no cover - older layout
    from langchain.tools import BaseTool  # type: ignore

from pydantic import BaseModel, Field

ALLOWLIST_FILE = os.environ.get(
    "ALLOWED_COMMANDS_FILE", "/etc/aigents/allowed-commands.txt")
MAX_OUTPUT = int(os.environ.get("RUN_COMMAND_MAX_OUTPUT", "8000"))
DEFAULT_TIMEOUT = float(os.environ.get("RUN_COMMAND_TIMEOUT", "600"))
WORK_DIR = os.environ.get("WORK_DIR", "/tmp/crew")

# Characters that would be meaningful to a shell. They are harmless once the
# command is executed with shell=False, but rejecting them keeps the tool's
# contract obvious and blocks accidental command chaining.
_SHELL_META = set(";|&<>`$(){}!*?\\\n")


def _allowed_binaries() -> set[str]:
    """Binaries the exec tool may run (the image allow-list + env override)."""
    names: set[str] = set()
    try:
        with open(ALLOWLIST_FILE, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line and not line.startswith("#"):
                    names.add(os.path.basename(line))
    except OSError:
        pass
    for token in os.environ.get("ALLOWED_COMMANDS", "").replace(",", " ").split():
        names.add(os.path.basename(token.strip()))
    return names


def _allowed_targets() -> set[str]:
    """Hosts the commands may address; empty set = no target restriction."""
    targets: set[str] = set()
    for token in os.environ.get("ALLOWED_TARGETS", "").replace(",", " ").split():
        if token.strip():
            targets.add(token.strip().lower())
    # Derive from the fixed SUT URL the worker already provides.
    target_url = os.environ.get("TARGET_URL", "")
    if target_url:
        host = urlparse(target_url).hostname
        if host:
            targets.add(host.lower())
    # Loopback is always in scope for local tooling.
    targets.update({"127.0.0.1", "localhost", "::1"})
    return targets


def _host_of(token: str) -> str | None:
    """Extract a host from a URL or host[:port] token, else None."""
    if "://" in token:
        return (urlparse(token).hostname or "").lower() or None
    # bare host[:port] — only if it looks like one (no leading dash, has a dot
    # or is localhost, optional :port).
    core = token.split("/", 1)[0]
    host = core.split("@")[-1].split(":")[0]
    if not host or token.startswith("-"):
        return None
    if host in ("localhost", "127.0.0.1") or "." in host:
        return host.lower()
    return None


class RunCommandInput(BaseModel):
    """Arguments for the exec tool."""

    command: str = Field(
        ...,
        description=(
            "Command line to run, e.g. 'nmap -sV http://127.0.0.1:8080' or "
            "'nikto -h 127.0.0.1 -p 8080'. The first token must be an "
            "allow-listed tool for this role."
        ),
    )
    timeout: int = Field(
        600, description="Seconds before the command is killed.")


class RunCommandTool(BaseTool):
    name: str = "run_command"
    description: str = (
        "Run one allow-listed security/scanning command inside your container "
        "and get its output. Only the tools installed for your role may run "
        "(e.g. the pentester's nmap, nikto, sqlmap, nuclei, whatweb, ffuf, "
        "gobuster, hydra), with no shell, a timeout and a capped output. "
        "Targets are restricted to the one system under test. Use it to perform "
        "the scans your task asks for and capture real evidence (never invent "
        "results)."
    )
    args_schema: type[BaseModel] = RunCommandInput

    def _run(self, command: str = "", timeout: int = 600) -> str:
        command = (command or "").strip()
        if not command:
            return "run_command: empty command"

        allowed = _allowed_binaries()
        if not allowed:
            return ("run_command: no allow-list found (expected "
                    f"{ALLOWLIST_FILE} or ALLOWED_COMMANDS) — execution disabled")

        try:
            tokens = shlex.split(command)
        except ValueError as exc:
            return f"run_command: could not parse command ({exc})"
        if not tokens:
            return "run_command: empty command"

        binary = os.path.basename(tokens[0])
        if binary not in allowed:
            return ("run_command: %r is not allowed for this role. Allowed: %s"
                    % (binary, ", ".join(sorted(allowed))))

        for tok in tokens:
            if any(ch in _SHELL_META for ch in tok):
                return ("run_command: refused — token %r contains shell "
                        "metacharacters" % tok)

        # Scope check: reject any argument that addresses a disallowed host.
        targets = _allowed_targets()
        if targets:
            for tok in tokens[1:]:
                host = _host_of(tok)
                if host and host not in targets:
                    return ("run_command: refused — target %r is out of scope "
                            "(allowed: %s)" % (host, ", ".join(sorted(targets))))

        exe = shutil.which(binary)
        if not exe:
            return (f"run_command: {binary!r} is allow-listed but not installed "
                    "in this image")

        try:
            limit = max(1, min(int(timeout or DEFAULT_TIMEOUT), int(DEFAULT_TIMEOUT) * 4))
        except (TypeError, ValueError):
            limit = int(DEFAULT_TIMEOUT)
        cwd = WORK_DIR if os.path.isdir(WORK_DIR) else None
        try:
            proc = subprocess.run(
                tokens, shell=False, cwd=cwd, capture_output=True,
                text=True, timeout=limit,
            )
        except subprocess.TimeoutExpired:
            return f"run_command: {binary} timed out after {limit}s"
        except (OSError, ValueError) as exc:
            return f"run_command: failed to start {binary}: {exc}"

        out = (proc.stdout or "").strip()
        err = (proc.stderr or "").strip()
        parts = [f"$ {' '.join(tokens)}", f"exit={proc.returncode}"]
        if out:
            parts.append("--- stdout ---\n" + out[-MAX_OUTPUT:])
        if err:
            parts.append("--- stderr ---\n" + err[-MAX_OUTPUT:])
        return "\n".join(parts)


# crewai >= 1.15 loads JSON-project tools from tools/<name>.py without putting
# the module in sys.modules; pydantic then cannot resolve the deferred
# `type[BaseModel]` forward ref in args_schema. Rebuild with an explicit
# namespace so the class is concrete under both loaders.
RunCommandTool.model_rebuild(force=True, _types_namespace=globals())
