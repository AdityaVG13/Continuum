# Meta model integration

**The Meta HTTPS adapter is implemented; no live call has been made yet.** Meta model usage is mandatory in the intended product. Goose is the implementation language; a C++ boundary supplies native I/O. Configurations, prompts and examples in this repository specify what to build next.

## 1. Product-critical model roles

The primary Meta controller diagnoses the incident using both network evidence and the current agent task, selects a bounded intervention, calls the supplied tool, examines the result and requests normal restoration. The primary Meta task agent interprets release evidence and produces the cited readiness report whose completion the system protects. Use separate contexts and tools for these roles even when both use the same model.

The deterministic guardian validates the controller's requests. It does not substitute a rule-selected action for a missing Meta decision. The watchdog restores an expired or failed owned lease independently; label that as watchdog recovery rather than a successful model decision. Meta is therefore both the decision maker in the adaptive loop and the engine doing useful semantic work.

Optional models remain secondary: Muse Spark can review completed incident traces; an eligible local Meta model can perform an expressly supported step after hardware and quality checks. Neither extension is a prerequisite for the core demonstration.

## 2. Verified public interface

Checked 2026-10-26. Meta documents `https://api.meta.ai/v1`, bearer authentication using `MODEL_API_KEY`, and `muse-wonder-1.0` for Wonder. Its overview shows `POST https://api.meta.ai/v1/responses`; Wonder is in preview. Spark standard model IDs include `muse-spark-1.3`. The models page distinguishes Wonder Full, available through Muse Code subscription access, from the API model. These public facts do not establish the team's hackathon eligibility, account access, credits or effective limits. [Meta overview](https://dev.meta.ai/docs/overview) · [Models](https://dev.meta.ai/docs/models)

