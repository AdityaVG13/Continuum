#!/usr/bin/env python3
"""Contract tests for the virtual stock router. Run against a live server:

  ROUTER_PASSWORD=<pw> python3 router_server.py 18080 &
  ROUTER_PASSWORD=<pw> python3 router_contract.py [port]

Exits 0 only if every behavior the C++ transport will rely on holds:
auth gate, session lifecycle, knob readback, revision bumps, reboot
semantics, and rejection of malformed input. Prints ok/FAIL per check.
"""
import json
import os
import sys
import urllib.error
import urllib.request

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 18080
BASE = f"http://127.0.0.1:{PORT}"
PW = os.environ.get("ROUTER_PASSWORD", "")
CHECKS = []


def check(cond, label):
    print(("ok " if cond else "FAIL ") + label, flush=True)
    CHECKS.append(cond)


def call(method, path, body=None, token=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method)
    if body is not None:
        req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read())
        except ValueError:
            return e.code, {}
    except Exception as e:  # noqa: BLE001 - contract probe reports, not raises
        return -1, {"exception": str(e)}


def main():
    # Wrong password is rejected, right one opens a session.
    s, _ = call("POST", "/api/login", {"password": "wrong"})
    check(s == 401, "wrong password rejected")
    s, r = call("POST", "/api/login", {"password": PW})
    check(s == 200 and len(r.get("session", "")) >= 16,
          "router password opens a session")
    tok = r.get("session", "")

    # Authed reads work; unauthed reads do not (except status).
    s, _ = call("GET", "/api/clients")
    check(s == 401, "client list needs a session")
    s, r = call("GET", "/api/clients", token=tok)
    check(s == 200 and len(r.get("clients", [])) == 2,
          "client list knob answers")

    # QoS knob: write, then read back the same values + bumped revision.
    s, r0 = call("GET", "/api/qos", token=tok)
    rev0 = r0.get("revision", -1)
    s, r = call("POST", "/api/qos",
                {"on": True, "rate_mbit": 20}, token=tok)
    check(s == 200 and r["qos"] == {"on": True, "rate_mbit": 20}
          and r["revision"] == rev0 + 1, "qos knob drives the queue")
    s, r = call("GET", "/api/qos", token=tok)
    check(s == 200 and r["qos"]["on"] is True
          and r["revision"] == rev0 + 1, "knob reads back")

    # Malformed knob writes are rejected without changing state.
    s, _ = call("POST", "/api/qos", {"on": "yes"}, token=tok)
    check(s == 400, "non-bool qos rejected")
    s, _ = call("POST", "/api/qos",
                {"on": True, "rate_mbit": 99999}, token=tok)
    check(s == 400, "out-of-range rate rejected")
    s, r = call("GET", "/api/qos", token=tok)
    check(s == 200 and r["qos"]["rate_mbit"] == 20
          and r["revision"] == rev0 + 1, "rejected writes change nothing")

    # Unknown endpoints 404 even with a session.
    s, _ = call("GET", "/api/nonexistent", token=tok)
    check(s == 404, "unknown endpoint 404s")

    # Reboot drops the session and bumps the revision.
    s, r = call("POST", "/api/reboot", {}, token=tok)
    check(s == 200 and r.get("rebooting") is True
          and r["revision"] == rev0 + 2, "reboot bumps revision")
    s, _ = call("GET", "/api/qos", token=tok)
    check(s == 401, "reboot drops the session")

    # Fresh login after reboot; state survived (NVRAM-like file).
    s, r = call("POST", "/api/login", {"password": PW})
    tok2 = r.get("session", "")
    s, r = call("GET", "/api/qos", token=tok2)
    check(s == 200 and r["qos"] == {"on": True, "rate_mbit": 20}
          and r["revision"] == rev0 + 2, "qos survives reboot")

    # Restore baseline for the next run.
    s, r = call("POST", "/api/qos",
                {"on": False, "rate_mbit": 100}, token=tok2)
    check(s == 200 and r["qos"]["on"] is False, "baseline restored")
    print("ROUTER_CONTRACT_ALL_GREEN" if all(CHECKS)
          else "ROUTER_CONTRACT_RED", flush=True)
    return 0 if all(CHECKS) else 1


if __name__ == "__main__":
    sys.exit(main())
