# Continuum

A Meta-directed network controller. An agent does useful work through a
network it shares with bulk traffic; a Meta controller sees both the task
and the path, takes bounded reversible action through a deterministic
guardian, checks whether it helped, and restores its owned configuration.
Goose is the primary implementation language; C++ supplies the native
transport boundaries and the fallback path.

The intended product is unattended after one-time setup: understand task needs
and network conditions, diagnose problems, admit only authorized reversible
changes, verify their effect and restore when they do not help. Its resident
service must remain useful without busy waiting or unbounded retained work;
only Meta models provide AI reasoning, and normal healthy monitoring spends
no model calls. Router-side or an always-on LAN deployment is the target, not
something the owner must repeatedly open and prompt.

Built for the Meta Global AI Developer Hackathon (indie track,
Push-the-Frontier): the claim under test is whether a model that sees
task needs *and* path evidence makes better bounded choices than
competent conventional control - measured, not asserted.

## Current status

Working today:

- Interactive Goose/C++ TUI for masked Meta key entry, optional macOS Keychain
  storage, model/budget settings, host discovery and bounded Meta investigation
  (`make tui`). No management IP is required to start; candidate identity stays
  unverified until evidence supports it.
- Live resident host monitor (`--serve`), independent of the setup UI: bounded
  IPv4 route/interface observations, blocking waits, private replaceable status,
  duplicate-owner exclusion and opt-in Meta incident handling. Setup, owner
  dialogue and incidents share one selected-device capability dispatcher;
  standing permission allows only the operations the owner has granted; reboots
  need separate explicit or standing owner approval.
  Service call reservations and cooldown survive ordinary process restarts.
- Deterministic sim loop and daemon (no network, no model calls).
- Typed tool-call binding, workload-result validation and Meta
  request/continuation builders with failure-first suites.
- Goose-to-C++ virtual-router loop against a lab double
  (`make web-e2e-run` -> `WEB_E2E_ALL_GREEN`).
- Meta HTTPS transport (`native/meta_web.cpp`): one bounded Responses
  call per submit via the system TLS stack; fail-closed without a key
  (`make meta-live`).
- One supervised runtime: controller-selected action against the chosen
  simulator or loopback HTTP backend, Meta audit workload with separate
  tools/context, independent seeded-evidence validation, and exit restoration
  (`make loop`, or `make loop-router` against the C++ double).
- Completed-work continuity: the CLI durably commits an accepted audit only
  after session cleanup; `--resume <run-id>` independently revalidates that
  artifact against exact current inputs without Meta or router actions. This
  is completed-output recovery, not continuation of unfinished inference.
- Owner-selected device lifecycle in the main CLI/TUI: persist one observed
  candidate and verify its protected device/firmware identity. Meta directs setup
  and supported reversible commissioning through `manage_device`; it chooses
  which optional services to change rather than inheriting a fixed cleanup.
  Device reboots require separate owner authority at the guarded boundary.
  Owner dialogue (`--talk`, TUI **t**), bounded device knowledge and workflow
  skills are shared with resident incidents; no fixed reboot schedule or
  redundancy topology is built in.
- ASUS-only commissioning after enrollment: private backup, bounded full-process
  inventory, allowlisted sharing-service cleanup and device-local rollback.
  The dedicated GT-AX11000 retained its lean settings across a real reboot;
  `verify` requires a changed boot and protected settings/runtime readback.
  Commissioning remains incomplete until the remaining network gates pass.
- Owner-configurable execution, allowed operations, protected clients/services,
  program limits and retention, shared by setup, conversation and the resident.
  Meta can install and run bounded authored local logic, not just compose fixed
  operations. Its output is an intent submitted through the same permission
  boundary; isolated code never receives router credentials or direct control.

Not yet verified: a keyed controller/workload run (needs `MODEL_API_KEY`).
Live optimization telemetry, general controller crash recovery, arbitrary
router-resident program deployment and the comparison against a rule remain
unimplemented. Local authored programs are implemented; live Meta authoring is
not yet qualified. The ASUS commissioning rollback is not a general controller
watchdog. Setup discovery reads live host interfaces/routes; optimization
observations are still synthetic, and supervised HTTP targets are restricted
to loopback until live collection and crash recovery exist. `docs/STATUS.md`
records the boundaries; the deterministic six-tool test is not a Meta run.

Every claim in this repository is scoped to the evidence behind it -
see "Claim discipline" below.

## Quickstart

### Install a release

