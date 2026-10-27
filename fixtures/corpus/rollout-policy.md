# Rollout policy

Evidence ID: rollout-policy:v1
Artifact status: synthetic demo evidence
Applies to release revision: rc2-2026-10-26

A release containing a schema migration requires a successful forward rehearsal and a successful rollback rehearsal for the exact candidate revision. A missing rehearsal is a blocking condition, even when the CI system marks that job non-blocking.

An unresolved high-severity security finding blocks deployment unless a separately authorized and current exception is present. No exception is included in this corpus.

A named support owner and a prepared customer-response note are required. These conditions supplement the technical gates; they cannot override a security or rollback blocker.

Allowed verdicts are ready, hold, or insufficient_evidence. Use hold when available evidence establishes a blocker. Use insufficient_evidence when readiness cannot be determined and no known blocker already determines the decision.
