#!/usr/bin/env python3
"""UDP load generator. Runs INSIDE the rtr netns (via nsenter), blasting
packets at 10.99.0.1 so they queue on rtr egress. Prints bytes sent + actual
Mbps to stdout at the end (the honest offered load, not the requested one).
Usage: python3 udp_load.py <mbps> <seconds> [pkt_bytes]
"""
import socket
import sys
import time


def main():
    target_mbps = float(sys.argv[1])
    seconds = float(sys.argv[2])
    pkt = int(sys.argv[3]) if len(sys.argv) > 3 else 1200
    target_bps = target_mbps * 1e6 / 8
    interval = pkt / target_bps if target_bps > 0 else 0
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("10.99.0.2", 0))
    payload = b"x" * pkt
    sent = 0
    deadline = time.monotonic() + seconds
    nxt = time.monotonic()
    while time.monotonic() < deadline:
        try:
            sock.sendto(payload, ("10.99.0.1", 9999))
        except OSError:
            break
        sent += pkt
        nxt += interval
        now = time.monotonic()
        if nxt > now:
            time.sleep(nxt - now)
        else:
            nxt = now
    elapsed = seconds - max(0.0, deadline - time.monotonic())
    actual_mbps = sent * 8 / 1e6 / seconds
    print(f"SENT bytes={sent} actual_mbps={actual_mbps:.2f}")
    sys.stdout.flush()


if __name__ == "__main__":
    main()
