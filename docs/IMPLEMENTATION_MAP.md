# Implementation map

This file connects the specification to concrete source modules. It is a build handoff, not an implementation claim. The main path is **Meta controller + Meta task workload, implemented in Goose**, with native C++ adapters as required. The whole-program C++ fallback keeps the same external contracts and acceptance criteria.

## Source ownership and first completion criterion

| Source | Present now | Implement next | Evidence required before calling it complete |
| --- | --- | --- | --- |
| `src/contracts.goose` | Typed internal records and enums | Version dispatch and remaining cross-field runtime checks | Valid/invalid schema fixtures map correctly; absence is distinct from a measured zero |
| `src/meta_provider.goose` | Request/continuation builders, typed response parsing, curl-child HTTPS adapter, call correlation | Live round trip, bounded retry/cancellation polish | Real configured model responds; request identity and actual model ID recorded; tool output returns to its originating `call_id`; no synthetic response substituted |
| `src/controller.goose` | `controller_tick`, `list_profiles`, phase enum | Meta controller loop and bounded tool dispatch | A real Meta tool call selects a listed profile; its actual admitted result is returned for verification |
| `src/telemetry.goose` | Sim-backed `read_observation` and explicit missing-result record | Live timestamped path, gateway and application measurements | Controlled load appears in the correct path; missing samples remain unknown; route changes invalidate baselines |
| `src/guardian.goose` | Fail-closed `admit_action` (sim scope) | Deterministic authorization, evidence, revision and lease checks against live state | Stale, out-of-scope, duplicate/conflicting and excessive requests are rejected before mutation |
| `src/actuator.goose` | Sim-backed `apply_profile`, `restore_profile`, `read_action_result`, watchdog contract; WebApi transport behind the same signatures | SSH/tc backends, out-of-process watchdog | Apply, readback, explicit restore and crash/expiry restoration observed on the dedicated lab path |
| `src/task_runner.goose` | Meta task/validator/checkpoint signatures plus workload-result validation | Real Meta workload plus independent acceptance of its output | Meaningful model output passes a pinned validator; invalid or missing evidence cannot advance progress |
| `src/events.goose` | Event record and `append_event` with file sink | Redacted view feed | Model-call provenance, admitted action, queue readback, observed recovery and validation appear as distinct events |
| `src/transport.goose` | Optional exact-object transfer contract | Owned-link reliable baseline, then bounded RaptorQ experiment | Exact authenticated object accepted before deadline under a matched wire budget; no unsupported claims about Meta's HTTPS leg |
| `native/continuum_native.h` | C ABI with router and Meta backends | SSH/tc and object-transfer adapters | ABI layout, lifetime, cancellation and error mapping proven on target platform |
| `native/continuum_native_stub.cpp` | Explicit `CT_NOT_IMPLEMENTED` functions | Replace one adapter at a time after its gate | Adapter-specific integration tests; stubs cannot silently return success |
| `native/fallback_main.cpp` | C++ status entrypoint | C++ host only if Goose integration gate requires it | Same model/tool contracts and workload acceptance criteria as Goose |

## Core tool dispatch

The external tool definitions live in `schemas/meta-tools.json`. Their implementation mapping is:

| Tool presented to the Meta controller | Goose boundary | Authority |
| --- | --- | --- |
| `read_observation` | `telemetry.goose::read_observation` | Read-only scoped measurements |
| `read_task_context` | `task_runner.goose::read_task_context` | Read-only deadline, work and validation requirements |
| `list_profiles` | `controller.goose::list_profiles` | Read-only server-owned allowlist |
| `apply_profile` | `guardian.goose::admit_action`, then `actuator.goose::apply_profile` | Bounded owned-profile mutation after admission |
| `read_action_result` | `actuator.goose::read_action_result` | Read actual action state and verification evidence |
| `restore_profile` | `guardian.goose::admit_action`, then `actuator.goose::restore_profile` | Restore the matching owned lease/revision |

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
- Session timestamps are monotonic milliseconds, not portable wall-clock checkpoints. Durable recovery needs a separate restart/epoch design.

## Source TODO labels

These labels group source work; use `BUILD_PLAN.md` for implementation ordering and milestones.

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

The build surface exposes type/syntax checks, the status ledger, deterministic sim/daemon transcripts, contract suites, native syntax checks, and two manual probes:

```sh
make check GOOSE=/absolute/path/to/goose
make status GOOSE=/absolute/path/to/goose
make test GOOSE=/absolute/path/to/goose
make sim daemon GOOSE=/absolute/path/to/goose
make native-check
make cpp-status
make web-e2e-run   # needs lab/router_server.py + ROUTER_PASSWORD
make meta-live     # needs MODEL_API_KEY for the live leg
```

`make status` builds a small Goose executable reporting each module's implementation state. `make cpp-status` does the same for the optional C++ fallback. The sim, daemon and contract suites touch no network. The two manual probes are the only lanes that leave the machine, and each states its requirements up front.
