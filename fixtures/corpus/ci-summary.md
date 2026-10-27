# CI summary

Evidence ID: ci-summary:v1
Artifact status: synthetic demo evidence
Release revision: rc2-2026-10-26

The build, unit tests, integration tests, and forward migration rehearsal passed for this revision. The migration rollback rehearsal did not run because the rehearsal environment was unavailable. No successful rollback result exists for this revision.

Tracking item REL-17 remains open. The pipeline's overall green status excludes the rollback rehearsal job because that job was configured as non-blocking in CI. The separate rollout policy determines whether the missing rehearsal is a release blocker.

This evidence supports build health. It does not support the claim that every release gate is satisfied.
