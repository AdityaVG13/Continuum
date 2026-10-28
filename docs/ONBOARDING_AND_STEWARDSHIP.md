# Onboarding, Delegation, and Stewardship

Design note. **Unimplemented** - everything below is future tense until it
passes a gate. Claim discipline from the README applies: no speedup,
autonomy rate, or live-router result is claimed anywhere in this
repository until measured through the loop in SPECIFICATION.md section 04.

## 1. Problem

Vendor onboarding (setup wizards, companion apps, accounts, bundled
"features") optimizes for the vendor's funnel, not for a fast network.
Continuum's position: never sidecar onto those flows. The device's own
settings interface (HTTP API, SSH) is the control surface; a vendor
wizard is just another device state to detect and move past, not a flow
to embed or re-skin.

Two user intents must both be served:

- **Assist** - the user drives, Continuum verifies each step.
- **Delegate** - Continuum drives everything non-secret, the user takes
  control at the end.

Both modes end in the same verified state. Neither mode ends with
Continuum holding the owner's master credential.

## 2. Credential model

Two credentials exist: the **owner credential** (master password, full
device authority) and the **steward credential** (what Continuum holds
for setup and upkeep).

Device classes determine what separation is actually enforceable:

- **Class A** (scoped accounts or tokens possible: Linux hosts, cloud
  APIs): provision a `continuum-steward` identity with only the
  permissions upkeep needs. Continuum never receives the owner
  credential. This is genuine separation.
- **Class B** (single admin, e.g. stock ASUSWRT on the GT-AX11000):
  separation cannot be enforced by the device. Whoever holds the admin
  session holds everything. The design must not pretend otherwise.

Class B rule: time-boxed steward session, every action written to the
event receipt store (C14), then a mandatory **rotation ceremony** - the
owner sets a new admin password, which revokes Continuum. Setup is not
"done" until Continuum verifies revocation by confirming the old
credential no longer authenticates. Re-entry for later upkeep uses an
explicit re-elevation grant (section 3), never a retained password.

Secret-handling rule: the owner credential and other owner secrets
(PPPoE logins, DDNS tokens) never transit chat, prompts, logs, or model
context. The owner types them directly into the device's own UI. Where
Continuum must submit a secret-bearing form on Class B, the owner
provides the secret through a one-shot OS-keychain read that is
dropped after use and never persisted.

## 3. Admin elevation

A standing "model can take over" posture is a grant, not a vibe. Every
grant is a tuple the operator can read back:

- **scope**: which device(s) and which setting classes (e.g. WiFi and
  WAN on one router - not "the network").
- **expiry**: per-session by default. Standing grants are explicit,
  named, and recommended only for dev work or unused networks.
- **audit**: the C14 receipt store records every action under the
  grant. "The model requested it / the tool applied it / it helped" stay
  three separate records per SPECIFICATION.md section 04.
- **revoke**: one action, immediate, verified by a failed-auth check.

Grant text states plainly what Continuum may change and until when.
Re-elevation for monthly upkeep is a fresh grant each interval, not a
silent extension.

## 4. No-sidecar rule

Continuum drives settings directly through the device interface and
verifies by measurement. Consequences:

- Wizard-state detection (e.g. the ASUS QIS flag) is a collector input,
  like any other device state.
- No screen-scraping of vendor apps, no companion-account creation, no
  bundled "optimization" suites left enabled.
- Services are the owner's choice. The tune pass inventories every
  enabled service, states the measured cost of each in plain terms,
  and the owner keeps or drops each one - interactively during setup
  (Assist default; Delegate proposes, owner confirms). Continuum never
  disables a service unilaterally to satisfy its own model of
  cleanliness. The receipt records who chose what, so a later tune
  pass does not relitigate settled choices.

## 5. Stewardship loop (periodic tune-up)

On a configurable interval (default monthly), plus once at the end of
initial setup, Continuum runs a tune pass over the owned network. It is
the C11 controller loop with a slower clock and a wider action set -
every change still passes guardian admission (C08), actuator readback
(C09), leases and the watchdog (C10):

1. **Measure.** Baseline latency distribution, latency under load
   (bufferbloat), loss, DNS resolution time, channel utilization, link
   rates, firmware version, enabled-service inventory.
2. **Rank.** One dominant cost at a time. No change without a
   measurement that names it.
3. **Change one thing.** Exactly one lever per pass segment, so the
   outcome attributes cleanly.
4. **Verify.** Post-change measurement window; keep on improvement,
   restore on regression or no-effect. Restoration is the normal
   outcome of a failed experiment, not an incident.
5. **Record.** Before/after numbers and the keep/revert decision land
   in the receipt store.

Tune classes, in rough order of expected value on home hardware:

1. Queue discipline / bufferbloat (Smart Queue / fq_codel-style QoS
   with rates set to measured provision, not defaults).
2. DNS (measure ISP resolver vs alternatives; authenticated/encrypted
   transport where the device supports it).
3. Radio (channel selection from utilization scans, bandwidth, 2.4/5
   GHz topology - split SSIDs vs shared vs steering - transmit power
   where regulatory). Band-layout tricks are welcome hypotheses; each
   one still has to survive step 4 to stay.
