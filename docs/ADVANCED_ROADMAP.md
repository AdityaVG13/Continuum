# Continuum: advanced architecture and research gates

**Status: specification only.** This roadmap preserves the ambitious direction without implying that the repository implements a codec, QUIC stack, durable workflow engine, local inference or learning system.

## 1. The stronger product direction

The core demo establishes that a Meta agent can treat path quality as part of its execution environment. The next step is to let it reason over **which exact information or execution step is needed next**, while deterministic components enforce identities, deadlines, budgets and authority. This connects network repair, evidence delivery, eligible execution placement and durable recovery around a verifiable task outcome.

The model selects a bounded strategy at useful decision boundaries. It does not run per-packet congestion control, declare its own output correct, generate privileged shell commands, or bypass resource admission. Low-level scheduling remains explicit code, with model proposals evaluated against the same constraints as any other caller.

## 2. Extension order and exit gates

| ID | Extension | Product purpose | Gate before claiming it |
| --- | --- | --- | --- |
| E01 | Content-addressed evidence objects | Avoid resending accepted exact inputs | Hash, manifest, revision and freshness checks; corrupt or stale inputs cannot unblock a step |
| E02 | Durable step-boundary resume | Preserve accepted work across interruption | Kill/restart reconciliation, durable commit receipts and explicit uncertain-side-effect handling |
| E03 | Eligible local Meta-model execution | Continue a suitable step with available inputs | Actual local model/hardware, quality, memory and deadline gates; complete required inputs already present |
| E04 | Owned RaptorQ transport | Recover exact objects under some loss regimes | Real codec/transport, bounded resources, canonical metadata, exact decode/hash check, matched comparison |
| E05 | Task-aware byte allocation | Spend scarce delivery capacity on dependencies that unlock valid work | Same-budget gain versus competent fixed repair/priority policies; quality unchanged |
| E06 | Retrospective Meta analysis | Learn useful hypotheses from repeated incident evidence | Offline evaluation and approval of versioned candidate policies; no self-promoted production rules |
| E07 | Multiple-path coded delivery | Combine useful symbols over genuinely distinct available paths | Two actual controlled paths, aggregate congestion/resource accounting, failure/correlation tests |

E01 and E02 can add value without E04. E04 does not require a fully generalized workflow engine. Choose one signature extension that fits the event after the Meta core passes its gates.

## 3. RaptorQ: where it belongs

