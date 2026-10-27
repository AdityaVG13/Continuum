#!/usr/bin/env python3
"""Continuum lab: real bufferbloat curves from a veth pair (see
lab/results/2026-10-26-notes.md for what was measured and what it proves).
Runs INSIDE `unshare -Urn` on the lab host. Builds a two-namespace topology
(cli <-> rtr), caps rtr egress at 20mbit with TBF, and measures ping RTT
from cli while a UDP load saturates rtr egress. Compares a dumb deep FIFO
(pfifo) against fq_codel.

Every row prints the ACTUAL achieved load (measured by the sender), not the
requested one. No sudo, no root on the host: everything is unprivileged.

Usage: unshare -Urn python3 cont-lab2.py
"""
import re
import subprocess
import sys
import time

PEER = None  # pid of the rtr-netns holder


def sh(*args, **kwargs):
    p = subprocess.run(args, capture_output=True, text=True, **kwargs)
    return p.returncode, (p.stdout + p.stderr).strip()


def peer(*args):
    return sh("nsenter", "-n", "-t", str(PEER), *args)


def setup():
    global PEER
    rc, out = sh("ip", "link", "set", "lo", "up")
    rc, out = sh("ip", "link", "add", "cli", "type", "veth", "peer", "name",
                 "rtr")
    assert rc == 0, f"veth create failed: {out}"
    holder = subprocess.Popen(["unshare", "-n", "sleep", "300"])
    PEER = holder.pid
    time.sleep(0.3)
    rc, out = sh("ip", "link", "set", "rtr", "netns", str(PEER))
    assert rc == 0, f"move rtr failed: {out}"
    rc, out = sh("ip", "link", "set", "cli", "up")
    assert rc == 0, out
    rc, out = sh("ip", "addr", "add", "10.99.0.1/24", "dev", "cli")
    assert rc == 0, out
    rc, out = peer("ip", "link", "set", "lo", "up")
    assert rc == 0, out
    rc, out = peer("ip", "link", "set", "rtr", "up")
    assert rc == 0, out
    rc, out = peer("ip", "addr", "add", "10.99.0.2/24", "dev", "rtr")
    assert rc == 0, out
    rc, out = sh("ping", "-c", "2", "-W", "1", "10.99.0.2")
    assert rc == 0, f"cross-ns ping failed: {out}"
    return holder


def set_qdisc(kind):
    peer("tc", "qdisc", "del", "dev", "rtr", "root")
    rc, out = peer("tc", "qdisc", "add", "dev", "rtr", "root", "handle", "1:",
                   "tbf", "rate", "20mbit", "burst", "32kbit", "latency",
                   "400ms")
    if rc != 0:
        return f"TBF-FAIL {out}"
    inner = ["pfifo", "limit", "1000"] if kind == "pfifo" else ["fq_codel"]
    rc, out = peer("tc", "qdisc", "add", "dev", "rtr", "parent", "1:1",
                   "handle", "10:", *inner)
    if rc != 0:
        return f"QDISC-FAIL {out}"
    return "ok"


def ping_rtt(count=10):
    rc, out = sh("ping", "-c", str(count), "-i", "0.05", "-W", "1",
                 "10.99.0.2")
    for line in out.splitlines():
        if "min/avg/max" in line:
            stats = line.split("=")[1].strip().split()[0]
            lo, avg, hi, _ = stats.split("/")
            return float(lo), float(avg), float(hi)
    return None


def main():
    holder = setup()
    print("qdisc,requested_mbps,actual_mbps,min_ms,avg_ms,max_ms,note",
          flush=True)
    try:
        for qdisc in ("pfifo", "fq_codel"):
            status = set_qdisc(qdisc)
            if status != "ok":
                print(f"{qdisc},-,-,-,-,-,{status}", flush=True)
                continue
            for load in (0, 10, 20, 30):
                gen = None
                if load > 0:
                    gen = subprocess.Popen(
                        ["nsenter", "-n", "-t", str(PEER), "python3",
                         "/tmp/cont-loadgen.py", str(load), "6"],
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                        text=True)
                    time.sleep(1.5)  # let the queue fill
                r = ping_rtt()
                actual = 0.0
                if gen:
                    try:
                        out, _ = gen.communicate(timeout=10)
                    except subprocess.TimeoutExpired:
                        gen.kill()
                        out, _ = gen.communicate()
                    m = re.search(r"actual_mbps=([\d.]+)", out or "")
                    if m:
                        actual = float(m.group(1))
                if r is None:
                    print(f"{qdisc},{load},{actual:.2f},-,-,-,PING-FAIL",
                          flush=True)
                else:
                    print(f"{qdisc},{load},{actual:.2f},{r[0]:.3f},"
                          f"{r[1]:.3f},{r[2]:.3f},ok", flush=True)
                time.sleep(0.3)
    finally:
        holder.terminate()


if __name__ == "__main__":
    sys.exit(main())