4. Service review (AiCloud/USB sharing, traffic-analyzer logging,
   WPS, unused guest nets, vendor telemetry): inventoried, costed,
   and put to the owner per section 4 - never unilateral.
5. Hygiene (DHCP lease table, stale port forwards, NAT acceleration
   state vs QoS interaction).
6. Firmware (check, stage, verify boot - owner-confirmed on Class B).

### Continuum opt-ins

Removing what the owner does not want is half the job; the other half
is a small set of Continuum-built additions - offered as recommended
defaults during setup, each individually declinable, each removable in
one action with verified restoration. Anti-bloat gate: an opt-in ships
only if it produces a measurement the loop consumes, adds no standing
traffic when idle, and carries its own keep/revert evidence. Anything
failing that gate is vendor bloat with a new logo.

Seed candidate: the **firsthand measurement sidecar** - a lightweight
prober (latency-under-load sampler, DNS timer) running on the router
where possible, else on a LAN host, feeding the Collector directly.
The controller then reasons from measured path evidence instead of
inferred signals; this is the C06 collector with its own eyes.
Further opt-ins (e.g. a bufferbloat-regression sentinel that re-checks
on the interval and alerts only on drift) earn their place the same
way: measurement in, receipt out, one-action removal.

Firmware ladder, stated honestly: stock firmware exposes classes 1-6
through its HTTP API with limits (no Cake, coarse QoS). Asuswrt-Merlin
keeps the same interface and unlocks scriptable depth. OpenWrt exposes
everything (SQM/Cake, full `tc`) at the cost of the vendor UI. The tune
pass reports which rung blocks the next win; it never silently
reflashes a device.

Hard bounds the loop must state, not discover theatrically:
provisioned ISP rate and hardware NAT caps bound throughput; radio
physics bounds range; tuning wins are latency, consistency under load,
and reliability. A tune pass that cannot move a measurement is a
pass that changes nothing.

## 6. Relation to the core loop

Nothing here displaces tickets C01-C18. Onboarding and stewardship are
the productization track on top of the proven core:

- Proposed **C19** (onboarding ceremony): wizard-state detection,
  Assist/Delegate modes, rotation ceremony with verified revocation.
- Proposed **C20** (steward credential): Class A provisioning, Class B
  time-boxed session handling, secret-handling rule enforcement.
- Proposed **C21** (steady-state tune pass): interval scheduler,
  measurement ranking, one-lever changes through C08 admission,
  keep/revert receipts.

All three are gated on C13/C15 passing first, per BUILD_PLAN.md
section 5. The C++ double (`tests/router_double.cpp`) has the
wizard-state fixture (`ROUTER_WIZARD=1|session`: setup pending is
status-visible, login is locked, one staged setup renames the radio
and rotates the password, and the factory password dies), the
control-channel planner (`src/onboarding.goose`) is implemented and
tested against the scenario catalogue in section 7, and the ceremony
executor is implemented in Goose+C++ (`src/leap.goose`,
`native/asus_web.cpp`, `native/host_macos.cpp`) with a green headless
e2e (`make leap-e2e`); junk-service fixtures are still future work.
Live-router claims rest on the section 7 runs; the Goose-driven live
repetition is pending a factory reset.

## 7. Live prototype plan (GT-AX11000, lab bench)

Observed 2026-10-27 (Mac-side probing, not a repo gate): factory-reset
GT-AX11000 on 192.168.50.1 serves QIS over plain HTTP, passes traffic
pre-setup, and broadcasts open SSIDs. Any GET issues an `asus_token`
cookie, but neither the bare cookie nor a no-auth `login.cgi` POST
establishes an `appGet.cgi` session - nvram reads stay locked behind
`Main_Login.asp` until QIS progresses. So the Delegate channel runs
*through* QIS form submission (step 2 below), not around it; service
inventory unlocks after. That is the Class B starting state.

