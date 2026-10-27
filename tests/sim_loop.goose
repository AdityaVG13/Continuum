// Phase-1 contract tests: deterministic brain + simulated bottleneck.
// Failure-first: every check below was written to FAIL against the v3 stubs
// (missing modules, NotImplemented outcomes) and now guards the landed slice.
// Run: goose check tests/sim_loop.goose   (type gate)
//      goose run  tests/sim_loop.goose   (behavior gate, exit 0 = all green)
import lib from "../src";
import std;

fn check(cond: bool, label: const u8[:]) {
    if !cond {
        print("FAIL ", label);
        abort(str("sim_loop contract violated: ", label));
    }
    print("ok ", label);
}

fn near(a: f64, b: f64, tol: f64) -> bool { abs(a - b) <= tol }

fn bloated_obs() -> continuum::Observation {
    return continuum::Observation {
        observation_id: "obs-bloat-1",
        provenance: continuum::Provenance.Synthetic,
        path_id: "sim0",
        route_epoch: 3,
        observed_at_ms: 1000,
        window_ms: 500,
        attempts: 20,
        successes: 20,
        baseline_rtt_ms: 25.0,
        loaded_rtt_ms: 325.0,
        metrics_known: true,
    };
}

fn sqm_profile() -> continuum::ActionProfile {
    return continuum::ActionProfile {
        profile_id: "sqm-fair",
        scope_id: "lab-sim",
        path_id: "sim0",
        owned: true,
        configured_rate_kbit: 90000,
        maximum_lease_ms: 60000,
        revision: 7,
    };
}

fn main() {
    // --- brain: bloat detection ---
    check(continuum::bloat_detected(bloated_obs(), 100.0), "brain flags 300ms bloat");
    var healthy = bloated_obs();
    healthy.loaded_rtt_ms = 30.0;
    check(!continuum::bloat_detected(healthy, 100.0), "brain stays quiet when healthy");
    var unknown = bloated_obs();
    unknown.metrics_known = false;
    check(!continuum::bloat_detected(unknown, 100.0), "brain abstains without evidence");

    // --- sim: bloated by default, repairable by profile ---
    continuum::sim_reset(7);
    let before = continuum::sim_observe("sim0", 0);
    check(before.observation.metrics_known, "sim observation carries evidence");
    check(before.outcome.status == continuum::Status.Completed, "sim observation completes");
    check(before.observation.loaded_rtt_ms > 300.0, "sim bottleneck is bloated at rest");
    check(!continuum::sim_apply("no-such-profile"), "sim rejects unknown profile");
    check(continuum::sim_apply("sqm-fair"), "sim accepts the fair-queue profile");
    let after = continuum::sim_observe("sim0", 1);
    check(after.observation.loaded_rtt_ms < 60.0, "fair queue drains the load");
    check(continuum::improvement_ms(before.observation, after.observation) > 200.0,
        "improvement math matches the drop");

    // --- guardian: fail-closed admission ---
    continuum::sim_reset(7);
    let obs = continuum::sim_observe("sim0", 0).observation;
    let prof = sqm_profile();
    var req = continuum::propose_apply(obs, prof, 1200);
    let adm = continuum::admit_action(req, obs, prof, 1200);
    check(adm.outcome.status == continuum::Status.Completed && adm.admitted, "clean request admitted");
    let dup = continuum::admit_action(req, obs, prof, 1200);
    check(!dup.admitted, "duplicate request id rejected");
    var later = continuum::propose_apply(obs, prof, 1204);
    check(continuum::admit_action(later, obs, prof, 1204).admitted, "second distinct request admitted");
    check(!continuum::admit_action(req, obs, prof, 1205).admitted, "replayed older id rejected");
    var stale = obs;
    stale.observed_at_ms = 0;
    var req2 = continuum::propose_apply(stale, prof, 9000);
    check(!continuum::admit_action(req2, stale, prof, 9000).admitted, "stale evidence rejected");
    var wrong_scope = continuum::propose_apply(obs, prof, 1200);
    wrong_scope.scope_id = "someone-elses-router";
    check(!continuum::admit_action(wrong_scope, obs, prof, 1201).admitted, "foreign scope rejected");
    var bad_lease = continuum::propose_apply(obs, prof, 1200);
    bad_lease.lease_ms = 9999999;
    check(!continuum::admit_action(bad_lease, obs, prof, 1202).admitted, "over-long lease rejected");
    var unowned = prof;
    unowned.owned = false;
    var req3 = continuum::propose_apply(obs, unowned, 1200);
    check(!continuum::admit_action(req3, obs, unowned, 1203).admitted, "unowned profile rejected");

    // --- actuator + watchdog: apply, verify, expire, restore ---
    continuum::sim_reset(7);
    let o0 = continuum::sim_observe("sim0", 0).observation;
    var rq = continuum::propose_apply(o0, prof, 100);
    let ad = continuum::admit_action(rq, o0, prof, 100);
    let applied = continuum::apply_profile(rq, ad);
    check(applied.applied && applied.verification_complete, "apply reports verified state");
    check(near(continuum::sim_observe("sim0", 2).observation.loaded_rtt_ms, 37.0, 10.0),
        "readback shows the repaired queue");
    continuum::sim_advance_ms(70000);
    let expired = continuum::reconcile_expired_lease(applied.lease_id, continuum::sim_now_ms());
    check(expired.restored, "watchdog restores after lease expiry");
    check(continuum::sim_observe("sim0", 3).observation.loaded_rtt_ms > 300.0,
        "queue is bloated again after restore");

    // --- journal: ordered, one entry per beat ---
    let s0 = continuum::append_event(continuum::Event {
        event_type: "test-beat-1", run_id: "sim-test", timestamp_ms: 1,
        provenance: continuum::Provenance.Synthetic, payload_json: "{}",
    });
    let s1 = continuum::append_event(continuum::Event {
        event_type: "test-beat-2", run_id: "sim-test", timestamp_ms: 2,
        provenance: continuum::Provenance.Synthetic, payload_json: "{}",
    });
    check(s0.status == continuum::Status.Completed && s1.status == continuum::Status.Completed,
        "journal accepts beats");
    check(continuum::journal_len() >= 2
        && continuum::journal_seq(continuum::journal_len() - 1)
            == continuum::journal_seq(continuum::journal_len() - 2) + 1,
        "journal sequence is ordered");

    print("SIM_LOOP_ALL_GREEN");
}
