// Item 3: metamorphic properties. Failure-first: written to FAIL until the
// properties held against the real loop; now guards them.
// Run: goose run tests/metamorphic.goose   (exit 0 = all green)
import lib from "../src";
import std;
import os;

fn check(cond: bool, label: const u8[:]) {
    if !cond {
        print("FAIL ", label);
        abort(str("metamorphic violated: ", label));
    }
    print("ok ", label);
}

fn main() {
    // Apply -> restore returns the exact prior state, and the lease is gone.
    continuum::sim_reset(21);
    let obs = continuum::sim_observe("sim0", 0).observation;
    let fair = continuum::sim_profile(1);
    let req = continuum::propose_apply(obs, fair, 0);
    let adm = continuum::admit_action(req, obs, fair, 0);
    check(adm.admitted, "metamorphic apply admitted");
    let ap = continuum::apply_profile(req, adm);
    check(ap.applied, "metamorphic apply applied");
    check(continuum::sim_current_profile_id() == "sqm-fair", "fair active mid-lease");
    let req_r = continuum::propose_restore(ap.lease_id, fair.scope_id, fair.path_id,
        fair.revision, 1000);
    let obs_r = continuum::sim_observe("sim0", 1).observation;
    let adm_r = continuum::admit_action(req_r, obs_r, fair, 1000);
    check(adm_r.admitted, "metamorphic restore admitted");
    let rs = continuum::restore_profile(req_r, adm_r);
    check(rs.restored, "metamorphic restore restored");
    check(continuum::sim_current_profile_id() == "baseline-fifo", "state identical after restore");
    let dup = continuum::restore_profile(req_r, adm_r);
    check(!dup.restored, "double restore rejected");

    // Re-apply with a fresh id works; replaying an old id never does.
    let req2 = continuum::propose_apply(obs_r, fair, 2000);
    let adm2 = continuum::admit_action(req2, obs_r, fair, 2000);
    check(adm2.admitted, "fresh re-apply admitted");
    let ap2 = continuum::apply_profile(req2, adm2);
    check(ap2.applied, "fresh re-apply applied");
    let replay = continuum::admit_action(req, obs_r, fair, 2000);
    check(!replay.admitted, "replayed request id rejected");
    // Close the second lease too: the daemon below must meet a clean world.
    let req_r2 = continuum::propose_restore(ap2.lease_id, fair.scope_id,
        fair.path_id, fair.revision, 3000);
    let obs_r2 = continuum::sim_observe("sim0", 2).observation;
    let adm_r2 = continuum::admit_action(req_r2, obs_r2, fair, 3000);
    check(adm_r2.admitted, "second restore admitted");
    let rs2 = continuum::restore_profile(req_r2, adm_r2);
    check(rs2.restored && continuum::sim_current_profile_id() == "baseline-fifo",
        "second full cycle returns to baseline");

    // No dangling lease: two full daemon runs, both end clean.
    let d1 = continuum::run_daemon(12);
    check(d1.applies == 1 && d1.restores == 1 && d1.escalations == 0
            && continuum::sim_current_profile_id() == "baseline-fifo",
        "first daemon run applies, verifies, restores");
    let d2 = continuum::run_daemon(12);
    check(d2.applies == d1.applies && d2.restores == d1.restores
            && d2.escalations == d1.escalations,
        "daemon deterministic across runs");

    // Lease file roundtrip, including a torn write.
    let dir = ".build/metamorphic-test";
    make_dir(dir);
    let lease_path = ".build/metamorphic-test/lease.txt";
    delete_file(lease_path);
    check(continuum::lease_save(lease_path, "l-1", "sqm-fair", "baseline-fifo", 7, 99999),
        "lease saves");
    let loaded = continuum::lease_load(lease_path);
    check(loaded.found && loaded.lease_id == "l-1" && loaded.expires_at_ms == 99999,
        "lease roundtrips");
    check(continuum::lease_clear(lease_path), "lease clears");
    check(!continuum::lease_load(lease_path).found, "cleared lease not found");
    var torn: u8[>..] = [];
    torn.append("lease=l-2\nprofile=");
    write_file(lease_path, torn);
    check(!continuum::lease_load(lease_path).found, "torn lease fails closed");
    delete_file(lease_path);

    // MR-LOAD-PERM: load-schedule permutation preserves daemon apply/restore
    // counts. Same multiset of loads, opposite orderings, fresh state per
    // trial (sim_reset isolates ordering from state carryover): the decision
    // multiset must be identical. Threshold 100ms; FIFO delay = 320*L^2, so
    // only 0.7 (156.8ms) and 1.0 (320ms) exceed it; jitter is +/-2ms.
    var perm_applies_a = 0;
    var perm_restores_a = 0;
    continuum::sim_reset(41);
    continuum::sim_set_load(0.1);
    let pa1 = continuum::sim_observe("sim0", 5);
    if continuum::daemon_decide(pa1.observation, false, false, true, pa1.observation.route_epoch) == continuum::Decision.Apply { perm_applies_a += 1; }
    if continuum::daemon_decide(pa1.observation, true, true, true, pa1.observation.route_epoch) == continuum::Decision.Restore { perm_restores_a += 1; }
    continuum::sim_reset(41);
    continuum::sim_set_load(0.3);
    let pa2 = continuum::sim_observe("sim0", 5);
    if continuum::daemon_decide(pa2.observation, false, false, true, pa2.observation.route_epoch) == continuum::Decision.Apply { perm_applies_a += 1; }
    if continuum::daemon_decide(pa2.observation, true, true, true, pa2.observation.route_epoch) == continuum::Decision.Restore { perm_restores_a += 1; }
    continuum::sim_reset(41);
    continuum::sim_set_load(0.5);
    let pa3 = continuum::sim_observe("sim0", 5);
    if continuum::daemon_decide(pa3.observation, false, false, true, pa3.observation.route_epoch) == continuum::Decision.Apply { perm_applies_a += 1; }
    if continuum::daemon_decide(pa3.observation, true, true, true, pa3.observation.route_epoch) == continuum::Decision.Restore { perm_restores_a += 1; }
    continuum::sim_reset(41);
    continuum::sim_set_load(0.7);
    let pa4 = continuum::sim_observe("sim0", 5);
    if continuum::daemon_decide(pa4.observation, false, false, true, pa4.observation.route_epoch) == continuum::Decision.Apply { perm_applies_a += 1; }
    if continuum::daemon_decide(pa4.observation, true, true, true, pa4.observation.route_epoch) == continuum::Decision.Restore { perm_restores_a += 1; }
    continuum::sim_reset(41);
    continuum::sim_set_load(1.0);
    let pa5 = continuum::sim_observe("sim0", 5);
    if continuum::daemon_decide(pa5.observation, false, false, true, pa5.observation.route_epoch) == continuum::Decision.Apply { perm_applies_a += 1; }
    if continuum::daemon_decide(pa5.observation, true, true, true, pa5.observation.route_epoch) == continuum::Decision.Restore { perm_restores_a += 1; }
    // Order B: 1.0 -> 0.7 -> 0.5 -> 0.3 -> 0.1 (same multiset, reversed).
    var perm_applies_b = 0;
    var perm_restores_b = 0;
    continuum::sim_reset(41);
    continuum::sim_set_load(1.0);
    let pb1 = continuum::sim_observe("sim0", 5);
    if continuum::daemon_decide(pb1.observation, false, false, true, pb1.observation.route_epoch) == continuum::Decision.Apply { perm_applies_b += 1; }
    if continuum::daemon_decide(pb1.observation, true, true, true, pb1.observation.route_epoch) == continuum::Decision.Restore { perm_restores_b += 1; }
    continuum::sim_reset(41);
    continuum::sim_set_load(0.7);
    let pb2 = continuum::sim_observe("sim0", 5);
    if continuum::daemon_decide(pb2.observation, false, false, true, pb2.observation.route_epoch) == continuum::Decision.Apply { perm_applies_b += 1; }
    if continuum::daemon_decide(pb2.observation, true, true, true, pb2.observation.route_epoch) == continuum::Decision.Restore { perm_restores_b += 1; }
    continuum::sim_reset(41);
    continuum::sim_set_load(0.5);
    let pb3 = continuum::sim_observe("sim0", 5);
    if continuum::daemon_decide(pb3.observation, false, false, true, pb3.observation.route_epoch) == continuum::Decision.Apply { perm_applies_b += 1; }
    if continuum::daemon_decide(pb3.observation, true, true, true, pb3.observation.route_epoch) == continuum::Decision.Restore { perm_restores_b += 1; }
    continuum::sim_reset(41);
    continuum::sim_set_load(0.3);
    let pb4 = continuum::sim_observe("sim0", 5);
    if continuum::daemon_decide(pb4.observation, false, false, true, pb4.observation.route_epoch) == continuum::Decision.Apply { perm_applies_b += 1; }
    if continuum::daemon_decide(pb4.observation, true, true, true, pb4.observation.route_epoch) == continuum::Decision.Restore { perm_restores_b += 1; }
    continuum::sim_reset(41);
    continuum::sim_set_load(0.1);
    let pb5 = continuum::sim_observe("sim0", 5);
    if continuum::daemon_decide(pb5.observation, false, false, true, pb5.observation.route_epoch) == continuum::Decision.Apply { perm_applies_b += 1; }
    if continuum::daemon_decide(pb5.observation, true, true, true, pb5.observation.route_epoch) == continuum::Decision.Restore { perm_restores_b += 1; }
    check(perm_applies_a == 2 && perm_applies_b == 2, "mr load-perm applies pinned at two");
    check(perm_applies_a == perm_applies_b, "mr load-perm applies order-invariant");
    check(perm_restores_a == 5 && perm_restores_b == 5, "mr load-perm restores pinned at five");
    check(perm_restores_a == perm_restores_b, "mr load-perm restores order-invariant");

    // MR-SHIFT: sample-shift preserves bloat ordering. Jitter derives from
    // (seed, sample) at +/-2ms; the bloated/healthy gap is ~300ms, so verdicts
    // and the bloated-above-healthy ordering must survive an index shift.
    continuum::sim_reset(55);
    continuum::sim_set_load(1.0);
    let sh_b0 = continuum::sim_observe("sim0", 0).observation;
    let sh_b1 = continuum::sim_observe("sim0", 7).observation;
    check(continuum::bloat_detected(sh_b0, 100.0), "mr shift bloated sample 0 flags");
    check(continuum::bloat_detected(sh_b1, 100.0), "mr shift bloated sample 7 flags");
    check(continuum::sim_apply("sqm-fair"), "mr shift fair profile applies");
    let sh_h0 = continuum::sim_observe("sim0", 0).observation;
    let sh_h1 = continuum::sim_observe("sim0", 7).observation;
    check(!continuum::bloat_detected(sh_h0, 100.0), "mr shift healthy sample 0 quiet");
    check(!continuum::bloat_detected(sh_h1, 100.0), "mr shift healthy sample 7 quiet");
    check(sh_b0.loaded_rtt_ms > sh_h0.loaded_rtt_ms && sh_b1.loaded_rtt_ms > sh_h1.loaded_rtt_ms,
        "mr shift bloat ordering preserved same-sample");
    check(sh_b0.loaded_rtt_ms > sh_h1.loaded_rtt_ms && sh_b1.loaded_rtt_ms > sh_h0.loaded_rtt_ms,
        "mr shift bloat ordering preserved cross-sample");

    // MR-ID-SPACE: N distinct timestamps => N distinct pairwise-once ids.
    // Goes beyond the 2-id duplicate check in sim_loop.goose:77-81: four fresh
    // propose_apply calls at four timestamps must yield four pairwise-distinct
    // ids, each admitted exactly once and rejected on replay. Clock jumps past
    // the 60s admission window first so prior applies cannot trip the rate cap.
    continuum::sim_reset(77);
    continuum::sim_advance_ms(70000);
    let mobs = continuum::sim_observe("sim0", 9).observation;
    let mfair = continuum::sim_profile(1);
    var q1 = continuum::propose_apply(mobs, mfair, 70100);
    var q2 = continuum::propose_apply(mobs, mfair, 70200);
    var q3 = continuum::propose_apply(mobs, mfair, 70300);
    var q4 = continuum::propose_apply(mobs, mfair, 70400);
    check(q1.request_id != q2.request_id, "mr ids 1-2 distinct");
    check(q1.request_id != q3.request_id, "mr ids 1-3 distinct");
    check(q1.request_id != q4.request_id, "mr ids 1-4 distinct");
    check(q2.request_id != q3.request_id, "mr ids 2-3 distinct");
    check(q2.request_id != q4.request_id, "mr ids 2-4 distinct");
    check(q3.request_id != q4.request_id, "mr ids 3-4 distinct");
    check(continuum::admit_action(q1, mobs, mfair, 70100).admitted, "mr id 1 admitted once");
    check(continuum::admit_action(q2, mobs, mfair, 70200).admitted, "mr id 2 admitted once");
    check(continuum::admit_action(q3, mobs, mfair, 70300).admitted, "mr id 3 admitted once");
    check(continuum::admit_action(q4, mobs, mfair, 70400).admitted, "mr id 4 admitted once");
    check(!continuum::admit_action(q1, mobs, mfair, 70101).admitted, "mr id 1 replay rejected");
    check(!continuum::admit_action(q2, mobs, mfair, 70201).admitted, "mr id 2 replay rejected");
    check(!continuum::admit_action(q3, mobs, mfair, 70301).admitted, "mr id 3 replay rejected");
    check(!continuum::admit_action(q4, mobs, mfair, 70401).admitted, "mr id 4 replay rejected");

    print("METAMORPHIC_ALL_GREEN");
}
