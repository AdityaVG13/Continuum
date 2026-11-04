# Lab

How Continuum was tested before the hackathon demo. Lab code is not published;
this file is the public record of what the lab is, what ran on it, and what
was proven vs. controlled.

## What the lab is

- **Loopback doubles**: `tests/router_double.cpp` (C++ HTTP router/QoS + ASUS
  QIS wizard fixture), `tests/host_fake.cpp` (process-disjoint transition
  fabric, atomic persistence, macOS host collisions). No external network.
- **Authored transports**: recorded/fixture Meta transports replay real
  receipts through the shipped request/continuation builders; they are not
  live provider calls.
- **PTY acceptance**: `tests/setup_tui.py` drives the real `.build/continuum`
  binary's TUI in an isolated home (tmp `XDG_CONFIG_HOME`), with a synthetic
  env key. `tests/commission_cli.py` drives the setup wizard from enroll to
  READY against the router double and the modeled firmware shell: a refused
  then accepted key, Meta commissioning (authored transport), a reboot whose
  answer is lost while the unit goes dark, the persistence check, the qdisc
  preflight/apply/readback, an upload measurement, qualification and the
  resident monitor. No Keychain writes in tests.

## Tested on

- Apple M5 Max, 18 cores, 48 GiB, macOS 26.6.2 / Darwin 25.6.0 (local).
- Pinned Goose v2026.3 (`4d3da949e563`), Goose `-O2`, Apple clang 21.
- Everything under `make check test …` in README was run with `HOST_LAB`,
  `LEAP_EXECUTE`, `MODEL_API_KEY`, `META_API_KEY` unset.

## What this proves

- Discovery reads live host route/interface state; setup, owner dialogue and
  resident incidents share one selected-device capability dispatcher.
- Owner policy, protected clients/services, lab/load/effects admission,
  restore refusal, secure app-identity enforcement, and resident handoff.
- The ASUS commission channel applies a bounded CAKE/fq_codel profile with
  generated `tc` programs, reads the root qdisc and rate back from the device,
  restores the kernel-default qdisc, and refuses honestly when `tc` is absent,
  the root is vendor-managed, the profile is out of bounds, or the device does
  not honor the requested rate. `make device-check` drives these cases through
  the same SSH/generated-program path the physical adapter uses, against a
  modeled firmware shell.
- The TUI renders the real state at 80x24 and wider, restores the terminal on
  exit, and keeps secrets out of model context.

## Physical lab run (owner-gated, not yet executed)

Everything happens inside `continuum` -- no flags, any directory, any link.
Each step is one screen; `[Enter]` opens that step's confirm frame, which
states exactly what will be written, and a second `[Enter]` dispatches it.
`[Esc]` on a confirm frame cancels without dispatch; `[Esc]` on the wizard
quits; `[a]` opens the panels and `[Esc]` there returns. The flow from "no
router in reach" through a Wi-Fi bind, and from enrollment to READY, is driven
keystroke by keystroke against the double in `make device-check`
(`tests/commission_cli.py`, `WIZARD_REACH_GREEN`, `WIZARD_LIFECYCLE_GREEN`);
none of it has run on the physical unit yet.

Install once: `curl -fsSL https://github.com/AdityaVG13/Continuum/releases/latest/download/install.sh | sh`
(binary in `/usr/local/bin`, prompts/schemas in `/usr/local/share/continuum`). Have ready: the Meta key, your
line's upload bandwidth in kbit/s, and -- for step 8 only -- a far-end HTTP
server reached through the WAN that answers `GET` on a probe path and accepts
`POST` uploads (e.g. `/ping`, `/bulk`). A terminal of 100x40 or more keeps
receipt lines unclipped.

How the Mac reaches the router does not matter:

| Situation | What you do | What step 1 shows |
| --- | --- | --- |
| Cable to a LAN port, or already on the router's Wi-Fi | nothing | `Routers this Mac can reach`, the router marked `>` |
| Factory-reset router, Mac on no network or another one | pick the router's Wi-Fi in the menu bar (ASUS: `ASUS_XX`, open) | `Looking for your router`, then the router marked `>` within a few seconds |
| Cable to the ISP gateway and Wi-Fi on the router | nothing | both gateways; only the supported router is marked |

Step 1 keeps looking on its own every two seconds; there is nothing to type.
Each gateway is labelled `ASUS router -- supported`, `<vendor> router -- no
Continuum backend yet`, or `no web answer on port 80`; only ASUS has a backend
today, and only a supported router is ever marked. macOS hides Wi-Fi names from
command-line tools, which is why the join is a menu-bar click.

