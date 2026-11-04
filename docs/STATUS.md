# Delivery status

Edition: **3.0 - specification and implementation**.

## Delivered

- Product and architecture specifications, build order and acceptance criteria.
- Meta prompts, tool/schema contracts, configuration and synthetic examples.
- Goose sources for the provider, controller, measurements, admission, actuation, task workload, events and optional transfer.
- Native C ABI with router and Meta backends, explicit stubs for pending adapters, and the C++ fallback entrypoint.
- Build targets for checks, status, transcripts, contract suites and manual probes.

## Current owner-directed infrastructure

Setup, owner dialogue (`--talk`, TUI **t**) and resident incidents now share
`src/device_agent.goose` capability dispatch and the selected device's bounded
knowledge/previous exchange. Meta chooses supported optional-service changes;
setup no longer mechanically cleans all five services or reboots. A separate
owner-approved reboot is enforced in the native adapter. Internal service
restarts remain permitted within supported reversible transactions. Detailed
model workflows live in `prompts/workflows/`; no redundancy topology or reboot
scheduler is imposed.

This is bounded infrastructure, not full network optimization or arbitrary
model-authored program deployment. Authored OS/provider integration proves the
request/tool/continuation and readback boundaries; live Meta commissioning and
physical-router acceptance of this path remain unverified. Earlier verification
entries below are historical evidence, not certification of this new path.

### Verification of this infrastructure slice

Using the pinned local Goose executable at
`.build/toolchain/goose-v2026.3-macos-arm64/goose`:

- `make check device-check setup-check service-check leap-e2e GOOSE=<that-path>`:
  passed. The authored device/model integration selected Samba only, preserved
  owner-required FTP, rejected a model reboot request, retained knowledge across
  owner dialogue, and shared the protected device with resident incidents.
  Evidence: `.build/commission-e2e-c382d9fde01f4fd5a0da32837445b1ee/transcript.json`.
- `make test native-check continuity-check signing-check GOOSE=<that-path>`:
  passed. These are local fallback checks, not a DSR receipt or live Meta proof.
- Reboot-consent mutation: deliberately bypassing the native approval guard made
  the unchanged commissioning test fail at "standing setup permission must NOT
  authorize a router reboot". The production guard was restored and the device
  integration passed again; test SHA-256 stayed
  `f8628b54cef91c796487120ceeb75655b03e5473ecc743d100a290881322f5bd`.
- DSR attempt:
  `/opt/homebrew/bin/bash "$(command -v dsr)" quality --tool continuum --work-dir /Users/aditya/Developer/Continuum`
  exited 4: `continuum` is not configured in
  `/Users/aditya/.config/dsr/repos.yaml`. No DSR verification receipt was produced;
  the Make lanes above are explicitly the local fallback. DSR configuration was
  not expanded as part of product implementation.

## Operational implementation status

### TUI redesign, polish, and cohesion (2026-11-03)

The setup screen in `src/setup.goose` / `native/terminal.cpp` was rebuilt around
five numbered sections (Overview, Network, Device, Programs, Resident) plus
`?` help. A pinned strip on every screen shows what is watched (with
observation age since discovery), the selected device, Meta's permitted
operations, and resident state. Device gates render as an `[OK]/[ ]` checklist;
job results render on their own Result screen; Programs exposes read/disable/
enable/reconcile (`Enter`/`x`/`E`/`R`) through the same guarded registry tools
as CLI and resident. Terminal renderer gained word-aware wrapping, CSI parsing
(arrows/PgUp/PgDn collapse to single key codes so their digits never act as
section keys), and a pinned three-line footer. `setup_resident_status()` is
the single parser for `service/status.json` behind strip and section views.
Legacy hotkeys (`h/o/g`) still work; `tests/setup_tui.py` covers sections,
resident readout, observation age, PgUp, and unknown-program refusal.

Local fallback passed, exit 0: `env -u HOST_LAB -u LEAP_EXECUTE -u MODEL_API_KEY
-u META_API_KEY make check test commission-check leap-e2e asus-check
transport-check meta-check web-e2e-run device-check setup-check
service-check owner-check continuity-check native-check signing-check
GOOSE=.build/toolchain/goose-v2026.3-macos-arm64/goose`. `host-check` built
and explicitly skipped its live run (login Keychain; needs `HOST_LAB=1`).
DSR remains blocked, exit 4: the tool is unconfigured. No live Meta call,
physical-router operation, or paid provider request ran. Live Meta authoring
still awaits a dedicated privately entered key.

