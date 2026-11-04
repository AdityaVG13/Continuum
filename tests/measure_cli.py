#!/usr/bin/env python3
"""End-to-end: the measurement command records evidence or refuses to.

The claim under test is narrow and checkable: `--measure` probes a named target
twice (idle, then under a sustained bulk transfer), writes an immutable artifact
with both sample counts, and refuses a run whose evidence is too thin. It must
not report a number it did not measure.

Run: python3 tests/measure_cli.py <continuum-binary>
"""
import json
import os
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import NoReturn

BULK_BYTES = 2 << 20
PING_BODY = b"pong\n"
BULK_BODY = b"x" * BULK_BYTES
UPLOAD_BYTES = 262144


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        if self.path.startswith("/bulk"):
            body = BULK_BODY
        elif self.path.startswith("/nothing"):
            # A 200-looking endpoint that moves no body: a "loaded" window with
            # no load must not be reportable as evidence.
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.send_header("Connection", "close")
            self.end_headers()
            return
        else:
            body = PING_BODY
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        remaining = int(self.headers.get("Content-Length") or 0)
        while remaining > 0:
            chunk = self.rfile.read(min(remaining, 65536))
            if not chunk:
                break
            remaining -= len(chunk)
        if self.path.startswith("/bulk") and remaining == 0:
            self.send_response(200)
        else:
            # A refused upload is not a filled pipe; the client must not count it.
            self.send_response(404)
        self.send_header("Content-Length", "0")
        self.send_header("Connection", "close")
        self.end_headers()

    def log_message(self, format, *args):
        pass


def fail(message, extra="") -> NoReturn:
    print("MEASURE_CHECK_FAILED " + message + (("\n" + extra) if extra else ""))
    sys.exit(1)


