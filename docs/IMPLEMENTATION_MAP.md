# Implementation map

This file connects the specification to concrete source modules. It is a build handoff, not an implementation claim. The main path is **Meta controller + Meta task workload, implemented in Goose**, with native C++ adapters as required. The whole-program C++ fallback keeps the same external contracts and acceptance criteria.

## Source ownership and first completion criterion

| Source | Present now | Implement next | Evidence required before calling it complete |
| --- | --- | --- | --- |
| `src/contracts.goose` | Typed internal records and enums | Version dispatch and remaining cross-field runtime checks | Valid/invalid schema fixtures map correctly; absence is distinct from a measured zero |
| `src/meta_provider.goose` | Request/continuation builders, typed response parsing, curl-child HTTPS adapter, call correlation | Live round trip, bounded retry/cancellation polish | Real configured model responds; request identity and actual model ID recorded; tool output returns to its originating `call_id`; no synthetic response substituted |
| `src/controller.goose`, `src/control_session.goose` | One selected simulator/loopback HTTP backend, controller receipt replay, protected Meta task, exact-baseline exit restoration and JSON run record | Keyed run, live telemetry and independent HTTP watchdog before physical actuation | Recorded success, malformed task output and provider failure preserve the exact baseline; a live call is not a scripted profile |
| `src/telemetry.goose` | Sim-backed `read_observation` and explicit missing-result record | Live timestamped path, gateway and application measurements | Controlled load appears in the correct path; missing samples remain unknown; route changes invalidate baselines |
| `src/guardian.goose` | Fail-closed `admit_action` (sim scope) | Deterministic authorization, evidence, revision and lease checks against live state | Stale, out-of-scope, duplicate/conflicting and excessive requests are rejected before mutation |
| `src/actuator.goose` | Sim-backed `apply_profile`, `restore_profile`, `read_action_result`, watchdog contract; WebApi transport behind the same signatures | SSH/tc backends, out-of-process watchdog | Apply, readback, explicit restore and crash/expiry restoration observed on the dedicated lab path |
| `src/task_runner.goose`, `src/continuity.goose`, `native/continuity.cpp` | Evidence-backed Meta audit with separate context/tools, seeded-finding validation, private immutable output commit after cleanup, and exact-input cross-process revalidation | Keyed execution, unfinished-step recovery with effect reconciliation, and additional workloads | Invalid/stale output cannot commit or resume; a recovered completed result needs no provider call and replays no intervention |
| `src/events.goose` | Event record and `append_event` with file sink | Redacted view feed | Model-call provenance, admitted action, queue readback, observed recovery and validation appear as distinct events |
| `src/transport.goose` | Optional exact-object transfer contract | Owned-link reliable baseline, then bounded RaptorQ experiment | Exact authenticated object accepted before deadline under a matched wire budget; no unsupported claims about Meta's HTTPS leg |
| `src/onboarding.goose` | Control-channel planner: discovered paths to strategy (`SurvivingPath` / staged `SameLinkLeap` / `NoPath`), staged-credential admissibility, post-leap outcome classification | OS path discovery and rejoin execution behind the native boundary; live Class B prototype | Scenario catalogue green in `tests/foundation.goose`; live leap rejoins and verifies, or the miss is recorded |
| `native/continuum_native.h` | C ABI with router and Meta backends | SSH/tc and object-transfer adapters | ABI layout, lifetime, cancellation and error mapping proven on target platform |
| `native/continuum_native_stub.cpp` | Explicit `CT_NOT_IMPLEMENTED` functions | Replace one adapter at a time after its gate | Adapter-specific integration tests; stubs cannot silently return success |
| `native/fallback_main.cpp` | C++ status entrypoint | C++ host only if Goose integration gate requires it | Same model/tool contracts and workload acceptance criteria as Goose |

## Owner-directed device infrastructure

`src/setup.goose` owns the TUI composition: five numbered sections (Overview,
Network, Device, Programs, Resident) plus a pinned strip (watching + age,
selected device, permitted operations, resident phase/pid) and a Result
screen. `setup_resident_status()` is the single parser for
`service/status.json` behind both the strip and the Resident section; the
Programs section drives read/disable/enable/reconcile through the same guarded
registry tools as the CLI and the resident. `native/terminal.cpp` owns the
renderer: pinned header/footer, word-aware wrapping, CSI parsing so arrow and
PgUp/PgDn keys never act as section digits, masked/secret input, and child-job
cancellation.

`src/device_agent.goose` owns one selected-device model conversation and
`device_dispatch`, used by both setup/owner dialogue and `src/service.goose`.
`src/device.goose` owns the binding, standing permission, bounded architecture
note and previous exchange. `schemas/device-tools.json` defines the separate
physical-device capability surface; `prompts/device.md` and on-demand
`prompts/workflows/` describe how Meta should use it, not fixed commissioning
policy. Native primitives in `native/asus_commission.h` and
`native/commission_ssh.cpp` retain identity, backup, readback and rollback guards.

`manage_device` supports workflow reading, inspect/enroll, runtime profiling,
model-selected optional-service changes, restore/verify and non-secret memory.
A model reboot request returns an approval-required receipt even after setup
permission. The owner's separate TUI/CLI reboot operation supplies explicit
native consent. Reset/firmware replacement and arbitrary script/HTTP execution
are not exposed. General program deployment, reboot scheduling and a prescribed
redundancy design are not implemented here.

