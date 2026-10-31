# Continuum Architecture & Topology Map

## Overview
Continuum is a Meta-directed network controller built in Goose (primary) with C++ native boundaries. It observes agent workload/network conditions, lets a Meta model choose bounded interventions via tool calls, enforces admission through a deterministic guardian, applies actions through an owned actuator, verifies outcomes, and restores state. Safety paths (watchdog/lease expiry) operate independently of the model.

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
- **`src/main.goose`**: CLI entrypoint. Modes: `--status` (shows implementation ledger), `--sim` (runs `run_sim_loop()`), `--daemon` (runs deterministic policy daemon). Imports via modules.
- **`src/lib.goose`**: Library entry for tests - imports all modules in one place.
- **`src/leap_main.goose`**: Leap ceremony entrypoint (onboarding control-channel).
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
| `controller.goose` | **Sim loop plus router actuator** | `dispatch_sim_tool()`, `run_simulated_loop()`, `run_router_loop()`; `--loop` uses the router only when `ROUTER_HOST` is set, and verified requires the revision readback |
| `telemetry.goose` | Observation collection | `read_observation()` - wraps sim observations for lab-sim paths |
| `task_runner.goose` | Workload execution/validation | `read_task_context()`, `run_meta_task()`, `validate_task_result()`, `checkpoint_run()` |
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

The participant loop is the decision. `arm_case` prepares one labelled world (`queue` or `provider`) and does not choose an action. `participant_context` gives the model the observation, the task and the catalogue. A recorded reply, or a live Meta reply, is dispatched by `dispatch_sim_tool`. The guardian admits or rejects. A receipt is replayed into the next call. The loop stops on abstain, the round cap, or a transport failure. It does not substitute a profile.

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
- `make test`: runs 8 Goose suites (sim_loop, foundation, toolbind, metamorphic, golden, conformance_matrix, fuzz_tooljson, leap_logic) - all green
- `make web-e2e-run`: Goose → C++ transport → C++ router double (self-contained)
- `make meta-live`: bounded Meta HTTPS call (needs `MODEL_API_KEY`, fails closed without)
- `make leap-e2e`: headless leap ceremony vs double
- `make native-check`: syntax check C++ sources

## Current State
- Core primitives (contracts, tooljson, guardian, actuator, sim, daemon, store, events) implemented and tested
- Meta transport (provider + native adapter) implemented
- Controller sim dispatch and the router apply/restore path are connected at `--loop`. The model does not yet choose the action, and the daemon does not call this path
- **Telemetry and task runner wired** to use sim paths
- Router WebApi transport implemented with double
- Onboarding/leap ceremony implemented
- All Goose tests passing
- Live Meta integration requires credentials/account access (gated)