| Step | Keys | You should see | Stop if |
| --- | --- | --- | --- |
| start | `continuum` | `STEP 1 OF 8   BIND THE ROUTER` (table above) | the GT-AX is never marked |
| 1 BIND | `Enter` | `STEP 2 OF 8` (nothing written to the router) | |
| 2 ENROLL, factory unit | `Enter`, `Enter` | about a minute, then `STEP 3 OF 8`; Wi-Fi renamed to the stem, the Mac rejoins it by itself | any other `WHY IT STOPPED` |
| 2 ENROLL, configured unit | `Enter`, `Enter`, then `p`, admin password, `Enter` | `WHY IT STOPPED ... already set up`, then `Password accepted` and `STEP 3 OF 8`; zero writes | the password is refused twice |
| 3 KEY | `Enter`, key, `Enter`, `Enter` (saves it in the Keychain; `n` = this session only) | `CHOOSE THE META MODEL`: the models this key can use, with Meta's prices | `refused this key while listing`: `k` enters another |
| 3 MODEL | `Enter` keeps the marked `muse-spark-1.3` (or a number) | `REASONING EFFORT` with the cap and step bound per level | |
| 3 EFFORT | `Enter` keeps the marked xhigh (or a number), `Enter` | one connection-test call, then `STEP 4 OF 8` and `Key  verified` | the test is refused |
| 4 SETUP | `Enter`, `Enter` | Meta works (bounded calls), then `STEP 5 OF 8` with `RECEIPT    baseline applied; runtime and recovery verified by the router` | `WHY IT STOPPED` (Meta finishing without a verified baseline counts as a failure) |
| 5 REBOOT | `Enter`, `Enter` | `WAITING FOR THE ROUTER`, `Went down   yes`, then `The router stopped answering and is back` | `the router has not answered for 10 minutes` |
| 6 VERIFY | `Enter`, `Enter` | `PERSIST    verified by the router` and `STEP 7 OF 8`; no model call | `reboot_not_observed`: power-cycle the unit, then `Enter` |
| 7 TUNE, preflight | `Enter`, `Enter` | `PREFLIGHT  tc present; eth0 root queue now: ...`; nothing written | `qdisc_tool_unavailable`; `already_managed` (turn off Adaptive QoS, then `Enter`) |
| 7 TUNE, apply | `Enter`, `Ctrl-U` + upload kbit/s, `Enter`, `Ctrl-U` + `eth0` (`ppp0` on PPPoE), `Enter`, `Enter` | `QDISC      cake <N> kbit/s on eth0` and `READBACK   verified on the router`, `STEP 8 OF 8` | no `READBACK   verified`; `readback` refusals roll back: `c`, lower rate |
| 8 MEASURE | `Enter`, `host:port/ping`, `Enter`, `Ctrl-U` + `/bulk`, `Enter`, `Enter` | `MEASURED   claimable: ...` and the `EVIDENCE` path | unclaimable: `c` fixes the target |
| 8 QUALIFY | `Enter`, `Enter` | `SETUP COMPLETE` | any refusal |
| READY | `Enter`, four prompts (`Enter` keeps each default), `Enter` | `Monitor  monitoring, pid <pid>, <n> samples`, refreshing each second | `Monitor not started` |
| undo (A/B) | `u`, `Enter` | kernel default queue back; TUNE and MEASURE re-open | |
| leave | `Esc` | the monitor keeps running; stop it with `kill <pid>` | |

Minimum for tonight's go/no-go (factory reset): steps start through 4 --
reachable over Wi-Fi from nothing, enrolled under a Continuum-minted
credential, the chosen Meta model accepted, and the baseline applied by Meta
with the router's receipt.

The target and upload path (and the upload rate and WAN interface) are saved
once in `~/.config/continuum/network.json`; `c` on steps 7 and 8 changes them.
The model and effort live in `~/.config/continuum/settings.json`.

Record every artifact: `~/.config/continuum/device/state.json`, the
`device/measure-*.json` evidence the wizard named, `device/recovery-*/qos-last.json`
and `service/status.json`. Abort criteria: any apply receipt without a verified
readback, any restore that cannot read the kernel-default root, or a measurement
whose verdict is not `claimable`.

Headless equivalents (debugging only): `continuum --meta-models`,
`--test-meta`, `--device-step inspect`, `--device-step verify --execute`,
`--device-step qos-status`,
`--device-qos '{"bandwidth_kbps":N,"interface":"eth0","mode":"cake","overhead_bytes":0}' --execute`,
`--device-qos-restore --execute`, `--measure <target> <load-path> --upload`
and `--device-qualify <path> --execute`.

## What this does not prove

- No live Meta call, no real-router mutation, no Internet performance.
- No `tc`/CAKE run on the physical GT-AX11000 yet, so no latency, goodput or
  bufferbloat number is claimed.
- Controlled doubles are not live Meta or physical-router proof. Session-local
  performance numbers in `benchmarks/` (gitignored) are not a claim.
