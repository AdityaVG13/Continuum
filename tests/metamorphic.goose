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

    print("METAMORPHIC_ALL_GREEN");
}