Recommended starting configuration: Wonder for both required roles, with explicit independent budgets. Keep exact model IDs configurable. If the event permits a different Meta model, record that choice in the run manifest. A provider failure must never silently switch the project to a non-Meta model. Local Muse Glimmer is a candidate extension; benchmark the actual device, runtime, memory, context size and supported task before enabling it. [Model availability](https://dev.meta.ai/docs/models)

## 3. Request and conversation design

Use the Responses endpoint. Join the configured base URL ending in `/v1` with `/responses` exactly once. `schemas/meta-tools.json` supplies flat function-tool definitions; `fixtures/meta-request.example.json` illustrates the body but deliberately contains replacement markers. Load the actual controller prompt and validated context when implementing the adapter.

Meta's protocol offers server-managed history through `previous_response_id` or stateless encrypted replay. The proposed default is stateless replay with `store: false` and `include: ["reasoning.encrypted_content"]`. Preserve retained replay items intact. Instructions must be resent on every request; they do not carry forward automatically. The documentation rejects automatic context truncation. Keep a bounded current incident history and compact settled events explicitly. [Responses protocol](https://dev.meta.ai/docs/protocols/responses)

Provider conversation state is not an application checkpoint. Persist accepted task outputs, input identities, revisions, tool receipts and ambiguous effects separately. A response ID, encrypted item or model narrative cannot prove that a network mutation happened or a task step passed validation.

## 4. Six required controller tools

| Tool | Required contract | Meaning of success |
| --- | --- | --- |
| `read_observation` | Path ID and allowed observation age | Returns measured facts with provenance, timestamps and unknown fields. |
| `read_task_context` | Run identity | Returns task revision, dependencies, remaining work and deadline. |
| `list_profiles` | Owned scope | Returns calibrated finite profiles and configuration revision. |
| `apply_profile` | Request/profile/observation identities, scope/path, revisions, bounded lease and rationale | Returns admission/action state; only later verified readback establishes application. |
| `read_action_result` | Action identity | Returns actual admission, actuation, readback and verification state. |
| `restore_profile` | Owned lease, expected revision, observation and rationale | Returns restoration state; readback establishes completion. |

Meta returns completed `function_call` items; the app returns `function_call_output` items with matching `call_id`. Only `tool_choice: "auto"` is documented, so handle plain text and abstention. Set `parallel_tool_calls: false`. Application code must cap function-tool turns; `max_tool_calls` covers built-in tools. A tool's `strict` flag checks the submitted schema subset and does not replace local argument or authority validation. [Tool calling](https://dev.meta.ai/docs/tool-calling)

The supplied tool definitions use `strict: false` and full local schema validation by design. Preflight can later establish whether a reduced provider-strict schema is useful. Neither choice changes the local checks. No general shell, arbitrary interface, caller-supplied shaping rate or privileged file path is exposed to the model.

## 5. Planned application loop

1. Build a controller context from current observations, task contract, calibrated profiles and active lease. Include model role, request identity, session clock and deadline.
2. Submit one bounded request to Meta. The C++ HTTPS adapter copies any bytes it retains; Goose owns protocol meaning and admission state.
3. Buffer the complete bounded response. Reject invalid JSON, unknown tools, excess argument size or terminal failure. Streaming support may be added later, but partial tool arguments never execute.
4. Resolve a complete tool call against its originating controller request. Validate schema, caller, run identity, tool identity and scope. Before new-action revision/freshness gates, resolve an existing request ID: return the historical receipt for identical parameters, reject conflicting identity reuse, and reconcile an unresolved prior effect without reexecuting it. For a new apply, require matching path, route epoch, task/configuration revisions, allowed profile and observation age. For restoration, require owned-lease identity, current configuration revision and restorable current state; the observation reference is audit context and may be old.
5. For a new apply, collect a current admission window and require that it remains consistent with the model's referenced evidence. A changed route, state or contradictory observation invalidates the request. The guardian does not invent a replacement action. Restoration is exempt from apply cooldowns, profile-change budgets and observation-age gates, including when the model has exhausted its ordinary action budget.
6. Record the request and guard result. If admitted, dispatch the narrow actuator transaction and watchdog lease. Return the honest action state to Meta.
7. Return matching tool outputs, preserve required conversation items and continue within the incident turn/time budget. Meta inspects verification and issues normal restoration.
8. End with an action result or explicit abstention. A missing tool call cannot count as a successful controller intervention.

A model's observation reference may become old during inference. The proposed 15-second maximum age is an unmeasured starting value, paired with current-window revalidation. Calibrate it against actual model latency and the lab's change timescale. Do not claim subsecond cloud control. Fast expiration, safe restoration and stopping unsafe actuation remain local.

## 6. Budgets and failure policy

`config/meta.example.json` proposes a 10-second controller request deadline, 2,048 output tokens, ten incident turns and one controller request in flight. The workload gets a separate 30-second request deadline and 4,096 output-token cap. These are provisional design values, not measurements or provider guarantees. Meta counts internal reasoning within the output-token budget; calibrate the cap rather than assuming every token is visible text. [Reasoning](https://dev.meta.ai/docs/reasoning)

| Failure | Required response |
| --- | --- |
| API key or selected model unavailable | Mark the live integration unavailable; stay in sim/lab-only mode and explain the failed preflight. |
| Timeout, rate limit or overload | At most the configured transport retry, with backoff and remaining-deadline check; no action inferred. |
| Plain text, abstention or incomplete response | Record the result; do not manufacture a tool call. |
| Invalid arguments or revision conflict | Reject and reconcile current ownership/state; do not overwrite another actor's change. |
| Stale evidence for a new apply | Reject and return a bounded error so Meta may gather fresh evidence; this age gate does not block owned-lease restoration. |
| Repeated action request | Return the matching prior receipt; reject identity reuse with different parameters. |
| Actuator failure or ambiguous result | Reconcile actual state before another mutation; use the independent restoration path where applicable. |
| Cloud connection lost | No new cloud-selected intervention; watchdog expiry/restoration and any already admitted local behavior continue. |
| Workload result is well-formed but wrong | Validator rejects it; no task commit or successful demo credit. |

A deadline cancels local interest in a request; it does not guarantee that remote inference stopped or billing ceased. Late provider output is logged as late and cannot act against a newer run/step revision.

## 7. Native boundary to implement

Goose owns request identity, controller/task contexts, response/tool matching, budget decisions, semantic checks and accepted progress. The native adapter owns TLS/HTTPS resources and bounded copied I/O: `native/meta_web.cpp` shells one bounded system-curl call per submit against the configured Responses URL, with the key read from the configured environment variable at submit time and never logged. Goose keeps protocol meaning and admission state.

Never retain borrowed Goose buffers without copying. Never invoke Goose from an arbitrary native worker callback. Poll completed copied events on the Goose owner thread. Native exceptions must not cross the C ABI. Bound response bytes, event count, argument size and retained incident history before allocating or appending. Cancellation invalidates local request generations so late results cannot be admitted accidentally.

The build gate selected the system curl binary over TLS for the Meta adapter; this document does not silently add a Python SDK, framework or separate service. A C++ fallback retains the same contract schemas, prompts and model requirements.

## 8. Visible evidence of Meta's contribution

The demo log records exact provider/model IDs, role, request ID, returned call ID, observation IDs, concise rationale, tool arguments, guard decision and action receipt. Include actual request duration and token usage when the API provides them. Never invent missing usage or label a fixture as a capture.

The display shows a concise explanation and the tool/action trace, not raw hidden chain-of-thought. Meta's public API exposes private reasoning as opaque replay material and optional summaries rather than raw readable internal reasoning. [Reasoning](https://dev.meta.ai/docs/reasoning)

Keep controller and workload metrics separate. The task result must pass its evidence/quality validator. The controller must issue the consequential action, observe the returned result and request normal restoration. A decorative summary written after a deterministic script acts does not satisfy the model-use requirement.

## 9. Required integration gates

- Confirm event rules and real access to the exact configured Meta model.
- Complete one genuine read-only tool round trip before enabling network actuation.
- Demonstrate malformed response, no-tool output, timeout and stale-context rejection with no mutation.
- Make the real Meta controller select a permitted apply action, then verify actual owned-profile readback.
- Feed subsequent observations and the action receipt to Meta; demonstrate its normal restore call and verified restoration.
- Separately kill or disconnect the controller and confirm independent lease restoration.
- Run the same meaningful workload through real Meta inference and the semantic validator; preserve evidence IDs and task revision.
- Compare against a calibrated deterministic controller with the same sensors, action profiles, workload/model settings and budgets. Report the model's incremental usefulness and overhead; it may fail to outperform the baseline.

The gates above are the implementation acceptance criteria, and none has passed yet. This repository supplies their contracts plus the first transport vertical; it does not claim they passed.
