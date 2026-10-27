# Continuum: implementation handoff

**Status: implementation underway.** These are the implementation tickets and acceptance gates. A stub compiling does not complete a ticket. The required product is a Meta-driven closed loop that observes a struggling agent workload, chooses a permitted network intervention, verifies the outcome, and restores its owned configuration. Current per-ticket reality is tracked in STATUS.md.

## 1. Fixed decisions

- Use aardappel/Goose first. Use C++ behind explicit native interfaces where necessary and as the fallback for an integration that cannot pass its Goose gate. No Python product runtime is assumed.
- Meta models are required for the controller and the meaningful agent workload. The primary controller selects interventions through the six documented tools. The deterministic guardian validates requests; it does not silently replace the model's decision-making.
- The first real vertical slice is **observe -> Meta tool call -> admit -> apply -> verify -> Meta restore -> verify restoration**.
- RaptorQ, durable workflow recovery, local-model handoff, multipath, and retrospective learning are extensions. Their specifications are included; they cannot displace the required live Meta loop.
- The original PDF suggests ten days. Treat the schedule below as a planning assumption until the actual event deadline, team size, allowed models, credits, and submission rules are confirmed.

## 2. Workstreams and ownership

| Workstream | Responsibility | Handoff |
| --- | --- | --- |
| Models and controller | Meta adapter, prompts, typed tool loop, controller state, useful workload | Sanitized real call trace; model-selected actions; validated task output |
| Network and native boundary | Goose/C++ integration, lab, collector, finite profiles, actuator, watchdog | Fresh observations; bounded actions; readback and restoration receipts |
| Evidence and experience | Evaluation, event log, operator view, demo, recording | Reproducible comparisons; truthful stage presentation |

These are responsibilities, not an assumed three-person team. A solo builder works through the dependency order and uses a terminal view initially. A second person can own the lab while the first brings up real model tool calls. UI polish follows the first complete loop.

## 3. Day-one decisions

Record the answers in the run/build manifest before selecting dependencies:

1. Which Meta model and endpoint can the actual account call, and are they eligible for the event? An authenticated response must include the selected model identity. Do not substitute another model provider without an explicit project decision.
2. Does the chosen Goose release compile on the target OS, and can a small native boundary exchange bounded request/result buffers? If the blocked piece needs C++, preserve the same contracts.
3. Is there an owned Linux host or VM with the required queue capabilities and administrative scope? Which exact interface or namespace is disposable?
4. Do controller API calls and workload API calls cross the impaired link? The primary integrated demo puts both through the declared path. Any bypass used during development must be labelled.
5. What is the workload, independent success validator, frozen evidence corpus, and deadline? Start with the release-readiness audit in the demo runbook.
6. What profile values are justified by calibration? Rates, lease lengths, model timeouts, evidence age, and intervention limits are configurable hypotheses until measured.

## 4. Ten-day sequence

| Relative day | Required output | Exit gate |
| --- | --- | --- |
| 1 | Goose/native build check; real Meta request and tool round trip; fixed tool schemas; owned lab preflight | Meta returns a real tool call and receives its correlated result; target build and lab access are known |
| 2 | Collector, reproducible loaded queue, calibrated static SQM, profile catalogue | Idle/load contrast and restoration repeat; actual routes are documented |
| 3 | Guarded apply/restore tool implementation, independent lease watchdog, minimal event view | Valid requests mutate only the owned profile; stale, duplicate, conflicting and out-of-scope requests behave correctly |
| 4 | First full Meta-controlled loop with verification and normal model-requested restoration | Actual model chooses an intervention and restoration; readback confirms both; no manual decision substitution |
| 5 | Meaningful Meta workload and independent result validator integrated into the same path | Task quality is checked and network/tool/model timings are separated |
| 6 | Negative controls, provider failures, interrupted controller, model-action provenance | Wrong-remedy cases abstain; independent cleanup survives controller failure |
| 7 | Matched baseline experiments and minimal presentation polish | Main claim can be assessed against static SQM and a competent deterministic controller |
| 8 | Optional extension only if the core gate is stable; freeze exact stage build | Required demo still passes; optional feature has its own evidence and can be disabled |
| 9 | Repeated rehearsal, failure drill, complete recording and evidence export | Live flow and labelled backup both fit the time limit |
| 10 | Final review, submission and cleanup rehearsal | Artifacts, provenance, presentation and restore procedure are complete |

If time is shorter, cut optional extensions and dashboard polish first. If the core loop does not pass by Day 4, use the next days to finish it; do not fill the gap with a codec demonstration or scripted model response.

