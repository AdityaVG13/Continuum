# Continuum: Meta-centered demo runbook

**Status: proposed live demo, not an executed result.** All timings below are presentation targets. The Meta transport and virtual-router loop exist and are proven against the lab double; no live Meta call, real-router mutation, or hackathon measurement is claimed yet.

## 1. Story the audience should understand

An agent is doing useful work through a real network. A competing upload fills the access queue. A **Meta controller** inspects network evidence and the task's current needs, chooses a bounded intervention, receives the actual tool result, and checks whether it helped. The Meta workload completes with valid evidence. The controller requests restoration; the local tool verifies it.

The visible intelligence is the selection and verification of actions in context. CAKE supplies a network mechanism. Goose supplies the application implementation. RaptorQ is a separately gated extension.

## 2. Required live proof

The stage build must show all six points:

1. A real eligible Meta model request produces the controller's action call. Its identity, request/call IDs and concise evidence summary are logged.
2. Fresh observations distinguish plausible queue congestion from other causes. The bulk transfer remains offered throughout the intervention comparison.
3. The deterministic guardian accepts or rejects the exact requested action; the actuator reports observed state, rather than merely echoing success.
4. The model reads the action outcome and the subsequent observations. A failed intervention remains a visible failed intervention.
5. A meaningful Meta workload produces a result that passes an independent validator. Latency and correctness are both shown.
6. The Meta controller requests normal restoration, and readback verifies it. The independent watchdog is demonstrated separately as the failure-recovery path.

The core tools are `read_observation`, `read_task_context`, `list_profiles`, `apply_profile`, `read_action_result`, and `restore_profile`. Their schemas are authoritative. No tool accepts arbitrary shell text or unrestricted interface names.

## 3. Useful workload: a small release-readiness audit

Use a versioned fixture service beyond the owned bottleneck. The workload agent must assess whether a specific release can ship and cite the evidence supporting its verdict. The supplied synthetic corpus is a proposed, editable default; the user has not selected this exact workload. Its events and findings are examples, not records of a real release or measured model behavior.

| Step | Work | Required dependency or check |
| --- | --- | --- |
| W01 | Read the release manifest and pin commit/revision | Establish identity before dependent requests |
| W02 | Fetch CI evidence for that revision | Keep check results bound to the pinned commit |
| W03 | Fetch the security review | Retain issue identity, severity, status and source references |
| W04 | Fetch rollout policy and release evidence | Preserve required conditions and actual evidence separately |
| W05 | Fetch supporting operational evidence | Independent fetches may run concurrently within the same declared limit |
| W06 | Ask a real Meta model for blocker findings and a proposed verdict | Include the complete evidence; require cited source IDs |
| W07 | Validate findings, source references and revision consistency | Expected fixture answers stay outside model input; the final report is withheld on failure |
| W08 | Render and commit the validated report | Completion follows validation, not merely a model response |

The proposed corpus seeds two blockers: `REL-17`, the missing required rollback rehearsal, and `SEC-42`, an unresolved high-severity authorization defect. Its expected verdict is `hold`. The independent validator checks both blockers, absence of invented failures, correct source references and final verdict. Keep the expected answer in evaluator data, outside the controller and workload prompts. Keep semantic interpretation meaningful; do not simply ask the model to repeat a precomputed `hold` flag. Conversely, do not depend on an unconstrained language-model judge for every objective fact.

The initial corpus is frozen for the run. If a later live-task contract requires a fresh authoritative release-state check, add that check before validation; cached evidence alone cannot satisfy it. The core eight-step example does not claim to implement that future live source.

The controller and workload can use the same Meta model in separate sessions. Their prompts, tool permissions, call budgets and timing traces remain separate. The workload cannot issue network-control tools.

## 4. Three-minute primary sequence

