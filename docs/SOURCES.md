# Source register

Checked 2026-10-26. Public documentation describes available interfaces; only a real account/event preflight establishes access for this project. Design recommendations below are proposed Continuum choices, not claims made by these sources.

## Preceding inputs (not included in this repository)

- Original Meta Dev Hackathon concept: required Wonder controller, live closed-loop shaping and restoration, optional local routing and Spark review.
- Reframing notes: ambitious exploration while preserving the operator's actual success criteria, measurement and honesty.
- Working decisions: implement the specified loop (no re-specification); aardappel Goose preferred, C++ fallback; Meta models central.

## Meta primary sources

| Source | What this repository uses it for |
| --- | --- |
| [Meta Model API overview](https://dev.meta.ai/docs/overview) | API base, authentication, Wonder/Spark model IDs and preview status. |
| [Models](https://dev.meta.ai/docs/models) | Endpoint/model availability and distinction between API Wonder and subscription-only Wonder Full. |
| [Tool calling](https://dev.meta.ai/docs/tool-calling) | Flat Responses function definitions, call/result matching, auto tool choice, application loop limits and strict-schema caveat. |
| [Responses protocol](https://dev.meta.ai/docs/protocols/responses) | Typed items, stateless replay versus stored history, instructions scope and context handling. |
| [Reasoning](https://dev.meta.ai/docs/reasoning) | Private reasoning, token budget implications and optional visible summaries. |
| [Glimmer deployment](https://dev.meta.ai/docs/muse-glimmer/deploy) | Optional self-hosted deployment; actual target-device feasibility remains a build gate. |

## Language, network and transport primary sources

| Source | What it grounds |
| --- | --- |
| [aardappel Goose](https://github.com/aardappel/goose) | The programming language selected by the user; unrelated to the Block Goose agent. |
| [Goose v2026.3 release](https://github.com/aardappel/goose/releases/tag/v2026.3) | Pinned compiler release (hashes in TOOLCHAIN.lock.json). |
| [Goose v2026.3 reference](https://github.com/aardappel/goose/blob/v2026.3/docs/reference.md) | Native interoperability boundary; implementation must follow the pinned release documentation. |
| [CAKE paper](https://arxiv.org/abs/1804.07617) | Smart queue management design and relevant prior work. |
| [Linux tc-cake manual](https://man7.org/linux/man-pages/man8/tc-cake.8.html) | Queue configuration semantics; calibrated scope ownership remains project-specific. |
| [cake-autorate](https://github.com/lynxthecat/cake-autorate) | A serious adaptive network baseline and existing prior work. |
| [RaptorQ, RFC 6330](https://www.rfc-editor.org/rfc/rfc6330.html) | Exact-object fountain coding proposed for an optional owned transport leg. |
| [QUIC DATAGRAM, RFC 9221](https://www.rfc-editor.org/rfc/rfc9221.html) | Unreliable datagrams within QUIC; no automatic reliability guarantee. |
| [FEC and congestion control, RFC 9265](https://www.rfc-editor.org/rfc/rfc9265.html) | Repair traffic must participate in congestion and resource accounting. |
| [QUIC recovery, RFC 9002](https://www.rfc-editor.org/rfc/rfc9002.html) | Transport congestion/recovery boundary. |

This repository does not claim new invention of queue management, adaptive shaping, agent tool loops, durable workflows, erasure coding or QUIC. The proposed contribution is their task-aware, Meta-directed coordination and a measurable demonstration of whether it helps.
