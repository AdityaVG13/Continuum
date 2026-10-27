# Continuum: pitch and claim discipline

**Working positioning:** A Meta agent that understands the network its work depends on, takes bounded corrective action, and checks whether that action helped.

## Thirty-second pitch

Agentic applications are chains of tool calls and model decisions. When a shared connection fills with bulk traffic, those dependent steps can stall even while the connection still moves plenty of data. Continuum gives a Meta controller the task context and live path evidence, plus a small set of reversible network tools. It chooses an allowed intervention, sees the actual result, checks task responsiveness and throughput, then restores its owned configuration. We measure whether the task finished correctly, and compare its decisions against competent conventional network control.

This describes the intended build. Until the live gates pass, use "the design gives" and "the demo will measure" instead of presenting it as an operating product.

## What makes Meta essential

The controller must interpret observations alongside the current workload and issue actual tool calls. Its decisions affect the live run. It receives tool errors, stale-evidence rejections and post-action observations and must respond appropriately. A separate meaningful Meta workload demonstrates why responsive agent loops matter. The model is neither a decorative explanation generator nor a label placed over a pre-scripted decision.

Goose is the implementation language. Meta models provide the agent reasoning. C++ supplies native integrations where useful. Those choices solve different parts of the design.

## Three slides

1. **The problem:** show one useful agent task, competing upload, and separate network/model/task timing. Explain why throughput alone misses the delay.
2. **The intervention:** show the actual Meta tool request, evidence references, guardian admission, owned leased profile and verification. Explain the finite action boundary in one sentence.
3. **The result:** show validated task completion, bulk goodput, restoration, baseline comparison and measured limits. Add one optional roadmap panel for exact evidence delivery and recovery.

## Proposed differentiator

The useful question is whether a model that sees both task needs and path evidence makes better bounded choices across mixed conditions. The core experiment tests that question against static SQM and a competent rule controller. The longer-term direction coordinates exact evidence delivery, execution placement and durable task progress under the same contracts.

Do not claim the first adaptive network agent, universal bufferbloat repair, automatic superiority to CAKE, or novelty in RaptorQ itself. The contribution must come from the specific coordination design and its evidence.

## Claims allowed by each evidence level

| Evidence available | Accurate claim |
| --- | --- |
| This repository (today) | Architecture, interfaces, prompts, examples and build plan are laid out; sim, contracts, virtual-router loop and Meta transport run |
| Real Meta tool round trip with mock actuator | Model/tool integration works in a labelled simulated environment |
| Full controlled lab loop | Actual Meta-selected bounded network intervention and restoration demonstrated on the declared topology |
| Validated workload and matched evaluations | Report the measured task/network effects with sample counts and baseline definitions |
| Positive model ablation | Report incremental benefit over the tested deterministic and no-task-context arms, with limitations |
| Isolated codec test only | Exact reconstruction was tested under those codec conditions; no end-to-end transport claim |
| Owned transport plus task evaluation | Report exact object delivery and downstream task results under those budgets and loss conditions |

## One-sentence stage close

"The result we care about is useful work completed correctly, with an observable Meta decision and a verified return to the original network state."
