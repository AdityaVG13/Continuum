// The onboarding control-channel planner (C19/C20 prototype logic).
//
// Delegate setup mutates the very network it is reached through: a first
// setup renames the radio and rotates the admin credential. Users' setups
// vary wildly -- a wired bench, a router behind another network, a second
// bound device, or (the common case) a laptop whose only path to the
// router rides the Wi-Fi being renamed. So no topology is assumed here:
// discovery produces whatever control paths actually exist, and this
// module decides the strategy in one pure function, like daemon_decide.
//
// plan_leap's rules, in order:
// - A reachable path that does not ride the target Wi-Fi survives the
//   rename (wired LAN, an upstream SSID, another bound device). It always
//   outranks a leap, whatever order discovery reported them in.
// - Otherwise setup is a same-link leap: disconnect is expected, not an
//   error. The leap is admissible only if the new SSID/PSK and the admin
//   credential were staged durably BEFORE the write, so the machine knows
//   exactly what to rejoin and how to authenticate when the link returns.
// - No strategy may mutate before the admin credential is staged: the
//   first write must never guess a password (ONBOARDING sec. 7 step 0).
// - Nothing reachable at all is NoPath: report what to check, never act.
//
// classify_leap names the post-leap outcome from what the radio actually
// shows, so recovery is a decision table. On a Class B device (single
// admin, e.g. stock ASUSWRT) staged-credential divergence has exactly one
// recovery -- the physical factory reset -- and leap_needs_physical_reset
// says so honestly instead of letting a caller retry guesses.
//
// No secrets live in these records: StagedSetup names credential refs
// (OS-keychain slots), following RouterProfile.credential_ref. This module
// plans; discovery, OS rejoin, and the device backend execute.
import .contracts;
namespace continuum;

enum PathKind { Unset, Wired, Wifi, OtherDevice }
enum LeapStrategy { Unset, NoPath, SurvivingPath, SameLinkLeap }
enum LeapOutcome { Unset, Verified, NotApplied, CredentialMismatch, AdminAuthFailed, Unreachable }

// One discovered way to reach the target router. `bind_addr` is the local
// interface address the backend must bind requests to, so router traffic
// never leaks out a different interface's default route on a multihomed
// host. `rides_target_wifi` means applying setup drops this very path.
struct ControlPath {
    path_id: u8[..64] = "",
    kind: PathKind = PathKind.Unset,
    interface_id: u8[..64] = "",
    bind_addr: u8[..64] = "",
    endpoint: u8[..256] = "",
    rides_target_wifi: bool = false,
    reachable: bool = false,
}

struct ControlPaths {
    items: ControlPath[..8] = [],
}

// The intended post-setup state, written ahead of any device mutation.
// `staged` asserts the refs were durably recorded by the host (keychain);
// the planner trusts the assertion exactly as far as the caller that set
// it -- a host that stages in memory only must not set it.
struct StagedSetup {
    staged: bool = false,
    old_ssid: u8[..64] = "",
    new_ssid: u8[..64] = "",
    psk_ref: u8[..64] = "",
    admin_ref: u8[..64] = "",
}

struct LeapPlan {
    strategy: LeapStrategy = LeapStrategy.Unset,
    admissible: bool = false,
    reason: u8[..256] = "",
    control_path_id: u8[..64] = "",
    bind_addr: u8[..64] = "",
    expects_disconnect: bool = false,
    requires_staging: bool = false,
    rejoin_ssid: u8[..64] = "",
    fallback_ssid: u8[..64] = "",
}

fn plan_leap(paths: ControlPaths, setup: StagedSetup) -> LeapPlan {
    let admin_staged = setup.staged && setup.admin_ref != "";
    let leap_staged = admin_staged && setup.new_ssid != "" && setup.psk_ref != "";
    for p in paths.items {
        if p.reachable && !p.rides_target_wifi {
            return LeapPlan {
                strategy: LeapStrategy.SurvivingPath,
                admissible: admin_staged,
                reason: if admin_staged { "" }
                    else { "admin credential must be staged before the first write" },
                control_path_id: p.path_id,
                bind_addr: p.bind_addr,
                requires_staging: !admin_staged,
            };
        }
    }
    for p in paths.items {
        if p.reachable && p.rides_target_wifi {
            return LeapPlan {
                strategy: LeapStrategy.SameLinkLeap,
                admissible: leap_staged,
                reason: if leap_staged { "" }
                    else { "same-link leap needs staged ssid, psk and admin credential" },
                control_path_id: p.path_id,
                bind_addr: p.bind_addr,
                expects_disconnect: true,
                requires_staging: !leap_staged,
                rejoin_ssid: setup.new_ssid,
                fallback_ssid: setup.old_ssid,
            };
        }
    }
    return LeapPlan {
        strategy: LeapStrategy.NoPath,
        reason: "no reachable control path; check power, proximity and radio state",
    };
}

// Post-leap truth comes from the radio, in this order: a verified join
// outranks everything (multi-band routers rename per band, so the old
// SSID may still be visible on another band); a visible-but-unjoinable
// new SSID indicts the staged PSK; old-SSID-only means setup never
// applied and a retry is safe; neither is an outage, not a verdict.
fn classify_leap(new_ssid_seen: bool, old_ssid_seen: bool,
                 joined_new: bool, admin_auth_ok: bool) -> LeapOutcome {
    if joined_new {
        return if admin_auth_ok { LeapOutcome.Verified }
            else { LeapOutcome.AdminAuthFailed };
    }
    if new_ssid_seen {
        return LeapOutcome.CredentialMismatch;
    }
    if old_ssid_seen {
        return LeapOutcome.NotApplied;
    }
    return LeapOutcome.Unreachable;
}

// The Class B honesty bound: when the device took our setup but rejects
// the exact staged credentials, no software path back exists -- the
// supported recovery is the physical factory reset, after which the
// whole Delegate run must be re-runnable from factory.
fn leap_needs_physical_reset(outcome: LeapOutcome) -> bool {
    match outcome {
        CredentialMismatch => true, AdminAuthFailed => true,
        Unset => false, Verified => false, NotApplied => false, Unreachable => false,
    }
}
