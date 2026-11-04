# Lab

How Continuum was tested before the hackathon demo. Lab code is not published;
this file is the public record of what the lab is, what ran on it, and what
was proven vs. controlled.

## What the lab is

- **Loopback doubles**: `tests/router_double.cpp` (C++ HTTP router/QoS + ASUS
  QIS wizard fixture), `tests/host_fake.cpp` (process-disjoint transition
  fabric, atomic persistence, macOS host collisions). No external network.
- **Authored transports**: recorded/fixture Meta transports replay real
  receipts through the shipped request/continuation builders; they are not
  live provider calls.
- **PTY acceptance**: `tests/setup_tui.py` drives the real `.build/continuum`
  binary's TUI in an isolated home (tmp `XDG_CONFIG_HOME`), with a synthetic
  env key. No Keychain writes in tests.

## Tested on

- Apple M5 Max, 18 cores, 48 GiB, macOS 26.6.2 / Darwin 25.6.0 (local).
- Pinned Goose v2026.3 (`4d3da949e563`), Goose `-O2`, Apple clang 21.
- Everything under `make check test …` in README was run with `HOST_LAB`,
  `LEAP_EXECUTE`, `MODEL_API_KEY`, `META_API_KEY` unset.

## What this proves

- Discovery reads live host route/interface state; setup, owner dialogue and
  resident incidents share one selected-device capability dispatcher.
- Owner policy, protected clients/services, lab/load/effects admission,
  restore refusal, secure app-identity enforcement, and resident handoff.
- The ASUS commission channel applies a bounded CAKE/fq_codel profile with
  generated `tc` programs, reads the root qdisc and rate back from the device,
  restores the kernel-default qdisc, and refuses honestly when `tc` is absent,
  the root is vendor-managed, the profile is out of bounds, or the device does
  not honor the requested rate. `make device-check` drives these cases through
  the same SSH/generated-program path the physical adapter uses, against a
  modeled firmware shell.
- The TUI renders the real state at 80x24 and wider, restores the terminal on
  exit, and keeps secrets out of model context.

## Physical lab run (owner-gated, not yet executed)

Prerequisites: the GT-AX11000 is factory-reset, the Mac is on its LAN, and the
admin password is available. The commissioning form enables `sshd` itself; do
not toggle it by hand. The measurement target must be reachable **through the
WAN** (a host on the Internet or another machine over the Internet), because a
LAN-only target never crosses the qdisc under test.

1. Commission: `continuum` opens the TUI; `m` enters the Meta key for the
   session, `v` verifies it, `d` discovers, `p` selects, `f` grants
   `runtime`/`verify` first, `e` runs the commissioning dialogue. Commissioning
   must not reboot the unit.
2. Preflight (read-only): `continuum --device-step qos-status`.
   `qdisc_tool_unavailable` means this unit has no `tc` and the demo stops
   here; `qdisc_root_already_managed` means vendor QoS owns the root and the
   tool will not stomp it.
3. Baseline evidence: `continuum --measure <far-host>:<port>/ping /bulk`
   (>= 20 samples, clean verdict).
4. Apply: `continuum --device-qos '{"bandwidth_kbps":N,"interface":"eth0","mode":"cake","overhead_bytes":0}' --execute`
   for a controlled A/B, or `continuum --talk "<owner request>"` to let Meta
   choose and apply under owner policy. The receipt must show `qos_applied`
   with `rate_readback:"verified"`.
5. After evidence: repeat the same `--measure` command.
6. Undo: `continuum --device-qos-restore --execute` (or Meta's
   `restore_qos`), then `--measure` once more to prove the path returned.

Abort criteria: any apply receipt without `qos_verified:true`, any restore that
cannot read the kernel-default root, or a measurement whose verdict is not
`claimable`. Record every receipt and artifact path; a demo without them is a
narrative, not a result.

## What this does not prove

- No live Meta call, no real-router mutation, no Internet performance.
- No `tc`/CAKE run on the physical GT-AX11000 yet, so no latency, goodput or
  bufferbloat number is claimed.
- Controlled doubles are not live Meta or physical-router proof. Session-local
  performance numbers in `benchmarks/` (gitignored) are not a claim.