RaptorQ is an object-delivery erasure code specified by RFC 6330. The intended deployment is an owned client and owned relay that both understand the object protocol. It can reconstruct an object when the received symbols are sufficient for decoding; it is not a promise that any arbitrary percentage of packets is enough. [RFC 6330](https://www.rfc-editor.org/rfc/rfc6330)

The proposed carrier uses reliable authenticated control messages and QUIC DATAGRAM payloads for coded symbols. DATAGRAM supports unreliable application messages within a QUIC connection; application code remains responsible for any desired object recovery. [RFC 9221](https://www.rfc-editor.org/rfc/rfc9221)

The relay calls the Meta endpoint using its documented HTTPS API. RaptorQ does **not** wrap or alter an opaque Meta server connection unless that server explicitly supports the same protocol. For the first experiment, a client uploads a frozen evidence capsule to the owned relay, then the relay submits those exact verified inputs to the model. A reverse-direction artifact download needs its own mirrored bottleneck and experiment.

Coding adds traffic and computation. It should not conceal congestion signals or excuse excess sending. The source, repair and control traffic must share a congestion-controlled capacity budget. [RFC 9265](https://www.rfc-editor.org/rfc/rfc9265)

## 4. Proposed object protocol

These are application protocol requirements to implement and review; no interoperability claim is made.

| Message | Minimum content | Receiver obligation |
| --- | --- | --- |
| OFFER | Protocol version, session/object ID, exact length/digest, manifest revision, source/input identities, remaining deadline, codec metadata and resource envelope | Authenticate, validate metadata and bounds, reject stale/unneeded/oversized object |
| ACCEPT | Object ID, receiver credit, supported codec/profile and transfer generation | Reserve bounded resources before accepting symbols |
| SYMBOL | Object/generation/block identity, encoding symbol ID and payload | Reject unknown generation, invalid lengths/IDs and duplicates outside accounting policy |
| STATUS | Admitted generation, exact verified chunks or received symbol state, remaining receiver credit | Treat as delivery state, not completed task progress |
| OBJECT_READY | Exact object digest, length, input validation result and receipt ID | Emit only after decode and integrity/input checks; sender can release object state |
| CANCEL / EXPIRED | Object/generation, reason and final accounting | Stop new work, drain bounded in-flight events and reclaim resources |

Canonical network byte order and explicit lengths are required. Do not serialize a codec library's private structs or private metadata representation. Cross-implementation fixtures must check actual wire bytes, including object transmission information, so two peers cannot accidentally agree on the same nonstandard encoding.

Receiver states are offered, admitted, receiving, decodable, decoded, verified, ready, and cancelled/expired/failed. Only `ready` can satisfy a task's input dependency. Keep decode success, digest success, input freshness and downstream output validation as separate events.

## 5. Deadline and budget design

Reserve time for decode, digest checking, input admission, the downstream Meta request and final task validation. The full task deadline cannot be spent transmitting an object that arrives too late to use.

Enforce cumulative per-run and per-object budgets for all source bytes, repair bytes, reliable-control bytes, retransmission/retry traffic where observable, repeated symbol sends and cancelled in-flight bytes. A limit on unique repair symbol IDs alone does not limit total sending. Log accounting boundaries where transport overhead cannot be measured precisely.

Bound object size, active objects, blocks, symbol size, decoder memory, CPU time, queued sends, peer credit, concurrent decodes and native completion events. Charge duplicates to wire accounting even when they add no decoder information. Release buffers on success, cancellation, expiry, disconnect and explicit close.

A candidate scheduling rule can rank ready objects by the value of the steps they unblock, remaining slack and estimated delivery cost, subject to hard per-class quotas. Start with an auditable deterministic rule. The Meta controller may choose a bounded policy/profile using the task context; it must not assign unlimited importance to its own request or override congestion control.

## 6. Native integration decision

Keep object identity, state transitions, admission and budget logic in Goose where the language gate passes. Put codec/QUIC integrations behind a stable C ABI when their libraries are native. Specify copied versus borrowed buffers, lengths, handle lifetime, explicit error/status codes, cancellation and bounded completion polling. Native callbacks enqueue copied events; Goose consumes them on its permitted thread boundary.

Select a codec and transport only after reviewing maintained source, licensing, RFC behavior, supported platforms and the actual target build. An isolated codec smoke test is not a transport benchmark. No codec or QUIC code is included in this repository.

## 7. Durable progress and local execution

Persist step identity, attempt ID, input/output hashes, source revisions, validator version/result, accepted effects, uncertain effects and pending work. Commit accepted output before displaying progress. On restart, reconcile the effect state before retrying an operation that might already have changed an external system.

A local Meta model is eligible only when the required weights/runtime fit the measured hardware, the step's complete inputs are available and fresh, its independent quality gate passes, and its expected duration leaves validation margin. Record model revision, quantization, runtime, hardware and warm/cold state. A hosted open-weight model is not offline execution. If the step needs a fresh remote fact, wait; caching or coding cannot invent it.

## 8. Retrospective Meta analysis

After a run, a separate Meta session can summarize incidents, find conflicting evidence, suggest a prompt/profile adjustment, or propose a candidate decision rule. Store its hypothesis and source run IDs. Evaluate it on held-out scenarios with the same constraints and baselines. Only a separately accepted version enters future runs. The analyser cannot rewrite the current guardian or increase its own permissions.

This turns the original idea's optional deeper analysis into a measurable learning workflow without requiring model training during the hackathon.

## 9. Highest-value experiment

Freeze one exact evidence capsule whose arrival unlocks a real Meta interpretation step. Introduce a declared loss burst on the owned upload leg. Compare reliable delivery, fixed repair and task-aware repair under the same total budget, deadline and congestion settings. Require exact reconstruction and task-quality validation. If repair spends more bytes without improving valid completion, retain the result and revise the policy.

The ambitious claim to investigate is: **joint attention to task dependencies and network conditions improves valid progress under constrained delivery.** It remains a hypothesis until the strong independent-composition comparison establishes incremental benefit.