macOS arm64 archives are published under
[Releases](https://github.com/AdityaVG13/Continuum/releases). The binary opens
`docs/prompts`, `schemas` and `fixtures/corpus` by relative path, so unpack it
and run `bin/continuum` from the unpacked root, or install it under
`~/.local/share/continuum` with a launcher on `PATH` as the archive's
`INSTALL.txt` describes. Confirm the build with `continuum --version`.

### Interactive setup

From the checkout root, run `make tui GOOSE=/absolute/path/to/goose`.
Once built, `.build/continuum` opens the same TUI without a rebuild.

The TUI is organized into five sections — `[1]` Overview, `[2]` Network,
`[3]` Device, `[4]` Programs, `[5]` Resident — plus `?` help. A pinned strip on
every screen answers: what is watched (with observation age, e.g. `just now`),
which device is selected, what Meta may do under the current permissions, and
whether the resident is running. Job results render on their own Result screen.
`j/k`/arrow keys scroll, `J/K` and `PgUp/PgDn` page; `q` cancels a running job
and quits. While busy, only `q` works and the footer says so.

First run advances in three steps: discover this host's network, select the
device you own, then set permissions and start the resident monitor. No Meta
key is needed to discover, select, or set permissions.

- **m**: enter `MODEL_API_KEY` privately, with masked input. Keep it for the
  session or explicitly save it in macOS Keychain; it never enters the model
  context, settings file or transcript.
- **c**: set controller/workload models, output-token cap, call limit and timeout.
  Only non-secret settings are persisted under `$XDG_CONFIG_HOME/continuum`
  (or `~/.config/continuum`).
- **v**: confirm one bounded Meta connection test. A staged key is not shown
  as verified until that test succeeds.
- **d** (Network): read this host's interfaces, connection kinds, route gateways and
  neighbor-cache candidates, with the observation age shown in the strip. No key,
  address lookup or active scan is needed.
- **a**: confirm a bounded Meta investigation using those observations and
  read-only discovery tools. Candidate page titles are untrusted clues, not
  authenticated device identity or permission to modify a router.
- **p** (Network/Device): choose a device from the observed candidates. Selection alone grants
  no write permission. New enrollment gets separate credential references; the
  existing-credential option uses the address-scoped references, not arbitrary
  credentials from a previous standalone run.
- **o** (Device screen) / **i** (Device): show saved lifecycle gates ([OK]/[ ] checklist) / perform a protected inspection.
  **u** separately authorizes access to an existing protected credential; ordinary
  inspection and resident monitoring refuse unavailable access without an OS dialog.
- **e** (Device): grant standing permission for Meta-directed setup and supported
  reversible operations on the selected device, within your owner policy. Use
  **f** to choose allowed operations and constraints; Meta cannot change that
  policy through conversation. The default does **not** approve a device
  reboot. Uncertain effects are not blindly repeated. **r** confirms restoration
  of the owned baseline, not a factory reset. **b** separately confirms one
  baseline-related device reboot; it is never scheduled or implied by setup.
- **f**: set execution host, local-program opt-in, device operations, protected
  users/devices and services, program slots, retention and execution timeout.
  The launching computer is the execution default, not a remote shell endpoint.
- **g** / **4** (Programs): inspect installed programs and their execution/reconciliation state
  locally, without a key or model call. `[Enter]` reads a program by id,
  `[x]` disables, `[E]` enables, `[R]` reconciles — through the same guarded
  registry tools the CLI (`--program-*`) and the resident use.
- **t**: talk to Meta about this host or selected device, requirements and priorities.
  Up to one bounded exchange and a concise model-maintained device note survive
  between requests. Do not enter passwords here; credential access remains private.
  From the CLI: `.build/continuum --talk 'Keep FTP enabled. What changed?'`.
- **s** (Resident): set monitoring interval, incident cooldown, service call cap and
  one-time permission for automatic Meta incident handling, then confirm
  background startup. This does not itself grant device-write permission;
  incidents use the same standing device grant and guards as foreground setup. The monitor continues after this UI closes. Existing
  monitors are not reconfigured; reboot autostart is not installed.
  Resident shows live phase/pid/samples/calls read back from
  `service/status.json`, not a stub.
- **l**: run the existing supervised controller/workload lab path, isolated from
  physical targets. **q** or **Ctrl-C** cancels the current UI job and exits,
  without stopping a separately started background monitor.

The model instructions are in `prompts/device.md`; on-demand commissioning,
optimization and reusable-program skills are in `prompts/workflows/`. Basic
profiling and transaction scripts live behind the native capabilities, not a
second orchestration engine. Programs can compose those operations or contain
bounded model-authored POSIX shell logic in the local OS sandbox. This is not
unrestricted shell/HTTP execution or installation on an arbitrary remote host.

### Owner control and bounded maintenance

Choose the private state location with an absolute `CONTINUUM_HOME`; otherwise
the usual XDG configuration location is used. Execution currently supports this
computer (`local`) or `disabled`, not remote deployment. Existing supported
device operations still run against the explicitly selected, identity-bound
device. Secure credential storage remains managed by the OS adapter.

`--owner-policy` reads the complete policy; `--owner-policy-set '<JSON>'` replaces
it after validation. Setup **f** is the interactive editor. Allowed operations
and protected services narrow the separate device grant, and are rechecked
before effects. A protected-client requirement refuses affected operations
because the current adapter cannot prove that named clients stay connected;
it is not a connectivity guarantee. Meta may read the policy, never widen it.

`--program-install '<JSON>'`, `--program-list`, `--program-read <id>`,
`--program-run <id>`, `--program-disable <id>`, `--program-enable <id>`,
`--program-reconcile <id>` and `--program-prune` use the same local registry as
Meta and the resident. The exact program format is in
`prompts/workflows/programs.md`. Local code is opt-in and receives a bounded
JSON observation, not inherited keys or unrestricted filesystem/network access.
macOS uses Seatbelt; Linux requires working bubblewrap namespaces and otherwise
refuses execution. Returned actions still need ordinary guardian approval.

Source and the latest result share one bounded private registry. Owner-selected
slots and retention prevent script-file/per-run-log accumulation. Expiry compacts
only inactive, resolved records; active schedules and uncertain/failed work are
retained for reconciliation. Recurring native inventories and event receipts
replace bounded latest observations, while recovery baselines stay immutable.
No existing backup files are automatically deleted. Healthy recurring work
does not call Meta; incidents and owner conversations retain their paid-call caps.

Meta discovers technical facts rather than asking the owner to supply them.
Multiple plausible devices remain an owner-selection question, not permission
for the model to silently change the live gateway. There are no idle model
calls. The TUI is Goose with native C++ terminal/OS boundaries; Python is used
only by its PTY acceptance test. Secure persistence is currently macOS-only;
other platforms offer session-only keys. IPv6 management is not yet collected.

### Platform credential identity

Credential references and the `ct_vault_*` C ABI are platform-neutral. OS-owned
secure storage belongs in the host adapter, not Goose policy or model context.
macOS Keychain is implemented; Linux Secret Service and Windows Credential
Manager adapters are not. An unavailable secure backend must refuse persistent
storage, never substitute plaintext files or the environment-backed test vault.
Apple signing is not a dependency of non-macOS builds. This separation does
not certify a native Windows port or implement its remaining OS boundaries.

On macOS, select a real signing certificate by name or fingerprint using
`MACOS_SIGN_IDENTITY`. For persistent local configuration, put that public
selection in `.build/signing.mk` as `MACOS_SIGN_IDENTITY ?= <fingerprint>`;
`.build/` is gitignored. No personal certificate, private key or password is
committed. Run `make sign GOOSE=/absolute/path/to/goose` to build, sign and
verify both production executables without running either. Configured rebuilds
also sign automatically, using distinct stable identifiers
`org.continuum.controller` and `org.continuum.leap`. Local signatures omit the
network timestamp; this is not a notarization/distribution pipeline.

Unsigned development builds remain possible, but their linker/ad-hoc identity
changes with their contents and cannot promise retained Keychain authorization.
A first certificate-signed build may still need explicit owner authorization
for an existing item. Keep the certificate and application identifier consistent
across rebuilds; switching signer/identifier is a new authorization boundary.
Signing does not grant access to existing credentials, change their ACLs, or
weaken the background reader's fail-closed, no-dialog policy. `make signing-check`
checks the build policy without using a certificate or touching credentials;
non-macOS recipe checks are not native OS execution proof.

### Headless checks and lab commands

Fetch the pinned Goose v2026.3 compiler for your platform
(assets and hashes in `TOOLCHAIN.lock.json`), then from the repo root:

```sh
export GOOSE=/absolute/path/to/goose
make check-all                              # full local gate
make check status sim daemon test native-check   # the lanes, individually
```

`make check-all` is the full local gate: typecheck, the contract suites, the
device lifecycle against the loopback double, live measurement, and the signing
policy, ending in `CHECK_ALL_GREEN`. It needs no provider key, no hardware and no
remote worker; on an M-series laptop it takes about two minutes of wall time and
under half a minute of CPU. The wall time is device time that must actually
elapse (a trial lease that expires unaided, a post-apply settle window) and live
sampling loops, not build or analysis cost.

These targets typecheck, build the status ledger, exercise the deterministic
sim/daemon and nine contract suites, and syntax-check the C++ sources.
The request golden now describes the actual six-tool controller allowlist;
the former nine-tool mismatch is preserved in the historical status ledger.
These lanes make no provider or physical-router requests.
`make continuity-check` additionally exercises durable commit, cross-process
recovery and stale/invalid-output refusal through an authored model transport.
`make device-check` exercises selected-device setup through the main CLI,
commissioning/reboot persistence, restart handoff into the resident, actual
read-tool result continuation and physical-write/changed-identity refusal. It
uses a loopback ASUS double and authored host/Meta boundaries, not hardware or
live model inference. `make setup-check service-check` exercises the PTY setup
and real host monitor as well as the bounded incident conversation.

For headless device operation, `--device-select <candidate-id> <ssid-stem>`
requires an exact candidate from current `--discover` output. `--device-status`
reads saved gates; `--device-step inspect` refreshes protected evidence;
`--device-step authorize` is the separate owner-interaction action.
`--device-step setup --execute` approves the initial transaction, including
reboot, and returns exit 3 when that transaction reaches its still-unqualified
network gate. `--device-step restore --execute` restores the owned baseline.
These are real device operations, not lab shortcuts; do not run them on an
unapproved target. No device operation silently substitutes the default gateway.

The virtual-router lanes run against the C++ double on localhost and
are self-contained:

```sh
make transport-check web-e2e-run asus-check leap-e2e
```

Two manual probes need the outside world and stay out of `make test`:

```sh
# One bounded Meta round trip, or a fail-closed check with no key
MODEL_API_KEY='<key>' META_CONTROLLER_MODEL='muse-wonder-1.0' make meta-live

# Leap ceremony against real hardware (dry run unless LEAP_EXECUTE=1)
ROUTER_HOST=<router> SSID_STEM=<stem> make leap
```

The Meta probe reads the key from the environment at submit time, never
logs it, and refuses to run without one.

`MODEL_API_KEY` is the official Meta environment-variable name, not
`META_API_KEY` ([Meta overview](https://dev.meta.ai/docs/overview)). Set it
locally without putting the value in this repository or chat. With it set:

```sh
make loop-router GOOSE="$GOOSE"
```

This spends bounded Meta calls for the controller and audit workload and
prints one JSON run record. `META_CONTROLLER_MODEL` and `META_TASK_MODEL`
select the roles independently. The controller may abstain; a scripted
profile is never substituted. The record distinguishes synthetic observations,
recorded/live model responses, verified restoration and durable task-commit
status. The CLI publishes an immutable private artifact under
`$XDG_CONFIG_HOME/continuum/runs/<run-id>.json` (default `~/.config/continuum`).
Supply an explicit identity with `.build/continuum --loop <run-id>`; recover
completed work with `.build/continuum --resume <run-id>`, even with no key.
Recovery must use the same checkout inputs and task-model setting; it neither
replays an intervention nor retries an uncertain external effect.
`make web-e2e-run` exercises the shared runtime with explicitly authored
responses and no provider calls. `docs/STATUS.md` separates this working slice
from the larger unproven product thesis; the session continuity ledger is kept
locally (`docs/progress/`) and is not published.

## Repository layout

| Location | Contents |
| --- | --- |
| `docs/SPECIFICATION.md` | Product thesis, architecture, lifecycle, ownership modes, boundaries. |
| `docs/MODEL_INTEGRATION.md` | Meta roles, Responses protocol usage, tool loop, budgets, failure policy. |
| `docs/STATUS.md` | What is implemented, what is not, and the evidence for each. |
| `docs/DEMO_RUNBOOK.md` | Three-minute stage sequence and required live proof. |
| `docs/IMPLEMENTATION_MAP.md`, `docs/LAB.md` | Source-to-capability map; what the lab proves and does not. |
| `docs/prompts/`, `schemas/`, `config/`, `fixtures/` | Controller/workload/device/discovery prompts, wire contracts, example configs, synthetic fixtures. |
| `src/` | Goose implementation: sim, guardian, actuator, tool binding, Meta provider, onboarding planner + leap ceremony. |
| `src/main.build`, `tests/*.build` | Toolchain sidecars linking the native sources into each binary. |
| `native/` | C ABI (`continuum_native.h`), router HTTP backend, Meta HTTPS adapter, ASUS onboarding adapter, macOS keychain/Wi-Fi host backend, C++ fallback stubs. |
| `tests/` | Contract suites, the C++ virtual-router double (`router_double.cpp`), native harnesses, and the manual probes. |
| `verification/` | Dated gate log and artifact summary. |

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
