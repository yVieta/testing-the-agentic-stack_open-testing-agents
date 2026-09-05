#!/usr/bin/env python3
"""MQTT worker that runs one crewAI agent on a Raspberry Pi.

Each Raspberry Pi runs exactly one worker. The worker:

  1. subscribes to its MQTT input topic (QoS 1),
  2. when a message arrives it kicks off ``crewai run`` in the current
     working directory (which must contain the compiled crew.json +
     pyproject.toml for this PI),
  3. saves the incoming payload to ``previous_output.md`` so downstream
     agents can read it with their FileReadTool,
  4. publishes the final output to the next agent's MQTT topic,
  5. publishes lifecycle status to ``crew/status/<role>``.

Run it from the per-PI directory, e.g.:

    cd build/pi1-e2e && python3 /path/to/worker.py

Environment is read from ``.env`` in the current directory (and from the
process environment, which takes precedence).
"""

import hashlib
import json
import logging
import os
import ssl
import subprocess
import sys
import threading
import time
from collections import deque
from pathlib import Path

import paho.mqtt.client as mqtt

log = logging.getLogger("crew-worker")

# role -> {input topic (suffix), output topic (suffix), next role}
PIPELINE = {
    "e2e_test_agent": {
        "input": "start",
        "output": "pentester/input",
    },
    "pentester_agent": {
        "input": "pentester/input",
        "output": "manager/input",
    },
    "test_manager_agent": {
        "input": "manager/input",
        "output": "final",
    },
}

# Directory name -> agent role (used when CREW_ROLE is not set).
DIR_ROLE = {
    "pi1-e2e": "e2e_test_agent",
    "pi2-pentester": "pentester_agent",
    "pi3-manager": "test_manager_agent",
}


def load_dotenv(path: Path) -> None:
    """Minimal .env parser; process environment wins over file values."""
    if not path.exists():
        return
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
            value = value[1:-1]
        if key:
            os.environ.setdefault(key, value)


class Worker:
    QUEUE = 32  # messages buffered while a crew is running
    DEDUPE_CAP = 256

    def __init__(self, role: str, cfg: dict, cwd: Path):
        self.role = role
        self.cfg = cfg
        self.cwd = cwd
        self.prefix = cfg["topic_prefix"]
        self.input_topic = f"{self.prefix}/{cfg['pipeline'][role]['input']}"
        self.output_topic = f"{self.prefix}/{cfg['pipeline'][role]['output']}"
        self.queue: deque = deque(maxlen=cfg["queue_size"])
        self.seen: deque = deque(maxlen=cfg["dedupe_cap"])
        self.client = self._build_client()
        self._lock = threading.RLock()

    # -- MQTT ----------------------------------------------------------------
    def _build_client(self) -> mqtt.Client:
        client = mqtt.Client(
            mqtt.CallbackAPIVersion.VERSION2,
            client_id=f"crewai-{self.role}",
            clean_session=True,
        )
        client.username_pw_set(self.cfg["broker_user"], self.cfg["broker_pass"])
        ca = self.cfg.get("tls_ca")
        if ca:
            client.tls_set(
                ca_certs=str(ca),
                certfile=None,
                keyfile=None,
                tls_version=ssl.PROTOCOL_TLS_CLIENT,
            )
            if not self.cfg.get("tls_require_cert", True):
                client.tls_insecure_set(True)
        client.on_connect = self._on_connect
        client.on_connect_fail = self._on_connect_fail
        client.on_disconnect = self._on_disconnect
        client.on_message = self._on_message
        return client

    def _on_connect(self, client, userdata, flags, reason_code, properties=None):
        if reason_code == 0:
            client.subscribe(self.input_topic, qos=1)
            log.info("connected to %s, subscribed to %s (QoS 1)", self.cfg["broker_host"], self.input_topic)
            self._status("idle")
        else:
            log.error("connection refused: %s", reason_code)

    def _on_connect_fail(self, client, userdata, flags, reason_code, properties=None):
        log.warning("connect attempt failed (%s); retrying", reason_code)

    def _on_disconnect(self, client, userdata, flags, reason_code, properties=None):
        log.warning("disconnected (%s); paho will reconnect", reason_code)

    def _on_message(self, client, userdata, msg):
        digest = hashlib.sha256((msg.topic + msg.payload.decode("utf-8", "replace")).encode()).hexdigest()
        with self._lock:
            if digest in self.seen:
                log.info("ignore duplicate message (already handled)")
                return
            self.seen.append(digest)
        log.info("message on %s (%d bytes)", msg.topic, len(msg.payload))
        try:
            self.queue.append(msg)
        except Exception:  # deque no longer accepts
            log.warning("queue full; dropping old message")

    # -- pipeline -------------------------------------------------------------
    def _status(self, state: str, detail: str = ""):
        payload = json.dumps(
            {"role": self.role, "state": state, "detail": detail, "ts": time.time()}
        )
        self.client.publish(f"{self.prefix}/status/{self.role}", payload, qos=1)

    def _run_crew(self) -> str:
        """Run this PI's crew and return its output."""
        if not (self.cwd / "crew.json").exists():
            raise RuntimeError(
                f"crew.json not found in {self.cwd} - run make or copy a "
                "build/piN-* directory here"
            )
        inputs = {"target_url": self.cfg.get("target_url", "")}
        cmd = ["crewai", "run", "--inputs", json.dumps(inputs)]
        log.info("running: %s", " ".join(cmd))
        proc = subprocess.run(
            cmd,
            cwd=str(self.cwd),
            capture_output=True,
            text=True,
            timeout=self.cfg["crew_timeout"],
        )
        out = proc.stdout or ""
        err = proc.stderr or ""
        if proc.returncode != 0:
            raise RuntimeError(f"crewai run failed (rc={proc.returncode})\nSTDERR:\n{err[-2000:]}")
        return out or err or "(no output)"

    def _handle(self, payload: str):
        run_id = f"{self.role}-{int(time.time())}"
        self._status("running", run_id)
        try:
            prev = self.cwd / "previous_output.md"
            if payload.strip():
                prev.write_text(payload)
                log.info("saved %s bytes to %s", len(payload), prev.name)

            output = self._run_crew()
            self.client.publish(self.output_topic, output, qos=1, retain=False)
            log.info("published %d bytes to %s", len(output), self.output_topic)
            self._status("done", run_id)
        except Exception as exc:  # noqa: BLE001 - report any failure over MQTT
            log.exception("task failed")
            self._status("failed", f"{run_id} {exc}")

    def run(self):
        broker_host = self.cfg["broker_host"]
        broker_port = self.cfg["broker_port"]
        log.info(
            "%s worker -> listen %s | publish %s", self.role, self.input_topic, self.output_topic
        )
        try:
            self.client.connect(broker_host, broker_port, keepalive=60)
        except Exception as exc:  # noqa: BLE001
            log.error("cannot connect to broker %s:%s: %s (is mosquitto up?)", broker_host, broker_port, exc)
            raise SystemExit(1)
        self.client.loop_start()

        while True:
            msg = self.queue.popleft() if self.queue else None
            if msg is None:
                time.sleep(0.5)
                continue
            self._handle(msg.payload.decode("utf-8", "replace"))


