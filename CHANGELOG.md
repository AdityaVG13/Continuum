# Changelog

All notable changes to Continuum. This project is pre-1.0: surfaces change, and
a capability listed here is listed with its evidence in `docs/STATUS.md`.

## [0.2.3] - 2026-11-04

- **Meta setup no longer fails on the router's SSH restart.** Turning on LAN
  SSH restarts the router's SSH daemon; the first connection right after was
  refused (`ssh_before_program_exit_255`, seen live on a GT-AX11000), so the
  apply never ran. A connection-phase failure (nothing sent to the router yet)
  now waits for the SSH port to accept connections and retries up to three
  times; a refused password or a changed host key is not retried.
- SSH failures name their cause (`connection_refused`, `timeout`,
  `auth_denied`, `host_key_changed`, ...) instead of a bare exit code.
- **The TUI opens about 5x faster** (2.5 s to 0.5 s measured on the lab Mac):
  step 1 probes only gateways, not every silent host on the LAN.

## [0.2.2] - 2026-11-04

- **Meta setup no longer runs out of calls before it acts.** The setup step's
  budget is 8 model calls (was 4; seen live: four read-only calls, no apply).
  Picking a model raises a lower saved budget to 8 and prices it that way.
- Meta is told its call budget, and that the owner policy and a fresh inventory
  are already in context, so it does not spend calls re-reading them.
- A run that still exhausts its budget names the operations it spent it on.

## [0.2.1] - 2026-11-04

Fixes from the first physical run on a factory-reset GT-AX11000.

- **Relaunch resumes where you left off.** A router already enrolled is no
  longer offered enrollment again after restarting `continuum`.
- **Faster rejoin after enrollment.** Instead of a fixed 45 s wait and six
  tries per band (highest band first), Continuum polls every band each round,
  5 GHz first, and moves on the moment the renamed Wi-Fi gives this Mac an
  address. A retry after an interrupted enrollment rejoins the renamed Wi-Fi
  before probing the router.
- **A long step says what it is doing.** The enroll screen states it takes 2-5
  minutes and that Wi-Fi drops while the router restarts it.
- **One stray Esc no longer quits.** Esc asks once more; progress is saved.
- The installer warns when an older `continuum` earlier on `PATH` would shadow
  the new one.

## [0.2.0] - 2026-11-04

### Changed

- **One command, one key.** `continuum` opens the setup wizard and every step
  advances on `Enter`. Step 1 keeps looking for the router by itself: plug in a
  cable or pick the router's Wi-Fi in the menu bar (a factory-reset ASUS shows
  as an open `ASUS_XX` network) and it appears. Only a router Continuum can
  drive is marked, so a Mac cabled to its ISP gateway and on the router's Wi-Fi
  binds the router, not the gateway. The typed Wi-Fi join (`w`, name, `o`) is
  gone.
- **Pick the Meta model from the key's own catalog**, with Meta's rate card and
  the most one setup step can cost at each reasoning effort. Spark 1.3 at xhigh
  is preselected.
- The Meta key is saved in the macOS Keychain on `Enter` (`n` keeps it for the
  session only), so the next run needs no key.

### Install

- One line, no checkout or build:
  `curl -fsSL https://github.com/AdityaVG13/Continuum/releases/latest/download/install.sh | sh`
  installs `continuum` into `/usr/local/bin` (prompts and schemas in
  `/usr/local/share/continuum`) after checking the archive's SHA-256.

## [0.1.0] - 2026-11-04

First release. Continuum is an owner-controlled management plane for a router
the owner physically holds: Meta proposes and explains, the product admits or
refuses, and every effect is typed, reversible and recorded.

### What is in it

- **Owner-selected device lifecycle.** Discovery reads this host only. Selection
  binds one observed target; inspection, authorization, enrollment, commissioning,
  runtime qualification, restore and reboot are separate, separately approved
  steps. Standing device permission never authorizes a reboot.
- **Factory enrollment that creates its own credential.** A factory-reset unit has
  no admin password. `enroll` generates the admin credential and PSK, stages them
  in the OS credential vault before the first write, submits the vendor first-run
  form, and proves a protected read under the new credential. A bare `enroll`
  without `--execute` is refused; a retry inspects and never replays the form.
- **Protected commissioning.** Typed `apply`/`restore` over the vendor's own web
  form plus a bounded SSH channel, with before/after receipts, an independent
  readback, a durable before-image, and refusal on drift.
- **Real traffic control, gated.** Read-only `qos-status` preflight; bounded CAKE
  profiles applied and independently read back, with typed refusal when `tc` is
  absent, the root qdisc is vendor-managed, the profile is out of bounds, or the
  device does not honor the requested rate.
- **Evidence instead of adjectives.** `--measure` samples idle and loaded HTTP
  RTT and goodput and refuses to certify a run it did not sample; `--upload` is
  the load direction a router's egress shaping can influence.
- **Continuity.** Completed work is committed atomically and recovered from its
  exact inputs; uncertain external effects are not replayed.
- **A five-section TUI** for the owner: device, model, network, permissions and
  results, with every disruptive step behind an explicit confirmation.

### What is not proven

- No physical-router run yet in this release. Every router-facing capability is
  proven against the C++ double and a modeled firmware shell; latency, goodput
  and "faster" claims remain absent until a physical run is recorded.
- The binary reads its prompts and schemas relative to the working directory, so
  an install must carry them and run from its install root.
