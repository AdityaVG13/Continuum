#!/usr/bin/env python3
"""Continuum virtual stock router (item 6 test double).

A small HTTP admin API with the shape of a stock home-router web backend:
password session, QoS knob with readback, client list, status, reboot.
Acts as the target for the C++ WebApi transport before any real hardware
is touched. stdlib only, no root needed.

  ROUTER_PASSWORD=test-only-pw python3 router_server.py [port]

State (revision, qos) persists in a JSON file beside the script so a
server restart behaves like NVRAM, not amnesia. A reboot drops sessions
and bumps the revision, like real firmware.
"""
import hashlib
import json
import os
import secrets
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse

STATE_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           "router_state.json")
SESSION_TTL = 3600


def load_state():
    try:
        with open(STATE_PATH) as f:
            st = json.load(f)
        st.setdefault("revision", 1)
        st.setdefault("qos", {"on": False, "rate_mbit": 100})
        st.setdefault("boot_id", 0)
        return st
    except (OSError, ValueError):
        return {"revision": 1, "qos": {"on": False, "rate_mbit": 100},
                "boot_id": 0}


def save_state(st):
    tmp = STATE_PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(st, f)
    os.replace(tmp, STATE_PATH)


STATE = load_state()
SESSIONS = {}  # token -> expires_at
PASSWORD = os.environ.get("ROUTER_PASSWORD", "")


def authed(headers):
    auth = headers.get("Authorization", "")
    if not auth.startswith("Bearer "):
        return False
    tok = auth[7:]
    exp = SESSIONS.get(tok)
    if not exp or exp < time.time():
        SESSIONS.pop(tok, None)
        return False
    return True


def body_json(handler):
    try:
        n = int(handler.headers.get("Content-Length", "0"))
    except ValueError:
        return None
    if n <= 0 or n > 8192:
        return None
    try:
        return json.loads(handler.rfile.read(n))
    except ValueError:
        return None


class Router(BaseHTTPRequestHandler):
    server_version = "ContRouter/0.1"
    protocol_version = "HTTP/1.0"

    def log_message(self, format: str, *args: object) -> None:
        pass

    def send_json(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        path = urlparse(self.path).path
        if path == "/api/login":
            req = body_json(self)
            if not req or req.get("password") != PASSWORD or not PASSWORD:
                self.send_json(401, {"error": "bad credentials"})
                return
            tok = secrets.token_hex(16)
            SESSIONS[tok] = time.time() + SESSION_TTL
            self.send_json(200, {"session": tok,
                                 "expires_in": SESSION_TTL})
            return
        if not authed(self.headers):
            self.send_json(401, {"error": "auth required"})
            return
        if path == "/api/qos":
            req = body_json(self)
            if not req or not isinstance(req.get("on"), bool):
                self.send_json(400, {"error": "need bool 'on'"})
                return
            rate = req.get("rate_mbit", STATE["qos"]["rate_mbit"])
            if not isinstance(rate, int) or rate < 1 or rate > 1000:
                self.send_json(400, {"error": "rate_mbit 1..1000"})
                return
            STATE["qos"] = {"on": req["on"], "rate_mbit": rate}
            STATE["revision"] += 1
            save_state(STATE)
            self.send_json(200, {"qos": STATE["qos"],
                                 "revision": STATE["revision"]})
            return
        if path == "/api/reboot":
            STATE["revision"] += 1
            STATE["boot_id"] += 1
            save_state(STATE)
            SESSIONS.clear()
            self.send_json(200, {"rebooting": True,
                                 "revision": STATE["revision"]})
            return
        self.send_json(404, {"error": "unknown endpoint"})

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/api/status":
            self.send_json(200, {"revision": STATE["revision"],
                                 "boot_id": STATE["boot_id"],
                                 "model": "ContRouter v0.1 (virtual)"})
            return
        if not authed(self.headers):
            self.send_json(401, {"error": "auth required"})
            return
        if path == "/api/qos":
            self.send_json(200, {"qos": STATE["qos"],
                                 "revision": STATE["revision"]})
            return
        if path == "/api/clients":
            self.send_json(200, {"clients": [
                {"mac": "aa:bb:cc:dd:ee:01", "ip": "192.168.1.101",
                 "hostname": "lab-cli"},
                {"mac": "aa:bb:cc:dd:ee:02", "ip": "192.168.1.102",
                 "hostname": "lab-phone"}]})
            return
        self.send_json(404, {"error": "unknown endpoint"})


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 18080
    if not PASSWORD:
        print("ROUTER_PASSWORD is empty: refusing to serve", flush=True)
        sys.exit(2)
    fp = hashlib.sha256(PASSWORD.encode()).hexdigest()[:8]
    # Localhost by default. Set ROUTER_BIND to the lab host's Tailscale IP
    # to let a remote Continuum binary reach the double; never 0.0.0.0 on a
    # laptop that roams across untrusted LANs.
    bind = os.environ.get("ROUTER_BIND", "127.0.0.1")
    print(f"virtual router on {bind}:{port} (password sha256 prefix {fp})",
          flush=True)
    HTTPServer((bind, port), Router).serve_forever()
