// Deterministic simulated bottleneck: the phase-1 stand-in for a real queue.
// A logical millisecond clock (no wall clock, no I/O) keeps every run
// bit-identical for a given seed. Two profiles: the bloated FIFO that ships
// with the sim, and the fair-queue profile the brain is allowed to apply.
// Provenance is always Synthetic: these numbers must never pose as live NIC
// measurements (contracts.goose: unset/zero is not evidence).
import .contracts;
import std;
import os;
namespace continuum;

struct SimWorld {
    now_ms: i64,
    applied_profile_id: u8[..64],
    baseline_rtt_ms: f64,
    route_epoch: i64,
    seed: u64,
    load_fraction: f64,
    loss_fraction: f64,
}

var sim_world: SimWorld = SimWorld {
    now_ms: 0,
    applied_profile_id: "baseline-fifo",
    baseline_rtt_ms: 25.0,
    route_epoch: 3,
    seed: 1,
    load_fraction: 1.0,
    loss_fraction: 0.0,
};

// Queueing delay under the current offered load. FIFO: delay grows with
// the square of load (a deep dumb queue filling up). Fair queue: the
// interactive flow is isolated, so delay stays near the floor until the
// link is past saturation. Unknown profiles report -1 (known-check fails).
// Shape validated against real veth+TBF measurements on 2026-10-26
// (lab/results/2026-10-26-notes.md): FIFO ~1000x inflation at saturation,
// fq_codel ~10x. Absolute scale is home-router domain (25ms baseline), and
// the quadratic acts earlier than a real FIFO (conservative by design).
fn sim_queue_delay_ms(profile_id: const u8[:]) -> f64 {
    let load = sim_world.load_fraction;
    if profile_id == "baseline-fifo" {
        return 320.0 * load * load;
    }
    if profile_id == "sqm-fair" {
        var delay = 12.0 * min(load, 1.0);
        if load > 1.0 {
            delay += 40.0 * (load - 1.0);
        }
        return delay;
    }
    return -1.0;
}

fn sim_profile_known(profile_id: const u8[:]) -> bool {
    return sim_queue_delay_ms(profile_id) >= 0.0;
}

fn sim_reset(seed: u64) {
    sim_world.now_ms = 0;
    sim_world.applied_profile_id = "baseline-fifo";
    sim_world.route_epoch = 3;
    sim_world.seed = seed;
    sim_world.load_fraction = 1.0;
    sim_world.loss_fraction = 0.0;
}

// Scenario controls: offered load (1.0 = link saturation) and loss. These
// are the knobs a scenario script turns; the queue model does the rest.
fn sim_set_load(fraction: f64) {
    if fraction < 0.0 {
        sim_world.load_fraction = 0.0;
        return;
    }
    sim_world.load_fraction = fraction;
}

fn sim_set_loss(fraction: f64) {
    if fraction < 0.0 {
        sim_world.loss_fraction = 0.0;
        return;
    }
    if fraction > 1.0 {
        sim_world.loss_fraction = 1.0;
        return;
    }
    sim_world.loss_fraction = fraction;
}

// A route change invalidates every baseline taken before it: the epoch is
// how observers and the guardian notice.
fn sim_route_change() {
    sim_world.route_epoch += 1;
}

fn sim_now_ms() -> i64 {
    return sim_world.now_ms;
}

fn sim_advance_ms(dt: i64) {
    if dt > 0 {
        sim_world.now_ms += dt;
    }
}

fn sim_apply(profile_id: const u8[:]) -> bool {
    if !sim_profile_known(profile_id) {
        return false;
    }
    sim_world.applied_profile_id = profile_id;
    return true;
}

fn sim_current_profile_id() -> u8[..64] {
    return sim_world.applied_profile_id;
}

// Catalogue behind list_profiles: the only profiles the sim will honor.
fn sim_profile_count() -> i64 {
    return 2;
}