Read-only baseline, same date, no changes made (single-sample probes
from a Mac bound to the open gaming SSID - orientation data, not a
gate): gateway idle 6.3 ms avg (3.2/11.7 min/max, 40 samples);
1.1.1.1 via the router 13.1 ms avg (7.8/43.8); DNS through the router
2-5 ms vs 16-23 ms via the system resolver. Two early notes for the
tune pass: the system resolver path is slower than the router's own
forwarder, and the 43.8 ms max on an idle link says latency-under-load
probing (the sidecar's first job) will be worth doing.

Prototype sequence, each step verified before the next:

0. Control-channel plan: enumerate every discovered path to the router
   (interface, bind address, does it ride the WiFi being renamed, does
   it survive a rename) and let the planner (`plan_leap` in
   `src/onboarding.goose`) pick the strategy. User topologies vary
   wildly, so no single wiring assumption is admissibility:

   | Discovered scenario | Strategy |
   | --- | --- |
   | Wired LAN to the router | `SurvivingPath` |
   | Router in AP mode behind another gateway, reached over a different SSID | `SurvivingPath` |
   | Second bound device holds the control session | `SurvivingPath` |
   | WiFi-only host on the target's own SSID (the common case) | `SameLinkLeap`: stage new SSID, PSK and admin credential durably *before* the write, expect the disconnect, rejoin the new SSID, re-authenticate, protected read |
   | Nothing reachable | `NoPath`: report what to check; never guess |

   No strategy mutates before the admin credential is staged, and a
   same-link leap additionally needs the staged SSID/PSK. After the
   leap, `classify_leap` names the outcome before anyone acts:
   `Verified` (joined new, admin reads back), `NotApplied` (old SSID
   present, new absent - rejoin old, safe retry), `CredentialMismatch`
   (new SSID visible, staged PSK rejected), `AdminAuthFailed` (joined
   new, staged admin password refused), `Unreachable` (neither SSID -
   bounded wait, then power/proximity checks). The last three are
   honest Class B truths: stock firmware has no confirmed-commit
   rollback timer, so the physical reset stays the final recovery and
   the leap is made deterministic instead - program-generated
   credentials, exact stored bytes, one submission, no guessing. This
   is a C19 requirement: Delegate chooses its control strategy from
   discovered paths, and only saws through its own link as a staged
   leap with a precomputed rejoin.
   Recovery primitive (learned 2026-10-27): a paper-clip factory reset
   (~5s on the GT-AX11000) is the supported escape hatch when the admin
   credential is unknown. Delegate runs must be re-runnable from true
   factory: record exact credential bytes in named fields in a
   permission-restricted store before the first write, verify the session
   token after every request, and never guess passwords. After a password
   write, authenticate with the exact stored credential and do a protected
   read before any WiFi change.
1. Detect QIS state via the device API (done in probing; promote to
   collector input).
2. Delegate: complete QIS with a generated throwaway admin password and
   WPA2 SSIDs; verify routing and DNS from a bound client.
3. Tune baseline: idle/load latency, DNS timing, service inventory;
   apply the cheapest owner-approved win first, verify.
4. Rotation ceremony: owner sets the real admin password; Continuum
   verifies the throwaway no longer authenticates and deletes it.
5. Re-elevation drill: fresh scoped grant, one bounded change, revoke.

Executed 2026-10-27 (`lab/leap_qis.py`, one GT-AX11000, WiFi-only Mac -
the `SameLinkLeap` row above): credentials staged in the macOS keychain
plus a 0600 journal outside the repo, QIS completed over the very link
being renamed, host rejoined `ContinuumLab_5G2`, protected read under
the staged credential, outcome `Verified`. Three firmware facts the
ceremony now encodes (single-unit observations, adapter-isolated in
`native/asus_web.cpp` after the port from the lab script, nothing
ASUS-specific outside that adapter):

- The wizard's unauthenticated factory `chpass.cgi` POST was refused
  (connection cut, nothing stored) and wizard-open reads closed behind
  it, while the factory credential still logged in. Session-first
  completion - factory login, authenticated `chpass` (current
  credentials as hex MD5 per `httpApi.chpass`), verify a fresh login
  with the staged credential, *then* `applyapp.cgi` - is a first-class
  branch of the ceremony, not an error path.
- `x_Setting` alone is not a factory detector: it flipped to 1 while
  the unit was still genuinely unconfigured (open factory SSIDs,
  default password, `w_Setting=0`). Factory detection is a
  conjunction: refuse when any band is already secured or
  `w_Setting=1`; otherwise the unit is onboardable.
- Login failure lockout is real (~245s after 2 failures, counters in
  the login page). The ceremony never probe-guesses a credential:
  staged bytes only, one diagnostic login at most, and the
  lockout state is read before assuming a credential is wrong.

Repeated 2026-10-27 from a clean owner factory reset (run 2,
`x_Setting=0`, wizard-open branch): dry-run, staged fresh credentials
under a run-scoped keychain prefix, submitted, rejoined, protected
read, outcome `Verified` (journal `leap-journal-run2.json`). The run
caught a resume-ordering bug - discovery and the factory gate ran
before the journal's submitted-skip, so a rerun would have refused
the state the ceremony itself created - now fixed. Host-side facts
this run proved (single Mac, macOS 26):

- A stale preferred-network entry for the target SSID (previous
  PSK, e.g. from before a reset) makes every association retry the
  old passphrase forever while `networksetup` exits 0. The rejoin
  forgets the SSID first; success is judged by the DHCP lease,
  never by exit codes or messages.
- CoreWLAN `associate(to:password:)` from an unbundled CLI returns
  -3900 (EAPOL class) even with a provably correct PSK here
  (`lab/macos_join.swift` kept as the diagnostic that proved it);
  `networksetup -addpreferredwirelessnetworkatindex` demands
  interactive admin authorization. Forget-first, then
  `networksetup -setairportnetwork`, then lease-check is the
  working unattended rejoin primitive on this host. A bundled,
  entitled Controller still owns the cross-machine version of
  this step; that remains a named open item, not a silent manual
  step.

Acceptance: C19-C21 behaviors demonstrated against the live box with
receipts, or the miss recorded in STATUS.md. The prototype runs only on
explicit owner approval per step that mutates live state - renaming
WiFi disconnects joined clients, and that is the owner's call, not the
agent's.
