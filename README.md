# Continuum

A Meta-directed network controller. An agent does useful work through a
network it shares with bulk traffic; a Meta controller sees both the task
and the path, takes bounded reversible action through a deterministic
guardian, checks whether it helped, and restores its owned configuration.
Goose is the primary implementation language; C++ supplies the native
transport boundaries and the fallback path.

Built for the Meta Global AI Developer Hackathon (indie track,
Push-the-Frontier): the claim under test is whether a model that sees
task needs *and* path evidence makes better bounded choices than
competent conventional control - measured, not asserted.

## Current status

Working today:

- Deterministic sim loop and daemon (no network, no model calls).
- Typed tool-call binding, workload-result validation and Meta
  request/continuation builders with failure-first suites.
- Goose-to-C++ virtual-router loop against a lab double
  (`make web-e2e-run` -> `WEB_E2E_ALL_GREEN`).
- Meta HTTPS transport (`native/meta_web.cpp`): one bounded Responses
  call per submit via the system TLS stack; fail-closed without a key
  (`make meta-live`).

Not yet done: the first live Meta round trip (needs `MODEL_API_KEY`
and event eligibility), the controller tick, workload integration and
the first full loop. `docs/STATUS.md` is the honest ledger;
`docs/BUILD_PLAN.md` orders the remaining tickets.

Every claim in this repository is scoped to the evidence behind it -
see "Claim discipline" below.

## Quickstart

Fetch the pinned Goose v2026.3 compiler for your platform
(assets and hashes in `TOOLCHAIN.lock.json`), then from the repo root:

```sh
export GOOSE=/absolute/path/to/goose
make check status sim daemon test native-check
```

What that proves: the sources typecheck, the status ledger builds, the
sim and daemon transcripts are deterministic, the four contract suites
pass, and the C++ sources compile clean. None of it touches a network.

Two manual probes need the outside world and stay out of `make test`:

```sh
# Virtual router over HTTP (lab double + password in the environment)
ROUTER_HOST=<lab> ROUTER_PORT=18081 ROUTER_PASSWORD='<pw>' make web-e2e-run

# One bounded Meta round trip, or a fail-closed check with no key
MODEL_API_KEY='<key>' META_CONTROLLER_MODEL='muse-wonder-1.0' make meta-live
```

The Meta probe reads the key from the environment at submit time, never
logs it, and refuses to run without one.

## Repository layout

| Location | Contents |
| --- | --- |
| `docs/SPECIFICATION.md` | Product thesis, architecture, lifecycle, ownership, evaluation. |
| `docs/MODEL_INTEGRATION.md` | Meta roles, Responses protocol usage, tool loop, budgets, failure policy. |
| `docs/BUILD_PLAN.md` | Ordered tickets (C01-C18) and exit gates. |
| `docs/DEMO_RUNBOOK.md` | Three-minute stage sequence and required live proof. |
| `docs/EVALUATION.md`, `PITCH.md` | Comparisons, metrics proposal, positioning. |
| `prompts/`, `schemas/`, `config/`, `fixtures/` | Controller/workload prompts, wire contracts, example configs, synthetic fixtures. |
| `src/` | Goose implementation: sim, guardian, actuator, tool binding, Meta provider. |
| `src/main.build`, `tests/*.build` | Toolchain sidecars linking the native sources into each binary. |
| `native/` | C ABI (`continuum_native.h`), router HTTP backend, Meta HTTPS adapter, C++ fallback stubs. |
| `lab/` | Virtual-router double, contract checker, load generators, measured curves in `lab/results/`. |
| `tests/` | Contract suites plus the two manual probes. |
| `verification/` | Dated gate log and artifact summary. |
| `tools/render_spec.py` | Optional PDF publishing utility (documentation tooling only). |

## Claim discipline

- Synthetic fixtures are designed inputs. No live Meta response or
  measured Internet result is bundled anywhere.
- A model tool call is not proof of success: admission, readback and
  verification receipts are separate records, and the demo shows all of
  them.
- Comparisons name their baselines, sample counts and configurations,
  or they are not made.
- Anything that has not passed its gate is described in future tense.

## License

MIT - see `LICENSE`.