| Capability | Status |
| --- | --- |
| Interactive setup and discovery | `make tui`: native masked key entry with optional macOS Keychain persistence, non-secret model/budget settings, OS-derived IPv4 interfaces/routes/neighbors, and a separately scoped read-only Meta investigation. UI/worker path exercised with authored transport; live Meta assessment and public-page probing on physical devices remain unverified |
| Authenticated Meta model call | Request/continuation builders, typed Responses parse and curl-child HTTPS adapter implemented (`src/meta_shape.goose`, `src/meta_provider.goose`, `native/meta_web.cpp`); no live call yet - needs `MODEL_API_KEY` |
| Meta model-driven action selection/tool loop | `continuum --loop` now runs one supervised controller/workload session. Model tool requests reach the selected simulator or loopback HTTP router backend and actual receipts are replayed; there is no parallel scripted router action. Recorded-response integration exercised; keyed execution pending. The comparison against a rule is not measured |
| Meaningful Meta task execution and independent validator | Implemented for the authored release-audit corpus: separate Meta task context with no controller tools, schema/identity/citation/required-finding validation, output retained in the run record. Task errors use the same restoration exit. Recorded-response integration exercised; live task execution pending credentials. Validation is not a durable commit or general proof of arbitrary prose |
| Resident monitoring | `--serve` reads live host IPv4 routes and interface counters, blocks between samples, persists one private bounded status record and rejects duplicate owners. Setup can start it independently of the TUI. Opt-in incident handling uses a durable fixed-window call budget and cooldown and the same owner-scoped supported device capabilities as setup; routed-load tuning, task-context adapter and reboot autostart remain unimplemented |
| Live optimization metrics | Interface counters and IPv4 route changes are collected. `continuum --measure host:port/path /loadpath [--upload]` adds active evidence: separate idle and loaded windows of HTTP RTT (p50/p95) plus measured body bytes and goodput of the load stream, each with its sample and failure counts, the load direction named in the receipt, written as an immutable artifact and refused below a 20-sample floor. An upload load (`--upload`, POST) is the direction a router's egress qdisc can actually shape; an upload the far end rejects is not counted as load. Queue telemetry, bufferbloat attribution beyond RTT inflation, and any physical-router before/after comparison remain unimplemented |
| Guardian checks and authenticated privileged IPC | Guardian checks implemented (sim scope); privileged IPC not implemented |
| Actual CAKE/tc apply, readback and restore | Implemented on the protected ASUS commission channel: typed `apply_qos`/`restore_qos` device operations, owner-grant mapping, generated `tc` programs (never model-supplied shell), independent readback of qdisc kind and CAKE rate, durable before/ownership markers, and typed refusal when `tc` is absent, the root qdisc is vendor-managed, the profile is out of bounds, or the device does not honor the requested rate (a mismatch is rolled back). A read-only `read_qos` preflight reports the qdisc tool and current root without touching anything, and the owner can apply or undo a bounded profile without a provider call (`--device-qos ... --execute`, `--device-qos-restore --execute`) so a lab A/B is not a paid-model measurement. `make device-check` exercises preflight, apply, retune, restore, idempotent restore, absent-`tc`, foreign-root and rate-clamp cases end-to-end against the modeled firmware, including through the model-driven dispatcher. No physical-router run yet, so there is no latency/goodput claim |
| Routed-load qualification (`READY`) | The last gate has a producer and a proof obligation: `--device-qualify <evidence> --execute` requires the device in `network_qualification_required` with runtime, recovery and persistence verified, re-checks the `--measure` receipt (claimable verdict, both windows at the sample floor, real load bytes), and requires `measured_at` to postdate the record's `baseline_at`. Success sets `network_load_verified`; `ready` is derived from every gate, and a record whose bit disagrees with its gates fails to load. Any qdisc apply or restore clears the qualification and moves the baseline, so the next change is measured again. `make device-check` proves a stale receipt is refused and a fresh one opens READY. No physical-router run yet |
| Ownership mode and capability graph | `DeviceState` schema v3 records owner-selected reach (`observer`, `advisor`, `operator`) and the qualification baseline; v1/v2 state files load without gaining reach (a v2 record cannot claim readiness), and hand-edited modes are rejected. `takeover` stays unselectable until `--takeover-drill` proves, on this exact device, that an owner revoking reach mid-effect stops the loop and restores the baseline it owns; the mode gate re-reads that artifact every time. The device reports a read-only, identity-bound capability graph (`id`, `class`, `state`, `settable`) over the closed classes `file_sharing`, `media_server`, `traffic_control`, `remote_access`, `update_channel`; the ASUS key-to-class mapping lives only in the native layer. `apply` selects capability ids the device advertised (never vendor keys), owner policy protects by id before any device I/O, and the adapter refuses an id it never reported |
| Independent watchdog and crash recovery | Sim: lease expiry + persisted-lease startup recovery implemented; separate watchdog process not implemented |
| Event persistence or live dashboard | Sim: append-only journal file sink implemented; dashboard not implemented |
| Deterministic daemon (no model) | Sim: policy-table tick loop with budgets and escalate-on-exception implemented (`make daemon`) |
| Router profile / capability contract | Contract + simulated stock-router backend implemented; real discovery not implemented |
| Onboarding control-channel planner + leap ceremony (C19 groundwork) | Planner decision logic (`src/onboarding.goose`): strategies from discovered paths, staged-credential admissibility, post-leap outcome classification. Ceremony executor implemented in Goose+C++ (`src/leap.goose` + `src/leap_main.goose` → `native/asus_web.cpp` ASUS adapter → `native/host_macos.cpp` keychain/Wi-Fi backend; dry run unless `LEAP_EXECUTE=1`); headless e2e green against the C++ double in both wizard branches (`make leap-e2e`, `make asus-check`). Live `SameLinkLeap` was executed twice against a factory GT-AX11000 via the local lab script (session-first branch, then - after a clean reset - the wizard-open branch; both outcome `Verified` - see ONBOARDING section 7); live repetition driven by the Goose binary is pending a factory reset. The product path is now deterministic rather than model-dependent: `continuum --device-step enroll --execute` (TUI `n` on the Device screen) generates the admin credential on a factory-pending unit, stages it in the OS vault before any write, submits QIS, proves a protected read, and never replays on retry; a bare `enroll` is refused. `make device-check` drives that whole transition against a factory-pending double (`tests/enroll_cli.py`), including the dead factory default, the no-replay rule, and the absence of credential material in output or durable state. Recovery from a factory reset is explicit: re-selecting the same candidate discards the stale binding (identity, gates, standing permission) and returns the record to `selected`, after which enrollment runs the ceremony again - also covered by `tests/enroll_cli.py` |
| JSON-to-Goose schema binding | Tool-call JSON gate (tools, ranges, ids, sizes, correlation) + workload-result validator implemented; tested against fixtures |
| WebApi router transport (virtual router) | Shared participant dispatch over the C++ HTTP transport; captures and restores the exact starting QoS state, independently reads it back, and refuses restoration over outside edits. Supervised targets restricted to loopback; independent crash watchdog, real-router discovery and SSH/tc backends not implemented |
| Durable continuation/local model execution | Completed-output commit and exact-input cross-process recovery implemented (`--resume`, `make continuity-check`); unfinished-step continuation, uncertain-effect reconciliation and local inference not implemented |
| QUIC/RaptorQ transport | Optional; not implemented |

