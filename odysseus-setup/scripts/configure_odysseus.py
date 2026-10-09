#!/usr/bin/env python3
"""Idempotently seed the Odysseus workspace during `tofu apply`.

Invoked by odysseus-setup's `configure_odysseus` step with the path to a JSON
seed file (rendered from the module variables). It:

  1. waits for the app to become healthy,
  2. logs in as the admin (password read from the generated credentials.env),
  3. registers the single phi-4-mini endpoint if missing and prunes stale model
  4. endpoints that still point at the retired CLI-only instance (port 18081),
  5. installs / activates the "Test Manager" character preset.

Every step is a no-op when the object already exists, so re-running the tofu
apply does not create duplicates. Only the standard library is used.
"""

import http.cookiejar
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


def _read_env(path):
    """Parse a shell-style KEY="value" file into a dict."""
    env = {}
    try:
        with open(path) as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, val = line.split("=", 1)
                env[key.strip()] = val.strip().strip('"').strip("'")
    except OSError as exc:
        print(f"odysseus-seed: cannot read {path}: {exc}", file=sys.stderr)
    return env


class Client:
    def __init__(self, base):
        self.base = base.rstrip("/")
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar())
        )

    def _open(self, method, path, data=None, form=False):
        headers = {}
        body = None
        if data is not None:
            if form:
                body = urllib.parse.urlencode(data).encode()
                headers["Content-Type"] = "application/x-www-form-urlencoded"
            else:
                body = json.dumps(data).encode()
                headers["Content-Type"] = "application/json"
        req = urllib.request.Request(self.base + path, data=body, method=method, headers=headers)
        return self.opener.open(req, timeout=60)

    def get(self, path):
        return json.load(self._open("GET", path))

    def post(self, path, data, form=False):
        return json.load(self._open("POST", path, data, form=form))

    def patch(self, path, data, form=False):
        return json.load(self._open("PATCH", path, data, form=form))

    def delete(self, path):
        try:
            self._open("DELETE", path)
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                return
            raise


def wait_for_health(client, attempts=80, delay=3):
    for _ in range(attempts):
        try:
            client.get("/api/health")
            return
        except Exception:  # noqa: BLE001 - anything means "not ready yet"
            time.sleep(delay)
    raise SystemExit("odysseus-seed: app never became healthy")


def login(client, user, password, attempts=40, delay=3):
    last = None
    for _ in range(attempts):
        try:
            client.post("/api/auth/login",
                        {"username": user, "password": password, "remember": True})
            return
        except urllib.error.HTTPError as exc:
            last = f"HTTP {exc.code}: {exc.read()[:200]!r}"
        except Exception as exc:  # noqa: BLE001
            last = repr(exc)
        time.sleep(delay)
    raise SystemExit(f"odysseus-seed: admin login failed ({last})")


def ensure_endpoints(client, endpoints):
    desired = {ep["base_url"].rstrip("/"): ep["name"] for ep in endpoints}
    for e in client.get("/api/model-endpoints"):
        url = e.get("base_url", "").rstrip("/")
        name = e.get("name")
        if url in desired and desired[url] == name:
            continue
        # Prune stale model registrations on this host: 18081 was the retired
        # CLI-only instance, 18080 duplicates are redundant with a single model,
        # and a declared URL registered under an old name is recreated so the
        # seed file stays the source of truth.
        if "18081" in url or (":18080" in url and (url not in desired or desired[url] != name)):
            eid = e.get("id")
            if eid is None:
                print(f"odysseus-seed: endpoint {name} -> {url} has no id; skipping",
                      file=sys.stderr)
                continue
            client.delete(f"/api/model-endpoints/{eid}")
            print(f"odysseus-seed: removed stale endpoint {name} -> {url}")
    known = {e.get("base_url", "").rstrip("/") for e in client.get("/api/model-endpoints")}
    for ep in endpoints:
        url = ep["base_url"].rstrip("/")
        if url in known:
            print(f"odysseus-seed: endpoint already present: {ep['name']}")
            continue
        client.post("/api/model-endpoints", {
            "name": ep["name"],
            "base_url": ep["base_url"],
            "endpoint_kind": "api",
            "model_type": "llm",
            "supports_tools": "true",
            "shared": "true",
        }, form=True)
        print(f"odysseus-seed: registered endpoint {ep['name']} -> {ep['base_url']}")


def ensure_preset(client, name, prompt):
    templates = client.get("/api/presets/templates")
    if any(t.get("name") == name for t in templates):
        print(f"odysseus-seed: preset already present: {name}")
    else:
        client.post("/api/presets/templates",
                    {"name": name, "system_prompt": prompt,
                     "temperature": 0.3, "max_tokens": 4096})
        print(f"odysseus-seed: created preset {name}")
    # Make it the active custom character (idempotent).
    client.post("/api/presets/custom",
                {"name": name, "system_prompt": prompt,
                 "temperature": 0.3, "max_tokens": 4096, "enabled": True})
    print(f"odysseus-seed: activated preset {name}")


def main():
    if len(sys.argv) < 2:
        raise SystemExit("usage: configure_odysseus.py <seed.json>")
    cfg = json.load(open(sys.argv[1]))

    creds = _read_env(cfg["credentials_file"])
    password = creds.get("ODYSSEUS_ADMIN_PASSWORD", "")
    if not password:
        raise SystemExit(f"odysseus-seed: no admin password in {cfg['credentials_file']}")

    client = Client(cfg["base_url"])
    wait_for_health(client)
    login(client, cfg.get("admin_user", "admin"), password)
    ensure_endpoints(client, cfg.get("endpoints", []))
    ensure_preset(client, cfg["preset_name"], cfg["preset_prompt"])
    print("odysseus-seed: done")


if __name__ == "__main__":
    main()
