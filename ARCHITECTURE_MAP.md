# Continuum Architecture & Topology Map

## Overview
Continuum is a Meta-directed network controller built in Goose (primary) with C++ native boundaries. It lets a Meta model choose bounded interventions through a deterministic guardian, executes a separately scoped Meta workload, validates its result, and restores state. Current observations are synthetic; supervised HTTP actuation is loopback-lab only. Model-independent expiry/recovery exists for the simulator; HTTP exit restoration is implemented, but an independent physical-router watchdog is not.

## Directory Structure
```
Continuum/
├── src/           # Goose implementation (core logic)
├── native/        # C/C++ native boundary (ABI + adapters)
├── tests/         # Contract suites, doubles, harnesses
├── docs/          # Specs, plans, status, runbooks
├── schemas/       # JSON schemas for contracts
├── prompts/       # Controller/workload prompts
├── config/        # Example configs
├── fixtures/      # Synthetic fixtures
└── Makefile       # Build/test targets
```

## Entry Points
- **`src/main.goose`**: CLI entrypoint. Modes: default/`--tui` setup, `--discover`, `--discover-model`, `--test-meta`, `--status`, `--sim`, `--daemon`, `--loop [run-id]` (supervised Meta controller + committed validated workload), `--resume <run-id>` (completed-output revalidation), and `router` (operator tuner).
- **`src/lib.goose`**: Library entry for tests - imports all modules in one place.
- **`src/setup.goose`**: TUI composition: five sections plus help, pinned status strip with observation age, Result screen, and TUI program actions. `setup_resident_status()` is the single parser for resident status.
- **`src/device_agent.goose`**: Shared Meta setup, owner dialogue and resident device capabilities; bounded knowledge and on-demand workflow skills. Device reboot consent is separate from standing service-control permission.
- **`src/leap_main.goose`**: Enrollment capability entrypoint; hands commissioning decisions back to Meta rather than running a cleanup strategy.
- **Native fallbacks**: `native/fallback_main.cpp`, `native/continuum_native_stub.cpp`

## Goose Module Dependency Graph
`main.goose` imports: contracts, meta_provider, telemetry, guardian, actuator, task_runner, events, transport, controller, policy, daemon, os

`lib.goose` imports (all modules): contracts, meta_provider, telemetry, guardian, actuator, task_runner, events, transport, controller, sim, policy, store, router, daemon, router_web, tooljson, workload, meta_shape, onboarding, leap

### Core Modules
| Module | Purpose | Key Exports |
|---|---|---|
| `contracts.goose` | Domain types/enums/structs (Status, Provenance, ToolName, ActionRequest, Observation, etc.) | All core types, `status_name()` |
| `tooljson.goose` | JSON gate for model tool calls (schema validation, fail-closed) | `validate_apply_call()`, `validate_restore_call()`, `validate_read_call()`, `validate_tool_result()`, `tool_named()`, `valid_id()` |
| `meta_shape.goose` | Meta Responses request/response shaping, parsing | `build_meta_request()`, `meta_request_body()`, `meta_parse_response()`, `meta_continuation_body()`, `find_raw_value()` |
| `meta_provider.goose` | Meta HTTPS transport integration via native ABI | `request_meta()`, `submit_tool_result()`, `meta_exchange()`, externs to `ct_meta_*` |
| `guardian.goose` | Admission control (fail-closed) | `admit_action()` - enforces ownership, scope, revision, freshness, lease bounds, rate limits, duplicate detection; restoration exempt from some gates |
| `actuator.goose` | Apply/restore/readback with watchdog | `apply_profile()`, `restore_profile()`, `read_action_result()`, `reconcile_expired_lease()`, `actuator_recover()`, uses sim/store |
| `controller.goose` | Shared controller/workload session | `run_protected_task()`, `dispatch_controller_tool()`, `session_record()`; recorded and live responses share execution/cleanup, with separate model and observation provenance |
| `control_session.goose` | Selected HTTP actuator and ownership | Loopback target selection, baseline capture, admission, apply/readback, conflict-aware exact-baseline restoration; unresolved leases prevent a new session |
| `telemetry.goose` | Observation collection | `read_observation()` - wraps sim observations for lab-sim paths |
| `task_runner.goose` | Workload execution/validation | `read_task_context()`, `run_meta_task()`, `validate_task_result()` |
| `continuity.goose` | Completed-work persistence and revalidation | `task_binding()`, `checkpoint_run()`, `resume_task()`; exact current inputs, independent validation, no replayed intervention |
| `events.goose` | Ordered journal (memory + file sink) | `append_event()`, `beat()` helper, sequence tracking |
| `policy.goose` | Deterministic policy brain for sim/daemon | `propose_apply()`, `propose_restore()`, `bloat_detected()`, `run_sim_loop()` |
| `daemon.goose` | Token-free daemon loop | `run_daemon()`, `daemon_decide()` - escalate on unknown cases |
| `sim.goose` | Deterministic simulator | Queue models (FIFO/bloat vs fair queue), observations, profiles, persistence |
| `store.goose` | Durable lease persistence | `lease_save()`, `lease_load()`, `lease_clear()` (atomic writes) |
| `router*.goose` | Router transport/shaping | Web API transport helpers |
| `workload.goose` | Workload contracts/helpers | |
| `onboarding.goose` | Control-channel planner | `plan_leap()`, `classify_leap()` |
| `leap.goose` | Leap ceremony executor | `run_leap()`, native calls to `ct_asus_*`, `ct_host_*` |