def main():
    if len(sys.argv) != 2:
        fail("usage", "python3 tests/measure_cli.py <continuum-binary>")
    binary = str(Path(sys.argv[1]).resolve())

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    port = server.server_address[1]
    target = "127.0.0.1:%d/ping" % port
    load_path = "/bulk"

    with tempfile.TemporaryDirectory(prefix="continuum-measure-") as home:
        env = dict(os.environ, XDG_CONFIG_HOME=str(Path(home) / "config"), HOME=home)
        device_dir = Path(home) / "config/continuum/device"

        def run(*args, extra_env=None):
            merged = dict(env, **(extra_env or {}))
            return subprocess.run([binary, *args], env=merged, capture_output=True,
                                  text=True, timeout=180)

        # 1. A target without a port cannot be probed; nothing is written.
        refused = run("--measure", "127.0.0.1", load_path)
        if refused.returncode == 0 or "MEASURE_REFUSED target_must_be_host:port/path" not in refused.stdout:
            fail("a portless target must be refused", refused.stdout + refused.stderr)
        if device_dir.exists() and any(device_dir.glob("measure-*.json")):
            fail("a refused run must not leave evidence behind")

        # 2. Asking for fewer samples than the floor is refused, not rounded up.
        thin = run("--measure", target, load_path, extra_env={"CONTINUUM_MEASURE_SAMPLES": "3"})
        if thin.returncode == 0 or "MEASURE_REFUSED insufficient_samples" not in thin.stdout:
            fail("a below-floor sample request must be refused", thin.stdout + thin.stderr)

        # 3. A load path that moves no body is not a loaded window. The refusal
        #    is still recorded: the artifact is how a failed measurement is
        #    audited later.
        empty_load = run("--measure", target, "/nothing")
        if empty_load.returncode == 0 or "no_load_observed" not in empty_load.stdout:
            fail("a load path with no body must not produce claimable evidence", empty_load.stdout + empty_load.stderr)
        refused_artifacts = sorted(device_dir.glob("measure-*.json"))
        if len(refused_artifacts) != 1:
            fail("a probed but unclaimable run keeps exactly one artifact", str(refused_artifacts))
        if json.loads(refused_artifacts[0].read_text()).get("verdict") != "no_load_observed":
            fail("the artifact must carry the refusal verdict", refused_artifacts[0].read_text())

        # 4. A real run: idle + loaded windows against a live endpoint.
        measured = run("--measure", target, load_path)
        if measured.returncode != 0:
            fail("measurement run failed", measured.stdout + measured.stderr)
        try:
            receipt = json.loads(measured.stdout.strip().splitlines()[-1])
        except (ValueError, IndexError):
            fail("receipt is not one JSON object", measured.stdout)
        if receipt.get("verdict") != "claimable":
            fail("a clean run must be claimable", measured.stdout)
        evidence = receipt.get("evidence") or {}
        if evidence.get("idle_samples") != 20 or evidence.get("loaded_samples") != 20:
            fail("both windows must carry the full sample count", measured.stdout)
        if evidence.get("idle_failures") != 0 or evidence.get("loaded_failures") != 0:
            fail("no probe may fail against a live endpoint", measured.stdout)
        for key in ("idle_p50_ms", "idle_p95_ms", "loaded_p50_ms", "loaded_p95_ms"):
            if not isinstance(evidence.get(key), (int, float)):
                fail("missing %s in the evidence" % key, measured.stdout)
        if evidence["idle_p95_ms"] < evidence["idle_p50_ms"] or evidence["loaded_p95_ms"] < evidence["loaded_p50_ms"]:
            fail("p95 below p50 contradicts the definition", measured.stdout)
        if evidence.get("load_bytes", 0) < BULK_BYTES:
            fail("the load window must move at least one full bulk body", measured.stdout)
        if evidence.get("load_goodput_kbps", 0) <= 0:
            fail("goodput must be measured, not assumed", measured.stdout)

        # 5. Evidence is durable, private, and never overwritten by the next run.
        artifacts = sorted(device_dir.glob("measure-*.json"))
        if len(artifacts) != 2:
            fail("one artifact per run, including the refused one", str(artifacts))
        artifact = artifacts[-1]
        if artifact.stat().st_mode & 0o077:
            fail("measurement artifacts must be private", oct(artifact.stat().st_mode))
        stored = json.loads(artifact.read_text())
        if stored != receipt:
            fail("the artifact must be the printed receipt, byte for byte")

        # 6. Upload load is the direction a router's egress shaping can influence.
        uploaded = run("--measure", target, load_path, "--upload")
        if uploaded.returncode != 0:
            fail("a clean upload run failed", uploaded.stdout + uploaded.stderr)
        up = json.loads(uploaded.stdout.strip().splitlines()[-1])
        up_evidence = up.get("evidence") or {}
        if up.get("verdict") != "claimable":
            fail("a clean upload run must be claimable", uploaded.stdout)
        if up_evidence.get("load_direction") != "upload":
            fail("the receipt must name the load direction", uploaded.stdout)
        if up_evidence.get("load_bytes", 0) < UPLOAD_BYTES:
            fail("one accepted upload must be counted as load", uploaded.stdout)
        if up_evidence.get("loaded_samples") != 20:
            fail("the upload window must carry the full sample count", uploaded.stdout)

        # 7. A rejected upload is not a filled pipe.
        refused_upload = run("--measure", target, "/nothing", "--upload")
        if refused_upload.returncode == 0 or "no_load_observed" not in refused_upload.stdout:
            fail("a rejected upload must not produce claimable evidence", refused_upload.stdout)

        second = run("--measure", target, load_path)
        if second.returncode != 0:
            fail("second run failed", second.stdout + second.stderr)
        artifact_count = len(list(device_dir.glob("measure-*.json")))
        if artifact_count != 5:
            fail("a later run must add evidence, never replace it", str(artifact_count))

    server.shutdown()
    server.server_close()
    print("MEASURE_CHECK_GREEN target=%s samples=20 artifacts=%d" % (target, artifact_count))


if __name__ == "__main__":
    main()
