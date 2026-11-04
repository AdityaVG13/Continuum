# Reusable programs and capability boundary

Observe architecture before authoring logic. State purpose, target/firmware,
inputs, bounds, trigger, permissions, readback and rollback. Keep secrets out of
source and knowledge. Programs cannot bypass permissions, delete data, reset,
replace firmware or reboot. Native apply/restore/verify retain their own guards.

Read owner_policy from context or read_policy (empty payload). Only the owner
can change that grant, using setup Permissions or --owner-policy-set; model
text cannot grant execution, widen operations or remove protected users/services.
Use execution_target from context as candidate_id. Without a selected device,
it is local: local programs must not acquire a later-selected router's authority.

install_program takes JSON: id (1..32 identifier bytes), purpose (1..256 bytes),
interval_ms (0 manual; otherwise 60000..86400000), steps, and optional source.
Choose exactly one form:
- Steps: 1..4 objects with exactly operation and payload, with empty source.
  Allowed: sample_host, inspect, runtime, apply, restore, verify. Only apply
  takes a nonempty payload: the five service-selection booleans described by
  manage_device, encoded as a JSON string. Each payload is at most 256 bytes.
- Authored logic: empty steps and nonempty source (at most 1024 bytes of POSIX
  shell). This requires owner opt-in allow_host_programs and execution_host=local.
  Read the supplied JSON from $CONTINUUM_INPUT (host sample, device evidence and
  owner_policy). Stdout must be one JSON object with exactly actions (0..4 step
  objects as above) and summary (at most 512 bytes). Use real evidence to decide;
  the returned actions pass through the same guardian, never execute directly.

Source runs in the host OS sandbox, not on the router. Only shell control flow
and basic text utilities are available; no network, credentials, parent files,
arbitrary executables or persistent writes. Wall time is owner-set (100..10000 ms),
stdout capped at 4096 bytes, with CPU/process/memory limits. Missing isolation
refuses execution. This is not an unrestricted shell or remote deployment.

Use list_programs (empty payload), then read_program (id payload) for retained
source/result. run_program executes an installed id through the same guardian,
without another model call. disable_program pauses it; enable_program resumes
scheduling, not authority. The host resident admits at most one due program per
sample, using durable due-time reservations across restarts. No periodic model
reasoning or router-resident daemon is installed by this mechanism.

The owner selects 1..8 slots and 0..365 retention days (0 disables expiry).
One private registry has a 64 KiB serialized cap, including inline source and
last results: no script files or per-run log history accumulate. Installation
and resident sampling compact expired, inactive resolved records; prune_programs
requests the same operation explicitly. Active, failed/running, or unreconciled
device effects are never pruned. Detailed native recovery artifacts stay intact.
Results are capped at 4096 bytes with explicit truncation. A 120 s admission
window is checked between steps; native operations retain their own bounds.
An interrupted/failed run remains blocked, even after re-enabling. Inspect current
evidence, restore an owned native baseline when needed, then explicitly use
reconcile_program. This is refusal plus bounded reconciliation, not general crash
recovery. Device programs require standing device permission and fresh identity,
and bind to the observed candidate, MAC and firmware. Host-only programs require
no router selection but can return only host-sampling actions.

A saved note is not an installed program; unsupported capabilities still need
implementation. Never claim remote deployment or invent a reboot schedule.