## Native C/C++ Boundary (ABI)
Defined in `native/continuum_native.h` (ABI v1). All native functions use C ABI, no exceptions cross boundary.

### Meta Transport
- `ct_meta_open(config_json, &handle)` / `ct_meta_submit(handle, request_json, &request_id)` / `ct_meta_poll(handle, result_json, &len)` / `ct_meta_cancel(handle, request_id)` / `ct_meta_close(handle)`
- Implemented in `native/meta_web.cpp`: shells system `curl` with key from env var (named in config, never logged), protected temp header files (0600), response size limits, timeout handling.

### Router/Profile
- `ct_profile_apply(admitted_request_json, receipt_json, &len)`, `ct_profile_restore(...)`, `ct_watchdog_reconcile(...)`, `ct_observation_read(...)`
- Implemented in `native/router_web.cpp`: HTTP/1.0 to router API, login with `ROUTER_PASSWORD` env var, QoS control, readback verification.

### ASUS Onboarding
- `ct_asus_discover/rotate/apply/verify(...)` in `native/asus_web.cpp`
- `ct_host_stage/rejoin/iface_ip(...)` in `native/host_macos.cpp` (macOS keychain + Wi-Fi)

### Vault
- `ct_vault_fetch/store/delete(...)` in `native/vault.cpp` (env-backed test double, keychain in prod)

### Bridges
- `native/goose_bridge.c`, `native/leap_bridge.c` - Goose/C interop

## Data Flow

### Meta Controller Loop

The mechanical six-tool walk (`run_simulated_loop`) spends no model call. It is the dispatch proof.

The participant loop is the decision. `arm_case` prepares one synthetic world (`queue` or `provider`) without selecting an action. `participant_context` gives the model the observation, task and selected backend's catalogue. `dispatch_controller_tool` routes the actual request to that backend; the guardian admits or rejects, and the execution receipt is replayed. In `run_protected_task`, a controller intervention remains active through Meta workload execution and independent seeded-evidence validation, then the host verifies restoration on success or failure. Model-requested early restoration is respected. No profile is substituted for an abstention. Task validation is not a durable commit: the CLI subsequently checks that task inputs have not changed, publishes a private immutable artifact through `native/continuity.cpp`, and revalidates its readback before acknowledging commitment. `--resume <run-id>` revalidates an already-completed result without a model call, observation collection or actuation; unfinished work is not resumed.

### Deterministic Daemon (No Model)
1. Observe via `sim_observe()`
2. Decide via `daemon_decide()` (policy table)
3. If apply: propose → admit → apply → verify
4. If restore/hold: handle based on dwell/cooldown
5. Watchdog checks `reconcile_expired_lease()` first each tick

### Sim Loop
Full cycle in `run_sim_loop()`: observe → bloat detect → propose/apply/admit → verify improvement → propose/restore/admit → verify restoration → duplicate rejection → journal ordering check

## Key Invariants (Enforced)
- Model tool call ≠ proof of applied action (separate records)
- Successful application ≠ proof of recovered performance (independent verification)
- Missing observations ≠ measurements (unknown, not zero)
- Freshness/route identity rechecked before new applies
- Restoration of owned lease exempt from apply budget/cooldown/age gates but needs ownership/revision/restorable state
- Duplicate requests rejected; restoration uses active lease identity
- Quality validation before task completion
- Synthetic vs Live provenance always labeled
- Credentials never logged/transmitted in prompts
- Guardian fail-closed; no silent fallbacks to non-Meta providers

## Testing
- `make test`: runs nine Goose suites including `sim_controller`; the request golden now matches the actual six-tool allowlist
- `make continuity-check`: cross-process artifact commit/recovery, changed-input and invalid-output refusal; authored Meta transport, no live provider
- `make web-e2e-run`: Goose → C++ transport → C++ router double (self-contained)
- `make meta-live`: bounded Meta HTTPS call (needs `MODEL_API_KEY`, fails closed without)
- `make leap-e2e`: headless leap ceremony vs double
- `make native-check`: syntax check C++ sources

## Current State
- Core primitives (contracts, tooljson, guardian, actuator, sim, daemon, store, events) implemented and tested
- Meta transport (provider + native adapter) implemented
- `--loop` shares model-selected dispatch, Meta workload execution, validation and restoration across the selected backend; keyed execution still needs verification
- Telemetry is synthetic; the task uses the supplied authored audit corpus; the daemon does not yet invoke this model/session path
- Router WebApi transport implemented with double
- Onboarding/leap ceremony implemented
- The historical request-golden mismatch is repaired; current verification and remaining boundaries are recorded in `docs/STATUS.md`
- Live Meta integration requires credentials/account access (gated)