Every remaining operational stub reports `NotImplemented` (Goose) or `CT_NOT_IMPLEMENTED` (C++). Default records are unset and not admissible live inputs. Credentials and live action flags are absent/disabled in the examples.

## Verification scope

Executed 2026-10-26 on macOS arm64 (Apple clang 21, pinned Goose v2026.3)
with the lab side on an x86_64 Linux host (Python 3.14, g++ 16.2.1) over Tailscale:

- `make test`: 137 checks green across four Goose suites (sim loop,
  foundation/daemon/crash-recovery, tool binding + workload validation,
  metamorphic properties). Two mutation spot-checks confirm the suites bite.
- `make check / status / sim / daemon`: exit 0; daemon transcript
  deterministic across runs (`applies=1 restores=1 model_calls=0`).
- `make web-e2e` + `make web-e2e-run` against `lab/router_server.py`:
  WEB_E2E_ALL_GREEN - envelope validation, guardian admission, C++ HTTP
  apply (router revision +1), readback reconcile, restore, post-restore
  drift. Virtual router only; no physical router has been touched.
- `make meta-live` with no `MODEL_API_KEY`: fail-closed green (absent key
  fails before any socket, provenance Unset, no tool call); with a key it
  spends one bounded Responses call and prints META_LIVE_ROUND_TRIP.
- `lab/results/2026-10-26-pfifo-vs-fq_codel.csv`: real veth+TBF curves
  (deep FIFO ~35ms at saturation, fq_codel ~0.3ms) calibrating the sim.

Added 2026-10-27 (macOS arm64, pinned Goose v2026.3, all network
lanes on localhost): control-channel planner scenario catalogue in
`tests/foundation.goose` (FOUNDATION_ALL_GREEN, with a mutation
spot-check: admitting an unstaged same-link leap fails the suite).
The Python virtual router was then replaced by a C++ double
(`tests/router_double.cpp`: item-6 JSON API + ASUS QIS wizard
fixture, `ROUTER_WIZARD=1|session`, fresh state per process), and
every network lane is now self-contained - each recipe spawns the
double with a test-only password and tears it down:

- `make test`: eight Goose suites green (sim loop, foundation,
  toolbind, metamorphic, golden, conformance matrix 24 pass / 2
  require-lab skips, tooljson fuzz 6060 cases, leap logic) -
  276 named checks outside the fuzz iterations.
- `make check / native-check / transport-check / web-e2e-run`:
  green (TRANSPORT_ALL_GREEN, WEB_E2E_ALL_GREEN).
- `make asus-check`: ASUS ceremony harness green in both wizard
  branches (ASUS_CHECK_ALL_GREEN).
- `make leap-e2e`: headless leap ceremony green in both branches -
  dry run writes nothing, execute verifies, second execute refuses
  the configured unit (LEAP_E2E_ALL_GREEN).

Live bench, 2026-10-27 (owner-approved, single GT-AX11000 on the lab
bench): `lab/leap_qis.py` completed a staged same-link leap from
factory state - credentials keychain-staged before any write, QIS
finished via the session-first branch after the firmware refused the
wizard-open `chpass`, host rejoined the renamed WPA2 SSID, protected
read verified under the staged credential (`Verified`; journal at
`~/.continuum-bench/`, secrets keychain-only, nothing in the repo).
Repeated the same day from a clean factory reset (run 2, wizard-open
branch, `Verified`); see the section-7 note for the resume bug and
the macOS rejoin facts that run pinned down.
This was a local lab script proving the ceremony against one
stock-ASUS unit; the ceremony has since been ported to Goose+C++
(`make leap`, dry by default) and is green headless against the C++
double, but the Goose-driven live repetition still needs a factory
reset of the bench unit. Details and the firmware facts learned
are in ONBOARDING section 7.

