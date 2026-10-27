# Owned laboratory design

**Status: lab doubles implemented; physical path pending.** `topology.example.json` is the proposed configuration for the dedicated Linux host. The Python files in this directory are disposable-lab harnesses only: they run against `127.0.0.1` or an explicitly passed lab host, and every one refuses to run outside an owned scope. No root-level networking commands are shipped in this repository.

## 1. Required layout

Use a dedicated Linux host or VM with disposable namespaces/interfaces. The agent client connects through an owned controller-visible shaping interface and a separately controlled bottleneck/emulation plane to an owned tool service or relay. A bulk sender shares the intended access bottleneck with the agent traffic. Management access and the evaluator are distinct and explicitly documented.

The bottleneck/emulation plane creates the declared network conditions. The actuator changes only the separately owned shaping profile upstream of that bottleneck. Keeping those controls separate avoids a controller "repairing" the experiment by turning off its impairment generator.

For an upload-congestion experiment, the constrained direction is client to relay/provider. Do not present that as evidence about a download bottleneck without constructing the mirrored case. Record which request, response, ACK, probe and bulk paths traverse each interface.

## 2. Traffic classes

| Class | Default route | Measurement |
| --- | --- | --- |
| Meta controller HTTPS | Across the declared impaired access path to the actual provider | Call issue, usable response, request/call IDs and provider identity |
| Meta workload HTTPS | Across the same declared path | Same plus task step and validation |
| Tool service reads | Client through bottleneck to owned service | Request/result timings and exact source identity |
| Bulk upload | Client through the shared bottleneck | Offered load and actual delivered useful bytes |
| Local gateway probe | Before the emulated remote bottleneck | Host/LAN reference, successful and attempted probes |
| Remote probe/application echo | Through the declared bottleneck | Loaded latency/loss and window metadata |
| Evaluator/management | Isolated management plane | Explicitly excluded from claimed application path |

A bypassed controller path is permissible for integration development but must be labelled and excluded from claims that the controller survived the same impaired path. The independent local watchdog never depends on the provider path.

## 3. Measurements and diagnosis

Collect monotonic local event times and wall-clock provenance separately. Prefer per-host monotonic durations; do not subtract unrelated host clocks without an explicit synchronization model. Every observation includes window bounds, creation time, route/baseline epoch, sample counts and unknown/missing fields.

Record gateway and remote probes, an owned application echo, application/model durations, load/utilization, loss and queue counters only where actually visible. An evaluator's hidden bottleneck state must not be leaked into the controller's observations. A single high ping is insufficient to identify the cause of a slow model call.

Use baseline, sustained congestion, brief load, provider-only delay, stale metrics, route change and complete outage profiles. The provider-delay case changes a controlled service's response time or uses a labelled service-delay harness; it must not pretend to control the external Meta provider's internal queue.

## 4. Profiles and ownership

CAKE supports shaping and queue management; its parameters must be calibrated for the actual controlled path and overhead assumptions. [Official tc-cake manual](https://man7.org/linux/man-pages/man8/tc-cake.8.html)

The actuator exposes fixed catalogue entries such as baseline and calibrated SQM profiles. The model selects a profile ID and bounded lease, not a shell command. The profile definition binds to one owned scope, route/config revision and allowed parameter range. The profile chosen for a sample file is illustrative until measured.

Before every mutation, check current ownership and revision. After mutation, read back actual state and issue a separate verification result. Restoration is permitted only for the still-owned state that the action changed; an unrelated administrator's later update creates a conflict to report, not a configuration to overwrite.

## 5. Reset and run boundaries

Freeze the fixture/model/profile versions and record the starting state. Start the offered load on the documented schedule, run one comparison arm, capture all events, verify final task state, restore, read back and close the run. Reset cache/session state consistently. Do not run competing arms concurrently through the same bottleneck.

The primary run is not complete until the expected owned baseline is observed again. Test restoration on normal completion, manual stop, lease expiry, controller crash and provider unavailability before the stage build is accepted.

## 6. Implemented harnesses and remaining work

`router_server.py` is the stock-like router admin double: login with the password from `ROUTER_PASSWORD` (empty refuses to start), a fixed knob set, revision tracking and scope checks. `router_contract.py` states the double's contract for the C++ transport tests. `udp_load.py` and `veth_bloat.py` generate offered load and bufferbloat inside disposable veth namespaces on the lab host. `results/` records dated runs; each file states what was actually measured and on which hosts.

Still to build: a scoped topology setup/reset tool, a run collector/exporter, the finite-profile SSH/tc actuator, and the independent watchdog process. This specification does not assume that the user has granted access to a router or the venue's network.
