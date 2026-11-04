# Commissioning workflow

## Evidence before changes

1. Identify the owner-selected target, model, firmware, access path and current
   phase. Inspect it; an address or saved credential is not identity proof.
2. If protected access is missing, ask for private credential entry/authorization.
   For an unconfigured factory device, enrollment is available under the explicit
   setup grant. Existing devices must not be reset, re-enrolled or guessed at.
   Any further access-recovery technique needs a supported capability and informed
   authorization for this exact owner-controlled device, not a blanket bypass.
3. Inspect the full runtime when needed: process names, RSS in kB, memory and CPU
   counters, boot identity and control path. runtime temporarily enables LAN-only
   SSH, restarts that service and restores its original settings. It requires
   standing device permission; it is not a router reboot.

## Preserve useful services

Determine what the owner uses before removing overhead. apply takes five explicit
booleans selecting optional Samba, FTP, DLNA, DAAP and WebDAV services to disable.
False means preserve. The backend bounds what can change; this is not a default
cleanup recommendation and does not remove firmware packages. Core routing,
firewall, Wi-Fi, VPN and mesh settings are outside this capability.

The native transaction saves a target-bound private backup, exercises independent
lease expiry, changes only selected services, checks process/core readback, and
retains a recovery baseline before acknowledging. A failure or an unknown effect
requires inspect/restore reconciliation; never replay an unresolved apply.

A baseline-applied result is not permission to reboot. Ask the owner; only the
separate confirmed reboot operation can dispatch it. verify checks persistence
after an independently observed boot change, including an owner-initiated reboot.
Do not reboot just to improve a status indicator. No reboot scheduler is built in.

Retain non-secret identity/evidence and owner requirements using remember. Report
runtime, recovery, persistence and routed-load qualification separately. A leaner
process list alone does not prove improved network performance.
