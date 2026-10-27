# Verification handoff

This package contains the implementation plus a sim test environment, so its executable tests prove sim behavior only, never live behavior. `make check` and `make status` verify source structure; `make test` runs the Goose suites (`tests/sim_loop.goose`: the phase-1 loop; `tests/foundation.goose`: scenarios, daemon, crash recovery, router-profile contract; `tests/toolbind.goose`: tool binding, workload validation, Meta request/response shape; `tests/metamorphic.goose`: restore/state properties); `make sim` and `make daemon` print the deterministic transcripts. Manual probes needing the outside world stay out of `make test`: `make web-e2e-run` (virtual router over HTTP) and `make meta-live` (one bounded Meta call, or a no-key fail-closed check).

Add executable behavior tests as each corresponding module is implemented. The substantive acceptance checks are:

| Area | Required behavior to exercise |
| --- | --- |
| Meta adapter | Actual configured model; correct function-call/output correlation; mixed text/tool items; malformed/oversized output; timeout, 401/429/5xx, cancellation and bounded retries |
| Meta controller | Real model chooses from listed tools; no hard-coded fixture substituted for a live decision; no action during provider outage unless an existing lease must be safely restored |
| Schema binding | Reject wrong schema/version, unknown tool, oversized IDs/payloads, invalid numbers, missing evidence and cross-run references |
| Telemetry | Stale/future/unknown samples; route changes; missing probes; service delay versus path delay; independent windows |
| Admission | Wrong scope, expired evidence, revision conflict, duplicate/conflicting request IDs, out-of-bounds lease, unlisted profile, unsafe repeat mutation |
| Actuator/watchdog | Real apply/readback/restore on the owned lab path; process kill, lease expiry, lost acknowledgement, state conflict and restart reconciliation |
| Task outcome | A meaningful Meta result with required evidence passes; unsupported claims, wrong input revisions, missing facts and duplicate effects fail |
| Events | Ordered resumable sequence; explicit source provenance; no credential leakage; model request and actual effect have separate records |
| Optional object transfer | Authenticated exact metadata, matching content hash, insufficient symbols, deadline expiry, repair/wire budgets, malformed objects, bounded memory/CPU |

Use the same workload, model configuration, validator and network trace for comparison runs. Test wrong diagnoses and no-op cases, not only a successful queue repair. Preserve raw timings and failures. A useful task result and a reduced RTT are separate claims and require separate evidence.
