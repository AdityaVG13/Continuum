// The phase-1 brain: a deterministic policy, not a model. It decides one
// thing (is this queue bloated enough to touch?), builds the exact request
// the guardian must admit, and scores the outcome. The Meta controller seam
// (controller_tick) stays the decision-maker for live runs; this policy is
// the testable stand-in that proves the loop mechanics in the sim.
import .contracts;
import .sim;
import .controller;
import .events;
namespace continuum;

var request_counter: i64 = 0;

fn next_request_id() -> u8[..64] {
    request_counter += 1;
    return str("req-", request_counter);
}

// Bloat is loaded RTT clearly above baseline on real evidence. Unknown or
// empty measurements abstain: absence of data is never a healthy signal,
// and never grounds for action either.
fn bloat_detected(obs: Observation, threshold_ms: f64) -> bool {
    if !obs.metrics_known {
        return false;
    }
    if obs.attempts <= 0 || obs.successes <= 0 {
        return false;
    }
    return obs.loaded_rtt_ms - obs.baseline_rtt_ms > threshold_ms;
}

// Milliseconds of loaded-RTT drop between two observations (positive = fixed).
fn improvement_ms(before: Observation, after: Observation) -> f64 {
    return before.loaded_rtt_ms - after.loaded_rtt_ms;
}

fn propose_apply(obs: Observation, profile: ActionProfile, now_ms: i64) -> ActionRequest {
    let id = next_request_id();
    return ActionRequest {
        request_id: id,
        run_id: "sim-run",
        kind: ActionKind.ApplyProfile,
        profile_id: profile.profile_id,
        scope_id: profile.scope_id,
        path_id: profile.path_id,
        observation_id: obs.observation_id,
        task_revision: 1,
        config_revision: 1,
        expected_revision: profile.revision,
        route_epoch: obs.route_epoch,
        issued_at_ms: now_ms,
        expires_at_ms: now_ms + 10000,
        lease_ms: 10000,
        lease_id: id,
        rationale: "sim: drain bloated queue with fair profile",
    };
}

fn propose_restore(lease_id: const u8[:], scope_id: const u8[:], path_id: const u8[:],
                revision: i64, now_ms: i64) -> ActionRequest {
    let id = next_request_id();
    return ActionRequest {
        request_id: id,
        run_id: "sim-run",
        kind: ActionKind.RestoreProfile,
        scope_id: scope_id,
        path_id: path_id,
        expected_revision: revision,
        route_epoch: 3,
        issued_at_ms: now_ms,
        expires_at_ms: now_ms + 5000,
        lease_ms: 5000,
        lease_id: lease_id,
        rationale: "sim: restore owned baseline after verified repair",
    };
}

fn beat(event_type: const u8[:], payload: const u8[:]) {
    append_event(Event {
        event_type: event_type,
        run_id: "sim-run",
        timestamp_ms: sim_now_ms(),
        provenance: Provenance.Synthetic,
        payload_json: payload,
    });
}

fn fail_loop(reason: const u8[:]) -> Outcome {
    print("SIM-FAIL ", reason);
    return Outcome { status: Status.Failed, message: reason };
}

// One full observe -> decide -> admit -> apply -> verify -> restore ->
// verify-restoration pass over the sim, with a negative duplicate probe and
// an ordered-journal check. Deterministic: same seed, same transcript.
fn run_sim_loop() -> Outcome {
    sim_reset(7);
    let first = sim_observe("sim0", 0);
    if first.outcome.status != Status.Completed {
        return fail_loop("observation did not complete");
    }
    beat("observe", "bloated baseline window");
    let obs0 = first.observation;
    print("SIM OBSERVE loaded=", obs0.loaded_rtt_ms, " baseline=", obs0.baseline_rtt_ms);
    if !bloat_detected(obs0, 100.0) {
        return fail_loop("brain missed the resting bloat");
    }
    let catalogue = list_profiles("lab-sim");
    if catalogue.profiles.len < 2 {
        return fail_loop("catalogue did not list both sim profiles");
    }
    let fair = catalogue.profiles[1];
    print("SIM DECIDE bloat apply=", fair.profile_id, " lease=10000");
    beat("decide", "fair profile selected");

    let req = propose_apply(obs0, fair, sim_now_ms());
    let adm = admit_action(req, obs0, fair, sim_now_ms());
    if !adm.admitted {
        return fail_loop(str("clean request rejected: ", adm.outcome.message));
    }
    print("SIM ADMIT admitted action=", adm.action_id);
    let applied = apply_profile(req, adm);
    if !applied.applied || !applied.verification_complete {
        return fail_loop("apply did not verify");
    }
    print("SIM APPLY applied verified lease=", applied.lease_id);
    beat("apply", "fair profile active");

    sim_advance_ms(2000);
    let obs1 = sim_observe("sim0", 1).observation;
    let gain = improvement_ms(obs0, obs1);
    print("SIM VERIFY loaded=", obs1.loaded_rtt_ms, " improvement=", gain);
    if gain < 200.0 {
        return fail_loop("repair did not move loaded RTT");
    }
    beat("verify", "loaded RTT dropped");

    let req_r = propose_restore(applied.lease_id, fair.scope_id, fair.path_id,
        fair.revision, sim_now_ms());
    let obs_r = sim_observe("sim0", 2).observation;
    let adm_r = admit_action(req_r, obs_r, fair, sim_now_ms());
    if !adm_r.admitted {
        return fail_loop("clean restore rejected");
    }
    let restored = restore_profile(req_r, adm_r);
    if !restored.restored || !restored.verification_complete {
        return fail_loop("restore did not verify");
    }
    print("SIM RESTORE restored");
    beat("restore", "baseline profile active again");

    let obs2 = sim_observe("sim0", 3).observation;
    print("SIM VERIFY-RESTORE loaded=", obs2.loaded_rtt_ms);
    if obs2.loaded_rtt_ms < 300.0 {
        return fail_loop("queue not bloated after restore");
    }
    let dup = admit_action(req, obs2, fair, sim_now_ms());
    if dup.admitted {
        return fail_loop("duplicate request id admitted");
    }
    print("SIM NEGATIVE-DUP rejected");
    var ordered = true;
    for i in 1..journal_len() {
        if journal_seq(i) != journal_seq(i - 1) + 1 {
            ordered = false;
        }
    }
    if !ordered {
        return fail_loop("journal out of order");
    }
    print("SIM JOURNAL beats=", journal_len(), " ordered");
    beat("done", "loop green");
    print("SIM_LOOP_ALL_GREEN");
    return Outcome { status: Status.Completed, message: "sim loop green" };
}