Reproduce the sim-only lanes with:

```sh
make -B check status sim daemon test GOOSE=/absolute/path/to/goose
```

The double lanes (`make transport-check web-e2e-run asus-check
leap-e2e GOOSE=/absolute/path/to/goose`) are self-contained: they
spawn `tests/router_double.cpp` on localhost with a test-only
password. `lab/` is gitignored local bench tooling and is not part
of the deliverable.

Passing these checks establishes only what each lane exercises: sim behavior,
contract enforcement and the virtual-router loop. It does not validate model
access, real-router effects, measured Internet performance or the hackathon
result. Synthetic JSON examples are designed inputs, not recorded provider
output.

The earlier package's Python policy reference and native/RaptorQ implementation experiments are not part of this edition. Their old verification results do not apply to this deliverable.

### Supervised integration verification - 2026-11-02

- DSR command: `/opt/homebrew/bin/bash /Users/aditya/.local/bin/dsr quality --tool continuum --work-dir /Users/aditya/Developer/Continuum`.
  Blocked, exit 4: `continuum` is not configured in the DSR registry.
  No DSR checks or certification are claimed; captured output is
  `.build/integration-dsr.log`.
- Local fallback: `env -u MODEL_API_KEY -u META_API_KEY make check status sim daemon native-check meta-check transport-check web-e2e-run router-cli meta-live GOOSE=/Users/aditya/Developer/Continuum/.build/toolchain/goose-v2026.3-macos-arm64/goose`.
  Exit 0. Transcript: `.build/integration-integration.log`.
- The shared HTTP session was exercised with explicitly authored controller
  and task responses: apply and receipt replay, task under the intervention,
  independent result validation, and exact restoration of a non-default
  starting configuration. Malformed output and provider-failure responses
  both restore that same baseline. These are controlled-response tests,
  not captures from Meta. The emitted record is `.build/supervised-record.json`.
- Credential lifetime and competing-session lease regressions fail against
  their targeted mutants and pass after restoration of the fixes. No mutant
  remains in the working tree.
- Contract suites: eight pass; `golden` fails with the existing Meta request
  mismatch (5418 expected bytes, 5869 actual). The golden still names nine
  tools while the current allowlist names six. The request-body builder and
  tool file are unchanged from HEAD; the golden was not regenerated.
  All nine suite executables were run individually so this failure could
  not hide the later conformance, fuzz and leap-logic results.
  Transcript: `.build/integration-suites.log`.
- Keyed controller/workload execution, physical-router actuation, live
  telemetry and independent HTTP crash recovery were not verified.
  `MODEL_API_KEY` is absent; the live probe reports `META_LIVE_SKIPPED_NO_KEY`.

### Interactive setup and discovery verification - 2026-11-02

- The default terminal entry and `--tui` now open interactive Meta key/model
  setup, host discovery, bounded read-only Meta investigation and simulator
  runs. No management IP is required; route/neighbor candidates are evidence,
  not authenticated device identity or permission to change the live gateway.
- Local fallback: `env -u MODEL_API_KEY -u META_API_KEY make check native-check setup-check GOOSE=/Users/aditya/Developer/Continuum/.build/toolchain/goose-v2026.3-macos-arm64/goose`.
  Exit 0, `SETUP_TUI_ALL_GREEN`: real PTY input, secret masking, settings
  persistence, clean terminal restoration, live OS gateway discovery and
  UI-to-worker tool execution with an authored Meta transport. Transcripts:
  `.build/tui-acceptance.ansi` and `.build/discovery-acceptance.json`.
- Mutation check: removing native secret masking makes `setup-check` fail
  on API-key disclosure. Restoring the mask returns the full check to green.
- Shared-boundary regressions: `env -u MODEL_API_KEY -u META_API_KEY make meta-check asus-check leap-e2e web-e2e-run router-cli GOOSE=/Users/aditya/Developer/Continuum/.build/toolchain/goose-v2026.3-macos-arm64/goose`.
  Exit 0. Router mutations in these checks target the C++ loopback double.
- Actual terminal recording: `.build/setup-demo.mp4`; masked input, network
  display and request confirmation were visually inspected. No mocked UI.
- DSR command remains `/opt/homebrew/bin/bash /Users/aditya/.local/bin/dsr quality --tool continuum --work-dir /Users/aditya/Developer/Continuum`.
  Exit 4: `continuum` is not configured. These are local fallback results.
- No paid Meta request or physical-router change was made. Keychain writes
  were tested through the fake vault seam, not against the owner's Keychain.
  IPv6 management discovery and non-macOS secure persistence are not provided.

### Completed-work continuity and final integration - 2026-11-02

