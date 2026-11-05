# Changelog

All notable changes to Continuum. This project is pre-1.0: surfaces change, and
a capability listed here is listed with its evidence in `docs/STATUS.md`.

## [0.2.9] - 2026-11-04

- **No login attempts with an old password on a reset router.** An ASUS counts
  refused logins and, after two, refuses even the correct password for a few
  minutes (its login page showed `error_status 10` with a `lock_time`).
  Continuum tried the pre-reset password at launch and again before enrolling,
  so the new password set during step 2 was refused (`rotate failed: refused`).
  Every router check now first asks whether the router is still in its
  first-run state, which needs no login, and skips the login if it is. The
  login proofs during step 2 also wait out a lock (up to ~5 minutes) instead of
  giving up after 6 seconds.

## [0.2.8] - 2026-11-04

- **A router reset since the last run is caught at launch.** The wizard used to
  resume at the saved step (the Meta key) for a router that had been
  factory-reset, and only found out at Meta's step. Launch now makes one
  read-only check with the saved admin password; if the router refuses it,
  Continuum says the router was reset and starts over at step 2. Nothing is
  written to the router.

## [0.2.7] - 2026-11-04

- **Enrollment no longer gives up on the first refused login after the Wi-Fi
  rename.** On a GT-AX11000 the first check of the new admin password, right
  after the Mac rejoined the renamed Wi-Fi, was refused; the same password
  worked minutes later with nothing changed. Continuum reported
  `AdminAuthFailed` and told the owner to paperclip-reset. It now keeps
  checking for up to 5 minutes before concluding the password was refused.

## [0.2.6] - 2026-11-04

- Relaunching after an interrupted enrollment retries it as is (rejoining the
  renamed Wi-Fi first) instead of re-binding, which reset the phase and lost
  that rejoin.
- "Router not in reach" says what to do (connect by cable or Wi-Fi, then
  Enter) instead of naming panel keys.

## [0.2.5] - 2026-11-04

- **Setup no longer meets a restarting SSH daemon mid-apply.** The recovery
  drill puts SSH back to its original setting and the apply turns it on again;
  the read right after that now gets the same bounded wait-and-retry as the
  first one. The host-side SSH guard allows 300 s (was 120 s), longer than a
  worst-case apply.
- An apply that failed before writing its recovery baseline (so before any
  router write) leaves the router enrolled, so the next try is not refused
  with `reconcile_existing_baseline_before_apply`. After a restore, Meta is
  told to apply again in the same run instead of stopping.
- **A router reset after enrollment is recognized.** A step that finds the
  saved admin password refused says the router was probably reset, and Enter
  starts over at step 2 (over Wi-Fi or a cable). Meta is not called against a
  router that refuses the password.
- **The reboot step rejoins the router's Wi-Fi.** After the reboot macOS left
  Wi-Fi unassociated (seen live), so the wait never ended. While waiting, a
  host that has lost its address on the router's link rejoins the renamed
  Wi-Fi; the protected read afterwards is still the proof.
- Meta's setup brief: disable optional services that serve nothing (no
  running process, not protected by owner policy) and keep the rest. Live on
  the GT-AX11000: Samba and DLNA off, `changed_services=2`, runtime, recovery
  and (after the reboot) persistence verified by the router.
- Step 4's result shows the router's receipt first, then Meta's report cut
  at a line end, never starting mid-sentence.
- Step 7 names a firmware without CAKE (`qdisc_cake_unavailable`; the stock
  GT-AX11000 `tc` answers `Unknown qdisc "cake"`) instead of
  `ssh_program_exit_1`. Nothing is written in that case.

## [0.2.4] - 2026-11-04

- The SSH retry is bounded to 30 s and only covers failures before the
  password reached the router (refused, timed out, unroutable, closed before
  the prompt). It can no longer outlast the router-side SSH guard (120 s) or
  turn a wrong password into repeated login failures.
- The installer's "older copy on PATH" warning no longer runs `continuum`
  by accident (an unquoted backtick in 0.2.0-0.2.3).

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
