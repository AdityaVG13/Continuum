# Continuum: evaluation design

**Status: future experiment protocol. No performance gains, model decisions or live repairs are reported by this repository.**

## 1. Claims to separate

The evaluation answers three different questions:

1. Does a correctly configured network intervention reduce relevant delay on the controlled path without unacceptable goodput loss?
2. Can an actual Meta model select, verify and restore permitted interventions from fresh path and task evidence?
3. Does that model's context-sensitive selection improve the desired outcome over competent deterministic choices with the same capabilities?

A "yes" to the first two does not establish the third. Ordinary SQM may solve most of a stationary queue problem. The model contribution must be assessed separately and reported even when the comparison is neutral or worse.

## 2. Primary outcome and invariants

The primary outcome is **valid workload completion before a declared deadline**, measured over all started runs. The result must pass the same evidence and quality validator in every arm. Also show task completion-time distributions and failures/timeouts separately.

Freeze the workload, model and generation settings, evidence corpus, permissions, maximum concurrency, application retries, task deadline, profile catalogue, goodput floor, route, offered-load schedule and validator before the evaluation set. Model inference can remain variable; record it instead of deleting slow runs. Controller overhead counts in the Meta arm.

A source-data error, task-quality failure, unsafe action or unverified restoration is a failed run even if latency falls.

## 3. Required comparison arms

| Arm | Controller | Workload | Question |
| --- | --- | --- | --- |
| A: Unmanaged | No adaptive intervention; known baseline profile | Same real Meta workload | How harmful is the declared impairment? |
| B: Competent static SQM | Best calibrated fixed allowed profile, frozen before evaluation | Same real Meta workload | How much does conventional queue management already solve? |
| C: Deterministic adaptation | Competent fixed rule controller, tuned on calibration data; same profile catalogue, telemetry, limits and watchdog | Same real Meta workload | What do inexpensive explicit rules achieve? |
| D: Meta control | Actual Meta controller sees path and task context; same action boundaries and watchdog | Same real Meta workload | What changes when Meta selects and verifies the actions? |
| E: Meta without task context | Same model, prompts and budgets except a deliberately specified task-context ablation | Same real Meta workload | Does task awareness affect the result or merely decorate the trace? |

Do not intentionally weaken C by denying it telemetry available to D. Define its rule set and tuning effort; publish them. D and E retain model-call cost and delay. B cannot choose a different rate after seeing evaluation outcomes.

For the later continuity extension, add a strong independent-composition arm: the best calibrated B/C network control plus the same durable runtime, cache, local executor, codec and budgets used by the coordinated system. Comparing joint coordination against that composition isolates coordination value from merely adding more components.

## 4. Scenarios

| Scenario | Purpose | Expected admissible behavior, not a promised result |
| --- | --- | --- |
| Sustained upload congestion | Reproduce original problem | Consider a bounded, calibrated shaping profile after corroboration |
| Healthy network, slow provider | Separate service latency from network delay | Avoid unsupported queue mutation; record provider delay |
| Short load burst | Test unnecessary intervention | Wait or abstain if evidence/benefit does not justify change |
| Capacity change | Test a dynamic regime | Recalibrate or select a permitted profile only with fresh supporting evidence |
| Same path, different task urgency | Test the task-context contribution | Explain any profile/abstention choice against remaining work and deadline |
| Stale observations or route change | Test evidence invalidation | Reject stale proposals and collect new observations |
| No owned shaping authority | Test scope handling | Return unsupported/denied; do not mutate another interface |
| Malformed or duplicate model tool call | Test integration correctness | Reject or return the same historical result without a second side effect |
| Controller timeout or crash | Test restoration independence | Do not guess a new action; expire and restore owned lease as specified |
| Complete outage | Separate recovery from delivery | No live cloud decision is claimed; preserve known safe state and execute watchdog rules |

The cleanest model-contribution case has mixed conditions where a plausible network symptom is sometimes caused by congestion and sometimes by the provider, plus differing task needs. Its value still requires measurement; complexity alone is not evidence.