- The supervised CLI now durably commits independently validated audit output
  after successful cleanup, and `--resume <run-id>` revalidates exact current
  evidence, prompt, schema, validation facts and requested task-model settings
  in a fresh process without Meta or actuation. This is completed-output recovery,
  not unfinished-step continuation or offline inference. Assessment and remaining
  product gates: `docs/progress/continuity.md`.
- Final local fallback command:
  `env -u MODEL_API_KEY -u META_API_KEY MAKEFLAGS=-j1 make check test native-check meta-check transport-check web-e2e-run router-cli asus-check leap-e2e continuity-check setup-check status sim daemon cpp-status meta-live GOOSE=/Users/aditya/Developer/Continuum/.build/toolchain/goose-v2026.3-macos-arm64/goose`.
  **Exit 0**. Full transcript: `.build/continuity-final-checks.log`.
- All nine Goose suites pass, including the repaired request golden. The prior
  mismatch above is historical, not a current blocker: the fixture now names
  the six actual controller tools; no production tool was restored to satisfy
  the obsolete nine-tool snapshot. Conformance still has its two require-lab
  skips; local pass status does not promote those cases.
- Cross-process success, stale evidence/prompt/schema refusal, saved-output
  validation, failed-provider/invalid-output/input-change cleanup and run-identity
  refusal pass through the real CLI plus authored transport. Transcript:
  `.build/continuity-acceptance-1793605758099653000/transcript.json`.
  Incorrect resume provenance is caught by its targeted behavioral mutant;
  production was restored before the final full guard run. Mutation output:
  `.build/autoresearch-continuity/resume-label-mutation.log`.
- `eval_ablation.goose` is explicitly `NotImplemented`; synthetic hard-coded
  success/latency values no longer masquerade as an executed comparison.
- Profiling and bounded A/B results, including the discarded candidate and final
  source/binary-bound confirmation: `benchmarks/results/baselines.md`.
  These establish local validator savings, not faster cloud inference or Internet
  service. The production binary also recovers the authored artifact in fresh
  processes; this is separately labelled absolute latency, not an A/B speedup.
- DSR remains blocked by the registry: the exact command at the top of the
  supervised section exits 4 because `continuum` is not configured. No DSR
  certificate is claimed; the checks above are local fallback execution.
- No paid Meta call or physical-router change was made. The live probe reports
  `META_LIVE_SKIPPED_NO_KEY`; actual provider quality/latency, live optimization
  telemetry, physical effects and independent HTTP crash recovery remain unrun.

### Resident monitor verification - 2026-11-02

- `--serve` is a real host monitor, separate from the deterministic `--daemon`
  simulator. The setup UI starts it after explicit interval/spend permission;
  closing the UI does not stop sampling. Reboot autostart is not installed.
- Observations are IPv4 default routes and interface byte/error/drop counters.
  Latency, reachability and current task context are explicitly unknown, not
  substituted from the simulator. No physical actuator is dispatched.
- One owner holds a private directory lock. The service retains one bounded
  atomic status record, blocks on a cancellable wait between samples and
  preserves service call reservations across ordinary process restarts.
  Meta incidents require saved permission and use one response per admitted
  incident, bounded by a fixed-window call cap and cooldown. No shell/tool
  execution is authorized by an assessment.
- Red/green: setup acceptance fails on the pre-service executable at the
  missing monitor entry; cross-process Meta acceptance fails on the shared
  staging filenames. Both pass with the production changes. The deliberate
  wait-removal mutant fails the real elapsed-time assertion; it was restored
  before final verification. The Meta transport now keeps bounded per-process
  state rather than colliding with setup/background requests in shared files.
- Final local fallback command:
  `env -u MODEL_API_KEY -u META_API_KEY MAKEFLAGS=-j1 CONTINUUM_PROFILE_INTERVAL_MS=15000 make check test native-check meta-check setup-check service-check continuity-check transport-check web-e2e-run router-cli status sim daemon cpp-status GOOSE=/Users/aditya/Developer/Continuum/.build/toolchain/goose-v2026.3-macos-arm64/goose`.
  **Exit 0**. Full transcript: `.build/service-final-checks.log`. Acceptance:
  `.build/service-acceptance.json`, `.build/service-tui-acceptance.json` and
  `.build/continuity-acceptance-1793642555009626000/transcript.json`.
  Existing require-lab conformance skips remain skips, not passes.
- Resource scope and raw observation: canonical row **CT-IDLE** in
  `benchmarks/results/baselines.md`; no sustained-load or inference-cost claim.
- DSR: `/opt/homebrew/bin/bash /Users/aditya/.local/bin/dsr quality --tool continuum --work-dir /Users/aditya/Developer/Continuum`;
  exit 4, `continuum` not configured. The results above are local fallback,
  not DSR certification. No paid provider request or physical-router change
  was made; test-owned monitors were stopped and no deployment was installed.
- Remaining gates are listed in `docs/progress/continuity.md`: observing and
  assessing a host does not yet deliver task-aware physical network repair.

### Dedicated ASUS: physical administrative access