| Time target | Scene | Evidence to show |
| --- | --- | --- |
| 0:00-0:25 | Introduce the release audit and idle path | Task requirement, actual model ID, live mode, known baseline, bulk byte counter |
| 0:25-0:50 | Begin the controlled competing upload | Loaded RTT/application echo, actual queue scope, slower dependent work |
| 0:50-1:20 | Meta reads current observations and task context, then selects a permitted profile | Real tool call, brief rationale, observation IDs, proposed profile and lease |
| 1:20-1:45 | Guardian admits and actuator applies; Meta reads the result and fresh verification window | Admission, readback, latency distribution, continuing goodput, success or failed verification |
| 1:45-2:20 | Workload finishes its evidence-backed report | Real Meta finding, cited inputs, independent validator, total task time |
| 2:20-2:45 | Meta requests restoration | Correlated restore call, exact owned revision and restored readback |
| 2:45-3:00 | Show matched comparison and the honest claim | Sample count, baseline identity, task quality, network effect and model contribution |

The times do not entitle the operator to replace a slow model decision with a scripted action. If real requests do not fit the stage limit, show a labelled recording of a complete measured run and shorten the live explanation. Retain the full underlying trace.

## 5. Suggested narration

**Opening:** "This Meta agent is checking whether a release can ship. Its answer has to cite the evidence and pass a validator. The controller beside it can see both the network and the work that is waiting."

**Impairment:** "The upload is still moving, but it is delaying the agent's dependent requests. These are the current observations, not a diagnosis inferred from a single ping."

**Decision:** "The Meta controller selected this allowed profile for this owned queue. The local executor checks the request's scope, age, revision and lease before applying it."

**Verification:** "The command being accepted is only the beginning. We check the actual configuration, the next observation window, the task's progress and the bulk transfer."

**Finish:** "The report passed its validator. The controller requested restoration, and readback confirms the previous owned profile. Here is the comparison against ordinary queue management."

These are presentation prompts, not prewritten model output.

## 6. Screen and event requirements

Use one compact terminal or dashboard view with task status, current observations, the latest Meta tool request, guardian result, applied profile/remaining lease, verification result and final output. The model record contains a short rationale and evidence references, not private chain-of-thought. Do not animate fabricated reasoning steps.

Every panel has an execution-mode badge:

- `LIVE`: current real model, network and workload events.
- `RECORDED`: a prior measured run with its stored manifest and timestamps.
- `SIMULATED`: development fixtures or explanatory replay.

Operator controls are start/reset, begin/end the owned load, stop, restore the owned lab state, and open the backup recording. No general shell input is part of the product flow.

## 7. Negative control and watchdog drill

Keep one short recorded inspector for each:

- **Provider delay:** application/model response is slow while independent path measurements stay healthy. Meta should avoid a network intervention unsupported by evidence.
- **Controller unavailable:** after an admitted leased action, stop the controller process. The independent local watchdog restores its owned state on expiry and records readback without another model call.

The watchdog is required reliability behavior, not an alternative source of the showcased model decision. It cannot diagnose arbitrary incidents or renew itself indefinitely.

## 8. Optional advanced scene

Only after the main gates pass, substitute a short owned-evidence delivery scene for part of the audit, rather than extending the stage indefinitely. A frozen evidence capsule must arrive at an owned relay before the next Meta interpretation call. Under a declared upload-loss burst, compare reliable transfer and bounded RaptorQ delivery at the same byte/deadline budget. Show actual decode, exact digest match, task-input validation and only then the model call.

The relay-to-Meta API call remains ordinary provider HTTPS. Coding applies only to the owned client-relay leg. Do not claim it modifies Meta's server transport or can send through a complete outage. This scene is absent if its independent transport and correctness gates are not complete.

## 9. Rehearsal and evidence bundle

Before presenting, run on the exact target machine, Meta account/model, topology and fixture versions. Verify that both controller and workload traffic take their declared routes. Exercise normal restore, stop, expiry and controller crash. Run service-delay and stale-observation controls. Keep failed attempts in the evidence set.

Export the run manifest; compiler and build identity; exact model/provider parameters; sanitized requests/tool calls/results; prompt versions; source hashes; raw observations; profile configurations; admission/readback/verification events; model and task timings; goodput; final validator result; and restoration receipt. A successful animation or screenshot is not this evidence bundle.

If the live run fails, say what failed, retain its log, and switch visibly to the labelled measured recording. If the recording is also incomplete, present the architecture and current status without asserting a completed live system.