def build_config(cwd: Path) -> dict:
    role = os.environ.get("CREW_ROLE") or (cwd.name.split("-", 1)[1] if "-" in cwd.name else "")
    if role not in PIPELINE:
        raise SystemExit(
            f"CREW_ROLE must be one of {sorted(PIPELINE)} (got {role!r}). "
            "Set it in .env or pass a role-dir like pi1-e2e."
        )
    pipeline = PIPELINE
    cfg = {
        "role": role,
        "pipeline": {
            r: {"input": v["input"], "output": v["output"]} for r, v in PIPELINE.items()
        },
        "topic_prefix": os.environ.get("MQTT_TOPIC_PREFIX", "crew"),
        "broker_host": os.environ.get("BROKER_HOST", "127.0.0.1"),
        "broker_port": int(os.environ.get("BROKER_PORT", "1883")),
        "broker_user": os.environ.get("BROKER_USERNAME", ""),
        "broker_pass": os.environ.get("BROKER_PASSWORD", ""),
        "tls_ca": os.environ.get("BROKER_TLS_CA", ""),
        "tls_require_cert": os.environ.get("BROKER_TLS_REQUIRE_CERT", "true").lower() == "true",
        "target_url": os.environ.get("TARGET_URL", ""),
        "crew_timeout": int(os.environ.get("CREW_TIMEOUT", "3600")),
        "queue_size": 32,
        "dedupe_cap": 256,
    }
    return cfg


def main(argv=None):
    argv = argv if argv is not None else sys.argv[1:]
    parser = argparse.ArgumentParser(description="crewAI MQTT worker for one Raspberry Pi")
    parser.add_argument("--dir", default=".", help="per-PI directory (default: cwd)")
    parser.add_argument("--verbose", action="store_true", help="enable debug logging")
    args = parser.parse_args(argv)

    cwd = Path(args.dir).resolve()
    load_dotenv(cwd / ".env")

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    cfg = build_config(cwd)
    Worker(cfg["role"], cfg, cwd).run()


if __name__ == "__main__":
    main()