- Owner scope is the dedicated GT-AX11000 only; the working router is excluded.
  Lab management is on Wi-Fi `en0`; the host's default route remains on `en7`.
- Existing Keychain credentials authenticated a protected stock-firmware read.
  A private settings backup was downloaded before software work; metadata:
  `.build/asus-backup-1793646462624340000.json`. Backup restoration is untested.
- Temporarily enabled LAN-only SSH and verified root through `/proc/self/status`.
  Captured kernel, memory, storage and paired CPU-counter snapshots in
  `.build/asus-stock-probe-1793646848412125000.json`. This is an operator
  diagnostic, not the shipped service, a Meta-driven investigation or a speedup.
- Restored original SSH settings and read them back. A later ABI probe lost its
  result when its teardown port check timed out; that probe does not establish
  executable compatibility. Independent follow-up confirmed SSH disabled,
  TCP port 22 refused, QoS and acceleration settings preserved:
  `.build/asus-after-diagnostics-1793647163348011000.json`.
- No firmware was flashed, software installed or vendor services removed.
  The stock kernel reports AArch64; userspace ELF/libc compatibility remains
  unqualified. The ASUS has no WAN lease, so routed-load optimization and the
  router-resident autonomous service remain unverified, not completed.

### Factory-reset ASUS: production onboarding qualification

- After the owner physically reset the dedicated GT-AX11000, the production
  Goose/C++ `.build/continuum-leap` completed setup with new, previously absent
  Keychain references. No pre-reset administrator password was used. Public
  factory defaults were used only by the firmware's initial-setup session.
- The executable staged fresh secrets (`reused=false`), proved the new admin
  login, submitted wireless setup, rejoined `ContinuumFresh_5G2` with a real
  DHCP lease and completed a protected read (`authenticated=true`,
  `wl0_ssid=ContinuumFresh_2G`). Transcript and reference-only metadata:
  `.build/asus-fresh-8d3c5d7450cb4327.log` and the matching `.json`.
- Fixed two actual host-backend gaps before that write: a retained in-prefix
  alias no longer counts as a join, and the PSK goes to `networksetup` through
  private stdin rather than argv. The frozen regression failed on the old
  backend, passed with the fix, and rejected separate alias/password mutants.
  The restored production backend and existing host/ASUS/Goose E2E/native
  checks passed; see `.build/host-fresh-green-1793649706085873000.log`.
- Removed the earlier temporary management alias; the real lab DHCP address
  remained, public model identity still answered on Wi-Fi, and the working
  default route remained `10.0.0.1` through Ethernet `en7`.
- An additional external verifier could not export the new credential through
  the Keychain CLI without authorization; it made no configuration writes and
  does not provide a second protected-read claim. The successful protected
  read above belongs to the production executable's completed hardware run.
- This qualifies that hardware onboarding path, not arbitrary routers, a
  pristine-Mac discovery experience, first-run TUI integration, Meta-directed
  optimization or router-resident software deployment. DSR remains blocked:
  `quality --tool continuum --work-dir /Users/aditya/Developer/Continuum`
  exits 4 because the tool is not configured; checks used the local fallback.

### Commissioning: runtime inventory and reboot qualification

- Finished the production `runtime` action: root-qualified boot, CPU/memory and
  bounded process-name/RSS observations are saved privately without command
  arguments. It restores the prior SSH configuration and leaves service flags
  alone. Acceptance covers a resource owner outside the cleanup allowlist.
- Added explicitly authorized `reboot` and separate `verify` actions. Verification
  binds to the saved target/credential reference, firmware/core configuration,
  owned service settings and the boot recorded after the applied baseline.
  Same-boot reads, changed settings and running disabled services cannot certify
  persistence. A successful persistence receipt still says `commissioned:false`
  and `network_load_verified:false`.
- The production executable rebooted the dedicated GT-AX11000. A subsequent
  authenticated process verified a different kernel boot ID, disabled Samba and
  DLNA settings, absent disabled daemons and preserved core settings. Evidence:
  `.build/commission-persistence-d4445dd8f07444e791c1570b7549a02d.log` and its
  `runtime_path` under the original recovery directory. TCP port 22 independently
  refused connections after verification. Ethernet remained the default route.
- Recovery boundary: macOS roamed to the working network during the reboot.
  A bounded passive wait did not recover the management path; an explicit join,
  DHCP evidence and protected readback did. Added verification-time rejoin of
  enrolled SSIDs using the existing private-stdin/Keychain backend, only with
  permission, Wi-Fi control and no explicit source bind to reinterpret. Offline
  failed/successful rejoin coverage passes. The final rebuilt executable's owner
  authorization timed out; this latest recovery addition is **not live-qualified**.
  No further reboot was issued. Blocker record:
  `.build/commission-final-authorization-5c2b1b8069244ca78d64c814152bd595.log`.
- DHCP supplied the ASUS as gateway and DNS server. A source-bound TCP DNS query
  returned the ASUS management address for `router.asus.com`; UDP returned the
  working gateway instead. The discrepancy is recorded without attributing it
  to firmware or changing host/network DNS. WAN remained `0.0.0.0`; routed-load
  performance, functional WAN firewall isolation and a network speedup are not
  qualified. Firmware components were not deleted or replaced.