## 5. Concrete tickets

Ticket IDs are planning identifiers. Each ticket is initially **not implemented**.

| ID | Deliverable | Depends on | Acceptance gate |
| --- | --- | --- | --- |
| C01 | Event, account and target-machine decision record | None | Exact Meta model is callable and eligible; target OS and owned lab scope recorded |
| C02 | Pinned Goose build and native boundary | None | Bounded buffer ownership, error return and lifetime demonstrated on target; C++ fallback boundary recorded |
| C03 | Meta adapter and one correlated tool round trip | C01, C02 | Real model call, returned tool call, tool output correlation, final continuation; no synthetic response substituted |
| C04 | Typed tool dispatcher | C03 | Only six allowlisted core tools accepted; JSON/type/size checks, unknown-tool error, duplicate-call behavior and bounded loop implemented |
| C05 | Owned lab topology and reset | C01 | All traffic routes identified; isolated load reproduces; reset returns known configuration |
| C06 | Observation collector | C02, C05 | Timing units, clock domains, route epoch, probe attempts/loss, sample windows and observation age explicit |
| C07 | Calibrated finite profile catalogue | C05, C06 | Baseline and permitted SQM profiles measured; minimum useful goodput and permitted lease bounds chosen before comparisons |
| C08 | Guardian and action admission | C04, C06, C07 | Ownership, revision, freshness, profile, lease, rate limit and duplicate checks enforced; rejection reason returned to model |
| C09 | Narrow actuator and readback | C02, C07, C08 | Apply only an owned finite profile; action receipt distinguishes accepted, applied, verified and failed states |
| C10 | Independent restoration watchdog | C09 | Expiry, normal finish, stop and controller crash handled; conflicting ownership never overwritten blindly |
| C11 | Meta controller state machine | C03, C04, C06, C08-C10 | Model observes, chooses apply, consumes result, verifies effect, and chooses restore; no hidden deterministic primary selector |
| C12 | Evidence-backed Meta workload | C03, C05 | Purposeful dependent work, pinned inputs, real semantic result, source references and independent quality validator |
| C13 | One complete required demo | C11, C12 | Congestion -> model-selected action -> measured check -> valid task result -> model-selected restore and readback |
| C14 | Structured event/evidence export | C06, C11, C12 | Every action linked to model/tool call, observation, scope revision, outcome and run; secrets excluded |
| C15 | Negative-control and failure suite | C13, C14 | Provider delay, insufficient evidence, route change, expired proposal, malicious tool text, model timeout and crash cleanup covered |
| C16 | Matched evaluations | C13-C15 | Same workload, model, profile catalogue, offered load and validator across applicable arms; failures retained |
| C17 | Stage view and recorded backup | C14, C16 | Clear live/replay labels; decision provenance, task quality, latency, goodput and restoration visible |
| C18 | Submission bundle | C17 | Build manifest, raw run data, exact configurations, report, video and remaining limits included |

The optional track begins only after C13 and C15 pass. Extension IDs are E01 content-addressed evidence, E02 durable resume, E03 local Meta execution, E04 owned RaptorQ transport, E05 task-aware transport scheduling, E06 retrospective analysis, and E07 real multipath. Their gates are in `ADVANCED_ROADMAP.md`.

The freshness, apply-budget and cooldown checks in C08 govern a new profile change. Restoration of an owned active lease remains available despite stale observations or exhausted apply budget, subject to ownership, revision and restorable-state checks. The watchdog requires no fresh cloud decision.

## 6. First implementation session

Implement C01-C04 against a mock actuator that returns explicit simulated outcomes, while C05 establishes the real lab. This is a development stage; the interface must display `SIMULATED`. The real Meta API call is still required. Next replace only the actuator/collector boundaries with real implementations, pass C08-C10, and run C11. Finally attach the meaningful workload and evaluate C13. This order makes the model integration a first-class dependency from the beginning.

The status output and contract fixtures are not the first live slice. They define the handoff so the next coding phase has exact interfaces and finish lines.

## 7. Scope control

No requirement here authorizes building an entire generalized agent platform, replacing the user's venue router, inventing a new programming language, or training a model. The upgraded ambition is to make the Meta agent's bounded action and its usefulness measurable, then expand the same contracts toward task-aware network and execution decisions.

Stop optional work once the chosen scope has passed its gates. Reopen a completed part only for a concrete failure, an essential integration dependency, or a changed requirement.
