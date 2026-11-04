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
- The TUI renders the real state at 80x24 and wider, restores the terminal on
  exit, and keeps secrets out of model context.

## What this does not prove

- No live Meta call, no real-router mutation, no Internet performance.
- Controlled doubles are not live Meta or physical-router proof. Session-local
  performance numbers in `benchmarks/` (gitignored) are not a claim.
