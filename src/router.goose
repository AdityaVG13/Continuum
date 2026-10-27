// Simulated stock router: the test-environment stand-in for a real admin
// API. It models the parts that matter for the contracts above it --
// session auth, a fixed knob set gated by the profile's capabilities,
// readback, and reboot dropping the session -- with zero network I/O.
// The real WebApi/Ssh backends implement this same surface later; the
// guardian still gates every mutation before a knob is touched.
import .contracts;
import .sim;
import std;
namespace continuum;

struct SimRouter {
    session: bool = false,
    qos_on: bool = false,
    channel: i64 = 6,
    dns_mode: u8[..64] = "isp",
    clients: i64 = 3,
    revision: i64 = 1,
}

var sim_router: SimRouter = SimRouter {};

fn router_profile() -> RouterProfile {
    return RouterProfile {
        router_id: "sim-router-0",
        vendor: "Continuum",
        model: "SimRouter",
        firmware: "1.0-sim",
        access_kind: AccessKind.Sim,
        endpoint: "sim://router0",
        credential_ref: "SIM_ROUTER_PASSWORD",
        scope_id: "lab-sim",
        path_id: "sim0",
        can_qos: true,
        can_priority_device: true,
        can_reboot: true,
        can_dns: true,
        can_channel: true,
        can_client_list: true,
        config_revision: sim_router.revision,
        discovered: true,
    };
}

// A profile is usable only if discovery actually happened and the access
// path is real: network kinds need an endpoint, every kind needs a scope,
// a path, and a revision to conflict-check against.
fn router_profile_valid(p: RouterProfile) -> bool {
    if !p.discovered || p.router_id == "" || p.scope_id == "" || p.path_id == "" {
        return false;
    }
    if p.config_revision <= 0 || p.access_kind == AccessKind.Unset {
        return false;
    }
    if p.access_kind == AccessKind.WebApi || p.access_kind == AccessKind.Ssh
        || p.access_kind == AccessKind.Serial {
        return p.endpoint != "";
    }
    return p.endpoint != "";
}

// The sim password stands in for the keychain-held credential. A real
// backend reads the secret named by RouterProfile.credential_ref from the
// OS keychain; it never transits chat or the journal.
fn router_unlock(password: const u8[:]) -> bool {
    if password != "sim-password" {
        sim_router.session = false;
        return false;
    }
    sim_router.session = true;
    return true;
}

fn router_lock() {
    sim_router.session = false;
}

fn router_set_knob(name: const u8[:], value: const u8[:]) -> bool {
    if !sim_router.session {
        return false;
    }
    let p = router_profile();
    if name == "qos" {
        if !p.can_qos || (value != "on" && value != "off") {
            return false;
        }
        sim_router.qos_on = value == "on";
        return sim_apply(if sim_router.qos_on { "sqm-fair" } else { "baseline-fifo" });
    }
    if name == "channel" {
        if !p.can_channel {
            return false;
        }
        let v, ok = parse_int(value);
        if !ok || v < 1 || v > 165 {
            return false;
        }
        sim_router.channel = v;
        return true;
    }
    if name == "dns" {
        if !p.can_dns || (value != "isp" && value != "encrypted") {
            return false;
        }
        sim_router.dns_mode = value;
        return true;
    }
    return false;
}

fn router_get_knob(name: const u8[:]) -> u8[..64] {
    if !sim_router.session {
        return "";
    }
    if name == "qos" {
        return if sim_router.qos_on { "on" } else { "off" };
    }
    if name == "channel" {
        return str(sim_router.channel);
    }
    if name == "dns" {
        return sim_router.dns_mode;
    }
    return "";
}

// -1 (not 0) when the router cannot answer: absence is not an empty house.
fn router_clients() -> i64 {
    if !sim_router.session || !router_profile().can_client_list {
        return -1;
    }
    return sim_router.clients;
}

fn router_reboot() {
    sim_router.session = false;
    sim_router.revision += 1;
}
