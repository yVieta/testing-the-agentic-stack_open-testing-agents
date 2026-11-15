"""MCP server exposing the self-hosted Qwen3-Coder model as agent tools.

The model is llama.cpp's OpenAI-compatible endpoint (see ``model-setup/``), so
this server is a thin, well-behaved MCP facade over HTTP: it adds MCP tool
schemas, bearer-token auth, and the reasoning/finish-reason handling that
Qwen3 needs in order to be usable by an autonomous agent.

Transport is selectable because the deployment story differs:

    --transport streamable-http   (default) served by uvicorn on MCP_PORT.
                                   One instance on the model host; crewAI on
                                   each Raspberry Pi connects over the LAN with
                                   MCPServerHTTP. Keeps the model itself bound
                                   to 127.0.0.1.
    --transport stdio             spawned as a child process by crewAI
                                   (MCPServerStdio). Useful for local testing
                                   and for hosts that can already reach the
                                   model port directly.

Configuration is environment-only (no argparse for the knobs, so the unit file
and crewAI both just set env):

    MODEL_URL        base URL of llama.cpp, e.g. http://127.0.0.1:18080/v1
    MODEL_NAME       model id to send in requests
    MODEL_API_KEY    bearer token if llama-server runs with --api-key ("" = off)
    MODEL_TIMEOUT    seconds per completion (CPU inference is slow; default 900)
    MODEL_CONTEXT    context window, advertised by qwen_info
    MCP_HOST         bind address for streamable-http (default 127.0.0.1)
    MCP_PORT         bind port for streamable-http (default 18081)
    MCP_BEARER_TOKEN required shared secret clients must present (streamable-http)
    MCP_ALLOWED_HOSTS / MCP_ALLOWED_ORIGINS
                     comma-separated allowlists for DNS-rebinding defence
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request

from mcp.server.mcpserver import MCPServer

MODEL_URL = os.environ.get("MODEL_URL", "http://127.0.0.1:18080/v1").rstrip("/")
MODEL_NAME = os.environ.get("MODEL_NAME", "qwen3-coder-30b-a3b-instruct")
MODEL_API_KEY = os.environ.get("MODEL_API_KEY", "")
MODEL_TIMEOUT = int(os.environ.get("MODEL_TIMEOUT", "900"))
MODEL_CONTEXT = int(os.environ.get("MODEL_CONTEXT", "16384"))

MCP_HOST = os.environ.get("MCP_HOST", "127.0.0.1")
MCP_PORT = int(os.environ.get("MCP_PORT", "18081"))
MCP_BEARER_TOKEN = os.environ.get("MCP_BEARER_TOKEN", "")

_ALLOWED_HOSTS = tuple(
    h.strip()
    for h in os.environ.get("MCP_ALLOWED_HOSTS", f"127.0.0.1,localhost,[::1]").split(",")
    if h.strip()
)
_ALLOWED_ORIGINS = tuple(
    o.strip()
    for o in os.environ.get("MCP_ALLOWED_ORIGINS", "").split(",")
    if o.strip()
)

server = MCPServer(
    name="aigents-model",
    instructions=(
        "Self-hosted Qwen3-Coder MoE served by llama.cpp on the local network. "
        "Use qwen_chat for reasoning, code and test-generation tasks; "
        "qwen_complete to continue a code prefix; qwen_info to check that the "
        "model is loaded and see its context size.\n\n"
        "qwen_chat returns only the answer. The model is a reasoning model, so "
        "it may spend most of a token budget thinking: always pass a "
        "max_tokens large enough for both thinking and the answer, and treat a "
        "'truncated' status as 'ask again with a bigger budget' rather than as "
        "an empty answer."
    ),
)


class ModelError(RuntimeError):
    """Raised when the model endpoint is unreachable or returns an error."""


def _post(path: str, payload: dict) -> dict:
    body = json.dumps(payload).encode()
    req = urllib.request.Request(f"{MODEL_URL}{path}", data=body, method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json")
    if MODEL_API_KEY:
        req.add_header("Authorization", f"Bearer {MODEL_API_KEY}")
    try:
        with urllib.request.urlopen(req, timeout=MODEL_TIMEOUT) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")[:500]
        raise ModelError(f"model endpoint returned HTTP {exc.code}: {detail}") from exc
    except urllib.error.URLError as exc:
        raise ModelError(
            f"cannot reach model at {MODEL_URL} ({exc.reason}). Is "
            f"qwen-coder.service running?"
        ) from exc
    except TimeoutError as exc:
        raise ModelError(
            f"model did not answer within {MODEL_TIMEOUT}s. This host runs "
            f"CPU-only inference; raise MODEL_TIMEOUT or lower max_tokens."
        ) from exc


def _get(path: str) -> dict:
    req = urllib.request.Request(f"{MODEL_URL}{path}")
    req.add_header("Accept", "application/json")
    if MODEL_API_KEY:
        req.add_header("Authorization", f"Bearer {MODEL_API_KEY}")
    try:
        with urllib.request.urlopen(req, timeout=min(MODEL_TIMEOUT, 30)) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as exc:
        raise ModelError(f"model endpoint returned HTTP {exc.code}") from exc
    except urllib.error.URLError as exc:
        raise ModelError(f"cannot reach model at {MODEL_URL} ({exc.reason})") from exc


def _usage_line(usage: dict) -> str:
    if not usage:
        return ""
    return (
        f"[tokens: {usage.get('prompt_tokens', '?')} prompt + "
        f"{usage.get('completion_tokens', '?')} completion]"
    )


# --------------------------------------------------------------------------- #
# tools
# --------------------------------------------------------------------------- #


@server.tool()
def qwen_chat(
    prompt: str,
    system: str | None = None,
    max_tokens: int = 2048,
    temperature: float = 0.2,
    think: bool = False,
) -> str:
    """Ask Qwen3-Coder a question. Returns the answer text only.

    Use this for reasoning, code generation, test generation, and analysis.
    `prompt` is the full user message; `system` optionally sets the persona.

    Set `think=True` to let the model reason before answering. Qwen3 reasons by
    default, and the thinking tokens come out of the same `max_tokens` budget, so
    give a generous budget (2048+) or the answer can come back empty.

    Returns the answer, plus a status line. `status: truncated` means the token
    budget ran out mid-answer — re-ask with a larger max_tokens.
    """
    messages = []
    if system:
        messages.append({"role": "system", "content": system})
    messages.append({"role": "user", "content": prompt})

    payload: dict = {
        "model": MODEL_NAME,
        "messages": messages,
        "max_tokens": max_tokens,
        "temperature": temperature,
    }
    if not think:
        # Strip the thinking phase. `none` leaves any residual <think> tags
        # inline in content, so they are removed separately below.
        payload["reasoning_format"] = "none"
        payload["chat_template_kwargs"] = {"enable_thinking": False}

    data = _post("/chat/completions", payload)
    choice = (data.get("choices") or [{}])[0]
    message = choice.get("message") or {}
    text = (message.get("content") or "").strip()
    reasoning = (message.get("reasoning_content") or "").strip()
    finish = choice.get("finish_reason", "unknown")

    if "<think>" in text or "</think>" in text:
        text = _strip_think_tags(text).strip()

    if not text:
        hint = ""
        if reasoning:
            hint = (
                "\n\nThe model produced only reasoning and no answer. Retry with "
                "a larger max_tokens (or think=False)."
            )
        return (
            f"status: empty\n{_usage_line(data.get('usage') or {})}"
            f"{hint}".strip()
        )

    status = "truncated" if finish == "length" else "ok"
    tail = ""
    if status == "truncated":
        tail = (
            "\n\nstatus: truncated (hit max_tokens mid-answer — re-ask with a "
            "larger max_tokens if the response looks cut off)"
        )
    if think and reasoning:
        tail += f"\n\n--- reasoning ---\n{reasoning}"
    return f"{text}\n\n[{status} {_usage_line(data.get('usage') or {})}]{tail}".strip()


@server.tool()
def qwen_complete(
    prefix: str,
    max_tokens: int = 512,
    temperature: float = 0.0,
) -> str:
    """Continue a raw text/code prefix using llama.cpp's completion endpoint.

    Use this when you need literal continuation of code or text *without* the
    chat template. For normal questions and instructions use qwen_chat instead.
    """
    data = _post(
        "/completions",
        {
            "model": MODEL_NAME,
            "prompt": prefix,
            "max_tokens": max_tokens,
            "temperature": temperature,
        },
    )
    choice = (data.get("choices") or [{}])[0]
    text = (choice.get("text") or "").strip()
    finish = choice.get("finish_reason", "unknown")
    if not text:
        return f"status: empty\n{_usage_line(data.get('usage') or {})}"
    status = "truncated" if finish == "length" else "ok"
    return f"{text}\n\n[{status} {_usage_line(data.get('usage') or {})}]".strip()


@server.tool()
def qwen_info() -> str:
    """Report model server health and configuration.

    Use this to check the model is loaded before blaming the model for a bad
    answer, and to see the served model id and context size.
    """
    try:
        models = _get("/models")
    except ModelError as exc:
        return f"status: unreachable\n{exc}"

    ids = [m.get("id") for m in models.get("data", []) if m.get("id")]
    return "\n".join(
        [
            "status: ok",
            f"endpoint: {MODEL_URL}",
            f"model: {MODEL_NAME}",
            f"reported models: {', '.join(ids) if ids else '(none)'}",
            f"context: {MODEL_CONTEXT}",
            f"auth: {'bearer token required' if MODEL_API_KEY else 'none (model port is localhost-only)'}",
            f"thinking: {'on by default, disable per-request with think=False' }",
        ]
    )


def _strip_think_tags(text: str) -> str:
    """Remove <think>...</think> blocks, including an unterminated trailing one."""
    result, i, in_think = [], 0, False
    while i < len(text):
        if not in_think and text.startswith("<think>", i):
            in_think, i = True, i + len("<think>")
            continue
        if in_think and text.startswith("</think>", i):
            in_think, i = False, i + len("</think>")
            continue
        if not in_think:
            result.append(text[i])
        i += 1
    return "".join(result)


def _build_auth_middleware(app):
    """Require a bearer token and reject unexpected Host/Origin headers.

    Implemented as plain ASGI middleware rather than the SDK's auth provider so
    it does not depend on mcp 1.x-vs-2.x internals, and so the exact policy is
    readable in one place.
    """
    if not MCP_BEARER_TOKEN:
        # Fail loudly rather than silently serving an open model to the LAN.
        if MCP_HOST not in ("127.0.0.1", "::1", "localhost"):
            raise SystemExit(
                "refusing to bind to %s without MCP_BEARER_TOKEN: anyone who "
                "reaches this port could run inference" % MCP_HOST
            )
        print(
            "warning: MCP_BEARER_TOKEN unset; serving unauthenticated on "
            "localhost only",
            file=sys.stderr,
        )

    allowed_hosts = set(_ALLOWED_HOSTS)
    allowed_origins = set(_ALLOWED_ORIGINS)

    class AuthMiddleware:
        def __init__(self, app):
            self.app = app

        async def __call__(self, scope, receive, send):
            if scope["type"] != "http":
                await self.app(scope, receive, send)
                return

            headers = {
                k.decode("latin-1").lower(): v.decode("latin-1")
                for k, v in scope.get("headers", [])
            }

            host = headers.get("host", "").rsplit(":", 1)[0] if ":" in headers.get("host", "") else headers.get("host", "")
            if host and allowed_hosts and host not in allowed_hosts:
                await _reject(send, 403, f"host {host!r} is not allowed")
                return

            origin = headers.get("origin")
            # crewAI will send none, which is the trusted case here..
            if origin and allowed_origins and origin not in allowed_origins:
                await _reject(send, 403, f"origin {origin!r} is not allowed")
                return

            if MCP_BEARER_TOKEN:
                auth = headers.get("authorization", "")
                if not auth.startswith("Bearer ") or not _constant_eq(
                    auth[7:].strip(), MCP_BEARER_TOKEN
                ):
                    await _reject(send, 401, "missing or invalid bearer token")
                    return

            await self.app(scope, receive, send)

    return AuthMiddleware(app)


def _constant_eq(a: str, b: str) -> bool:
    """Compare without leaking length/prefix through timing."""
    import hmac

    return hmac.compare_digest(a, b)


async def _reject(send, status: int, detail: str) -> None:
    body = json.dumps({"error": detail}).encode()
    await send(
        {
            "type": "http.response.start",
            "status": status,
            "headers": [
                (b"content-type", b"application/json"),
                (b"content-length", str(len(body)).encode()),
            ],
        }
    )
    await send({"type": "http.response.body", "body": body})

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--transport",
        choices=["streamable-http", "stdio"],
        default="streamable-http",
        help="streamable-http serves uvicorn on MCP_HOST:MCP_PORT; stdio speaks MCP on stdin/stdout",
    )
    args = parser.parse_args()

    if args.transport == "stdio":
        server.run(transport="stdio")
        return

    import uvicorn

    app = server.streamable_http_app(
        stateless_http=True,
        json_response=True,
        host=MCP_HOST,
    )
    app = _build_auth_middleware(app)
    uvicorn.run(app, host=MCP_HOST, port=MCP_PORT, log_level="warning")


if __name__ == "__main__":
    main()