- Final local fallback returned exit 0 for `make check test commission-check
  leap-e2e asus-check native-check host-check .build/continuum-leap HOST_LAB=1`
  with the pinned macOS Goose. All nine Goose suites ran; two require-lab cases
  remain explicitly skipped, not passed. Full command/output:
  `.build/commission-final-352a8806b97947ff9a2b70cc4b080cc2.log`.
  The broader run exposed and fixed a real pinned-sidecar C++ compatibility
  failure in SSH argv construction. Three deliberate mutants were rejected:
  process-inventory filtering, same-boot certification and omitted roaming
  recovery. Production sources were restored and the final lanes rerun:
  `.build/commission-mutations-2cb74016512d4bb28a9df6b0b7a4c391.log`.
- DSR command `/opt/homebrew/bin/bash /Users/aditya/.local/bin/dsr quality --tool
  continuum --work-dir /Users/aditya/Developer/Continuum` remains blocked, exit 4:
  the tool is not configured. No DSR pass or optimization benefit is claimed.

### Legacy Keychain prompt repair

- The prior SecItem query flag did not prevent a legacy ACL authorization dialog.
  The macOS backend now serializes Keychain operations and temporarily disables
  legacy interaction for quiet reads, restoring the prior policy on return.
  Failure to establish that policy refuses before accessing the item. Explicit
  owner authorization remains a separate interactive action; it was not retried.
- Automatic Wi-Fi recovery now fetches its credential quietly before removing a
  remembered network or attempting a join. An unavailable credential cannot open
  a password dialog or mutate Wi-Fi state as part of that recovery attempt.
- `tests/commission_keychain.cpp` substitutes the legacy API behavior, not the
  backend: it ignores the modern query flag and detects the actual interaction
  policy. The unchanged assertions fail before the repair and pass afterwards;
  removing the legacy suppression or making recovery interactive fails again.
  Production was restored and the test forcibly rebuilt after each mutation.
  Red: `.build/commission-keychain-red-83152179b7664eedbf9aac18bf54cb31.log`.
- Local fallback `make -W native/host_macos.cpp check commission-check leap-e2e
  asus-check native-check host-check .build/continuum-leap
  GOOSE=.build/toolchain/goose-v2026.3-macos-arm64/goose` passed, exit 0.
  Log: `.build/commission-keychain-final-a9cd5f3f9e084b28b395d9e5aa27864e.log`.
  `host-check` built but intentionally skipped its real-Keychain write/delete
  lane; no `HOST_LAB=1` is claimed for this repair. DSR was retried with the exact
  command above and remains blocked, exit 4, because `continuum` is unconfigured.
- Real production `COMMISSION_ACTION=inspect`, without interactive authorization,
  returned `credential_access_requires_owner_authorization`, `changed:false`,
  exit 1 rather than waiting for owner input. The protected item was not
  exported; no password was printed, requested or retried. Follow-up found no
  SecurityAgent windows and no remaining `continuum-leap` worker. Log:
  `.build/commission-quiet-live-812bf9939ce24290b93098add01f6edd.log`.
- The credential-access boundary is qualified to refuse this unavailable access,
  not to grant it. Latest-executable roaming recovery and the remaining hardware
  gates still require an authorized, stable credential-access identity. No new
  physical-router verification, router change or completed commissioning is claimed.

### Main-program selected-device lifecycle and resident handoff

- Connected discovery/owner selection, protected device/firmware identity,
  enrollment, approved commissioning, reboot/persistence verification and resident
  observation through one private device binding. Goose owns phase transitions;
  the native boundary locks that binding and synchronizes intent before effects.
  Uncertain enrollment/apply/reboot phases are not blindly replayed on restart.
- The TUI exposes selection, saved gates, protected inspection, separate credential
  authorization, approved setup/restore and read-only monitoring. Main-CLI device
  commands and their incomplete exit status are documented in `README.md`.
- Resident incidents now support a bounded Meta tool conversation: protected
  inspection returns the selected device's actual receipt; tool results are
  submitted with the real call identity; each continuation reserves durable spend.
  Changed identity, a different candidate and physical apply/restore are refused.
  This path never dispatches the simulator actuator.
- Local fallback passed, exit 0: `env -u HOST_LAB -u LEAP_EXECUTE -u MODEL_API_KEY
  make check test commission-check leap-e2e asus-check host-check transport-check
  meta-check web-e2e-run device-check setup-check service-check continuity-check
  native-check signing-check .build/continuum-leap
  GOOSE=/Users/aditya/Developer/Continuum/.build/toolchain/goose-v2026.3-macos-arm64/goose`.
  Full command/output: `.build/lifecycle-final-green.log`. All nine Goose suites
  ran; the two require-lab matrix cases and real-Keychain `host-check` execution
  remain explicitly skipped, not passed. Both production executables were built.