fn sim_profile(slot: i64) -> ActionProfile {
    if slot == 1 {
        return ActionProfile {
            profile_id: "sqm-fair",
            scope_id: "lab-sim",
            path_id: "sim0",
            owned: true,
            configured_rate_kbit: 90000,
            maximum_lease_ms: 60000,
            revision: 7,
        };
    }
    return ActionProfile {
        profile_id: "baseline-fifo",
        scope_id: "lab-sim",
        path_id: "sim0",
        owned: true,
        configured_rate_kbit: 100000,
        maximum_lease_ms: 60000,
        revision: 7,
    };
}

// One observation window: baseline + profile queueing + deterministic jitter.
// Jitter derives from (seed, sample) only, so reruns are identical.
fn sim_observe(path_id: const u8[:], sample: i64) -> ObservationResult {
    let delay = sim_queue_delay_ms(sim_world.applied_profile_id);
    let h = hash(sim_world.seed + sample as! u64);
    let jitter = (h % 4000) as! f64 / 1000.0 - 2.0;
    let loaded = sim_world.baseline_rtt_ms + delay + jitter;
    let lost = (20.0 * sim_world.loss_fraction) as i64;
    return ObservationResult {
        outcome: Outcome { status: Status.Completed, message: "sim window" },
        observation: Observation {
            observation_id: "sim-obs",
            provenance: Provenance.Synthetic,
            path_id: path_id,
            route_epoch: sim_world.route_epoch,
            observed_at_ms: sim_world.now_ms,
            window_ms: 500,
            attempts: 20,
            successes: 20 - lost,
            baseline_rtt_ms: sim_world.baseline_rtt_ms,
            loaded_rtt_ms: loaded,
            gateway_rtt_ms: sim_world.baseline_rtt_ms / 2.0,
            application_echo_ms: loaded,
            utilization: min(sim_world.load_fraction, 1.0),
            loss_fraction: sim_world.loss_fraction,
            metrics_known: true,
        },
    };
}

// Durable sim state: one key=value per line, atomically replaced. This is
// what survives a controller crash in the test environment; the lease file
// (store.goose) says why the world looks this way.
fn sim_save(path: const u8[:]) -> bool {
    let text = str("now=", sim_world.now_ms,
        "\nprofile=", sim_world.applied_profile_id,
        "\nbaseline=", sim_world.baseline_rtt_ms,
        "\nepoch=", sim_world.route_epoch,
        "\nseed=", sim_world.seed as i64,
        "\nload=", sim_world.load_fraction,
        "\nloss=", sim_world.loss_fraction, "\n");
    return write_file_atomic(path, text);
}

fn sim_load(path: const u8[:]) -> bool {
    var text: u8[>..] = [];
    guard read_file(path, text) else { return false; }
    var found = false;
    each_split(text, '\n') {
        let eq = find(it, "=");
        if eq > 0 {
            let key = it[..eq];
            let val = it[eq + 1..];
            if key == "now" {
                let v, ok = parse_int(val);
                if ok { sim_world.now_ms = v; found = true; }
            } else if key == "profile" {
                // Mirror sim_apply: never install a profile the sim will
                // not honor. Unknown names keep the current profile.
                if sim_profile_known(val) {
                    sim_world.applied_profile_id = val;
                }
            } else if key == "baseline" {
                let v, ok = parse_flt(val);
                if ok { sim_world.baseline_rtt_ms = v; }
            } else if key == "epoch" {
                let v, ok = parse_int(val);
                if ok { sim_world.route_epoch = v; }
            } else if key == "seed" {
                let v, ok = parse_int(val);
                if ok { sim_world.seed = v as! u64; }
            } else if key == "load" {
                // Mirror sim_set_load: floor negatives, keep super-unity
                // saturation (that is what the knob is for).
                let v, ok = parse_flt(val);
                if ok {
                    if v < 0.0 { sim_world.load_fraction = 0.0; }
                    else { sim_world.load_fraction = v; }
                }
            } else if key == "loss" {
                // Mirror sim_set_loss: loss lives in [0, 1].
                let v, ok = parse_flt(val);
                if ok {
                    if v < 0.0 { sim_world.loss_fraction = 0.0; }
                    else if v > 1.0 { sim_world.loss_fraction = 1.0; }
                    else { sim_world.loss_fraction = v; }
                }
            }
        }
    };
    return found;
}
