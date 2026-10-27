# Release manifest

Evidence ID: release-manifest:v1
Artifact status: synthetic demo evidence
Release: Continuum Demo Application 1.8.0-rc2
Revision: rc2-2026-10-26

The release contains a schema migration, a session authorization change, and user-interface corrections. Readiness must be assessed against the CI summary, security review, rollout policy, and support-readiness records for this same revision.

Release gates include all mandatory tests, closure of high-severity security findings, a successful migration rollback rehearsal, and a support owner. A passing build alone does not authorize release.

Known review items: REL-17 concerns migration rollback readiness. SEC-42 concerns session authorization. The authoritative detail for each item is in the corresponding evidence document; this manifest does not state that either item is closed.