## Core tool dispatch

The external tool definitions live in `schemas/meta-tools.json`. Their implementation mapping is:

| Tool presented to the Meta controller | Goose boundary | Authority |
| --- | --- | --- |
| `read_observation` | `telemetry.goose::read_observation` | Read-only scoped measurements |
| `read_task_context` | `task_runner.goose::read_task_context` | Read-only deadline, work and validation requirements |
| `list_profiles` | `controller.goose::list_profiles` | Read-only server-owned allowlist |
| `apply_profile` | `dispatch_controller_tool` → guardian → selected sim actuator or `control_session.goose::dispatch_web_apply` | Bounded owned-profile mutation after admission |
| `read_action_result` | Selected sim receipt or `control_session.goose::dispatch_web_result` | Read actual action state and verification evidence |
| `restore_profile` | Guardian → selected sim restore or `control_session.goose::dispatch_web_restore` | Restore the matching owned lease/revision |

The model determines whether to request an action. The guardian decides whether the request is admissible. The actuator performs an admitted change and reports actual state. The independent watchdog restores expired owned state even if the controller or provider is unavailable. These responsibilities must remain distinct as implementation fills in behind them.

## Draft record mapping

The Goose structs deliberately represent **internal** records, not wire serializers. The JSON schemas and tool definitions specify external payloads. The JSON-to-Goose adapter (`src/tooljson.goose`, `src/meta_shape.goose`) rejects malformed, overlong, unknown-version and inconsistent input before constructing an actionable internal record.

- `ActionRequest.request_id`, `scope_id`, `path_id`, `profile_id`, `observation_id`, `task_revision`, `route_epoch`, `config_revision`, `lease_ms` and `rationale` correspond to an apply request. A restore request uses `lease_id` and `expected_revision` with its observation and rationale.
- `run_id`, originating provider response/call IDs, issuance/expiry time and authorization context are bound by trusted host context. A tool argument cannot choose a different run or manufacture authority.
- `Admission.authority_token` is an unresolved design boundary, not a usable token generator. Finalize authenticated IPC and exact binding to request, lease, scope and revision before native mutation.
- External request/scope/path/task/object identifiers use the schema's 64-character limit; internal UTF-8 byte arrays impose byte limits. The eventual binding must settle Unicode handling explicitly rather than assuming character count equals byte count. Provider response IDs and opaque payloads have independent limits.
- `Observation.metrics_known=false` is explicit absence. The all-zero constructor is an unset placeholder, not a healthy observation.
- `TaskResult.independently_validated=false` and `committed=false` stay false until independent validation passes. HTTP success, generated text and a recovered object are each insufficient to commit task progress.
- Wire enum strings must be mapped explicitly. The internal `Status` enum is an internal detail and is not serialized by ordinal.
- Session timestamps are monotonic milliseconds, not portable wall-clock checkpoints. Completed-output recovery binds exact task/evidence/prompt/schema/model bytes and revalidates without replaying leases; unfinished-step or live-lease recovery still needs a restart/epoch and effect-reconciliation design.

## Source TODO labels

These labels group source work; implementation ordering and milestones are tracked separately.

| Label | Work group |
| --- | --- |
| M01 | Meta provider transport and model capability preflight |
| M02 | Meta conversation/tool orchestration |
| M03 | Live telemetry and path identity |
| M04 | Deterministic admission |
| M05 | Owned actuator, receipts and independent restoration |
| M06 | Meta task workload and independent validation |
| M07 | Trace export and stage view |
| X01 | Optional owned-link RaptorQ experiment |
| X02 | Optional durable task continuation |

Do not implement X01 before the Meta closed loop works. A codec demonstration is evidence for a transport component; it does not establish a model controller or a useful agent outcome.

## Native integration gate

The C ABI uses borrowed input spans, caller-owned output buffers and explicit status codes. Each adapter defines maximum sizes, byte encoding, asynchronous ownership, close/cancel semantics and exception boundaries before use. An insufficient output buffer must not silently truncate a model response or receipt. Native callbacks queue copied events; the owning Goose thread drains them.

The header is bound into the Goose executables through `extern` declarations and per-target sidecar files. The Meta adapter uses the system curl binary over TLS; the router adapter speaks stock HTTP. No native QUIC/codec/database library has been chosen yet. C++ fallback is permitted for a failed integration gate, not an automatic reason to replace Goose everywhere.

## Build surface

The build surface exposes type/syntax checks, the status ledger, deterministic sim/daemon transcripts, contract suites, native syntax checks, self-contained end-to-end lanes against the C++ virtual router (`tests/router_double.cpp`), and two manual probes:

```sh
make check GOOSE=/absolute/path/to/goose
make status GOOSE=/absolute/path/to/goose
make test GOOSE=/absolute/path/to/goose
make sim daemon GOOSE=/absolute/path/to/goose
make native-check
make cpp-status
make transport-check web-e2e-run asus-check leap-e2e   # C++ double, self-contained
make meta-live     # needs MODEL_API_KEY for the live leg
make leap          # real hardware ceremony; dry unless LEAP_EXECUTE=1
```

`make status` builds a small Goose executable reporting each module's implementation state. `make cpp-status` does the same for the optional C++ fallback. The sim, daemon and contract suites touch no network; the double lanes touch only localhost. The two manual probes (`meta-live`, `leap`) are the only lanes that leave the machine, and each states its requirements up front.