## 5. Metrics and attribution

| Metric | Definition |
| --- | --- |
| Valid completion by deadline | Validated runs finishing on time divided by all started runs |
| Completion time | End-to-end wall duration; timeouts and failures remain in the denominator |
| Application tool latency | Request issue to usable complete result, separated by tool class |
| Meta latency | Queue/connection/request/first-output/complete-output stages where actually observable; otherwise report the measurable aggregate |
| Controller latency | Observation snapshot available to chosen tool request, then admission/apply/verification spans separately |
| Loaded latency and loss | Declared probe/echo distributions, attempted and received counts, sample window, route epoch |
| Bulk goodput | Useful delivered bulk bytes per second over matched intervals; also cumulative bytes |
| Model contribution | D versus C and D versus E on the same outcome, with overhead and failures included |
| Wrong interventions | Applied mutations in negative controls or without necessary supporting evidence |
| Action churn | Profile changes, rejects, retries and time under each lease |
| Restoration | Success, elapsed time, and readback on normal finish, stop, expiry and crash |
| Resource cost | Model calls/tokens where available, native CPU/memory, transmitted bytes and discarded work |

Record model token usage only when the provider reports it or a clearly labelled estimate is used. Do not turn a model's self-reported confidence into measured correctness. Telemetry can support a queueing hypothesis without proving every delay source.

## 6. Procedure

1. Use a separate calibration set to choose static rates, rule thresholds, prompt versions and budgets. Freeze the configuration and record its hash.
2. Predeclare the evaluated scenarios, run count, success thresholds, deadline and goodput constraint. Ten runs per arm/scenario is a suggested hackathon screening minimum, not a statistical adequacy guarantee. Choose a larger count when variability prevents a useful conclusion.
3. Run matched arms with identical seeded offered-load schedules and corpus versions. Randomize arm order. Avoid simultaneous arms sharing the same bottleneck.
4. Reset the owned topology/profile and state between runs. Reuse warm/cold model/session conditions consistently or explicitly stratify them.
5. Capture raw observations and events, complete unsuccessful runs, and execute the same final validator and restoration check.
6. Compare paired outcomes and uncertainty. For small samples, show every run and sample counts. Do not advertise a stable p99 from a tiny run set.
7. Separate the controlled local-service mechanism test from external-provider experiments. External-service variability belongs in the latter's limitations.

## 7. Proposed acceptance decisions

Mandatory functional gates are real model-issued apply and restore calls, no unauthorized mutation, correct duplicate/stale handling, actual configuration readback, independent expiry restoration, and validated task output. They are assessed directly.

Performance thresholds are configured after calibration and before evaluation: a desired task deadline-success improvement, a maximum acceptable model-control overhead, a minimum useful goodput retention, and an allowed intervention frequency. Do not select thresholds after seeing D's results. The deliverable deliberately does not label arbitrary percentages as achieved improvements.

If D does not outperform C, retain the working Meta integration but narrow the claim: demonstrated bounded agentic control, with no established superiority over the chosen rule controller. If E matches D, task context has not yet demonstrated incremental value. If B wins, stationary SQM is the simpler solution for that regime and the next experiment should test a justified dynamic use case.

## 8. RaptorQ extension experiment

Hold queue management, authenticated session, object bytes, receiver constraints and congestion-control settings fixed. Compare reliable QUIC streams, fixed-budget RaptorQ, and dependency/deadline-aware RaptorQ. Measure exact object-ready time, task-valid completion, total transmitted bytes including repair/control/retries, useful goodput and decode CPU/memory. Include no-loss, burst-loss, sustained congestion, insufficient-symbol and complete-outage cases. Count failed decode and late arrival rather than omitting them.

An exact object receipt requires completed decoding and digest/input checks. A transport ACK, a sufficient-looking symbol count, or a model starting to generate is not that receipt. The coding comparison is distinct from the Meta decision comparison.