- `make device-check` exercises the main-program handoff with a loopback ASUS
  double and authored OS/Meta boundaries, not real inference/hardware. Removing
  the device-identity guard fails the changed-device assertion:
  `.build/device-identity-mutation.log`. The guard was restored, production
  rebuilt and the complete affected lanes rerun successfully.
- The first combined check failed at a PTY assertion, exit 2:
  `.build/lifecycle-final-checks.log`. Its reader had waited for the heading,
  then asserted a phase which could arrive in the next chunk. It now waits for
  the phase and still asserts both heading and phase; failure cleanup drains the
  terminal so a blocked final redraw cannot hide the original assertion. No
  product behavior, timeout or acceptance criterion was relaxed.
- DSR `/opt/homebrew/bin/bash /Users/aditya/.local/bin/dsr quality --tool continuum
  --work-dir /Users/aditya/Developer/Continuum` remains blocked, exit 4, because
  `continuum` is unconfigured. Record: `.build/lifecycle-dsr.log`.
- Hardware gate unchanged: the existing protected item still needs explicit
  owner authorization for the chosen stable application identity. No new owner
  prompt, physical-router operation or paid provider request ran. The authoritative
  record emits `ready:false` and `network_load_verified:false`; routed-load tuning,
  general controller crash recovery and autonomous physical maintenance remain
  unimplemented, not hidden behind a successful baseline-persistence result.

### Existing-item authorization through the signed main application

- Owner-approved `.build/continuum --device-step authorize` completed, exit 0,
  using the existing administrator credential. The application signature verifies
  as `org.continuum.controller`, Developer ID team `MTLF932YPV`.
- A separate `.build/continuum --device-step inspect` completed with prompting
  disabled, exit 0, and matched the dedicated GT-AX11000's MAC and firmware.
  The authorization requester exited; the Ethernet default route stayed on en7.
  Evidence: `.build/lifecycle-owner-authorization.json`.
- This clears administrator protected-read access for the main application,
  not other executable identities or the separate Wi-Fi PSK. No credential
  rotation, router configuration write, reboot or provider request ran.
  The current binding is `enrolled`, `setup_approved:false`, `ready:false`;
  latest-path commissioning, rejoin/persistence and routed-load qualification
  remain separate gates.

### Owner-configurable authority and local authored maintenance

- Added owner policy editing through the CLI and setup, shared with Meta tools
  and resident execution. It covers permitted device operations, protected
  clients/services, local-code opt-in, slots, retention and execution time. The
  launching computer is the default execution host; `CONTINUUM_HOME` selects
  private state placement. Arbitrary remote-code deployment is not implemented.
- Installed programs may now contain bounded authored local shell logic. Real
  Seatbelt/bubblewrap execution receives bounded observations without inherited
  keys, parent files, persistent writes or network access. Returned action
  intents pass through the existing device guardian. No model text grants
  authority; protected clients refuse changes whose continuity is unproven.
- Source/latest results share one capped registry; expired inactive resolved
  records compact without deleting files. Active/failed/ambiguous work remains.
  Recurring native runtime inventories and event receipts now replace bounded
  latest observations instead of accumulating snapshots/history. Immutable
  recovery baselines and existing backup files are not pruned.
- Local fallback passed, exit 0: `env -u HOST_LAB -u LEAP_EXECUTE -u MODEL_API_KEY
  -u META_API_KEY make check test owner-check device-check setup-check service-check
  continuity-check native-check signing-check
  GOOSE=/Users/aditya/Developer/Continuum/.build/toolchain/goose-v2026.3-macos-arm64/goose`.
  Log: `.build/owner-final-final.log`. The two require-lab matrix cases remain
  explicitly skipped. Owner permission, unsafe failed-record pruning and sandbox
  file-read mutants each failed; each was restored and the same test passed.
  Logs: `.build/owner-{permission,retention,sandbox}-{mutation,restored}.log`.
- Linux ARM64 native builds and device/UI/resident/continuity acceptance passed
  using RCH on Spark. Retrieved artifacts: `.build/linux-final/`. Its bubblewrap
  cannot create the isolated network namespace (`Failed RTM_NEWADDR`); authored
  execution correctly refuses there. RCH declined omarchy as unavailable; a
  direct SSH build on that idle x86_64 host passed the identical owner-program
  test with real bubblewrap. Verified transcript:
  `/home/aditya/Developer/Continuum/.build/owner-programs-e83545c99cbe42b49113bd605cc85869/transcript.json`.
  Native Windows acceptance was not run. No host security setting was relaxed.
- Profiling captured real local-program invocations and the idle resident in
  `.build/owner-profile-8a298dff3f2f4a4c887c45fe6d4b295b/`. Sampling shows blocking
  waits, not an idle busy loop. No speculative performance edit, throughput
  improvement or physical-network benefit is claimed.
- DSR `/opt/homebrew/bin/bash /Users/aditya/.local/bin/dsr quality --tool continuum
  --work-dir /Users/aditya/Developer/Continuum` remains blocked, exit 4: the tool
  is unconfigured. Exact command/output: `.build/owner-final-dsr.log`. Live Meta
  authoring awaits a dedicated privately entered key; no paid provider call,
  physical-router operation or Hermes restart was used for this slice.
