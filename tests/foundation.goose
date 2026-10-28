// Foundation contract tests: scenarios, decision table, router-profile
// contract, onboarding control-channel planner, durable lease/journal
// persistence, crash recovery, daemon loop.
// Failure-first: written to FAIL until the foundation modules landed; now guards them.
// Run: goose run tests/foundation.goose   (exit 0 = all green)
import lib from "../src";
import std;
import os;

fn check(cond: bool, label: const u8[:]) {
    if !cond {
        print("FAIL ", label);
        abort(str("foundation contract violated: ", label));
    }
    print("ok ", label);
}

fn near(a: f64, b: f64, tol: f64) -> bool { abs(a - b) <= tol }

fn main() {
    let dir = ".build/foundation-test";
    make_dir(dir);
    let lease_path = ".build/foundation-test/lease.txt";
    let sim_path = ".build/foundation-test/sim.txt";
    let journal_path = ".build/foundation-test/journal.log";
    delete_file(lease_path);
    delete_file(sim_path);
    delete_file(journal_path);

    // --- scenarios: load drives the queue, fair profile isolates it ---
    continuum::sim_reset(11);
    continuum::sim_set_load(0.1);
    let low = continuum::sim_observe("sim0", 0).observation;
    check(low.loaded_rtt_ms < 60.0, "low load stays responsive on FIFO");
    continuum::sim_set_load(1.0);
    let high = continuum::sim_observe("sim0", 1).observation;
    check(high.loaded_rtt_ms > 300.0, "saturating load bloats FIFO");
    check(continuum::sim_apply("sqm-fair"), "fair profile applies under load");
    let fair = continuum::sim_observe("sim0", 2).observation;
    check(fair.loaded_rtt_ms < 60.0, "fair queue isolates interactive flow under load");
    continuum::sim_set_loss(0.5);
    let lossy = continuum::sim_observe("sim0", 3).observation;
    check(near(lossy.loss_fraction, 0.5, 0.01) && lossy.successes == 10,
        "loss scenario reaches the observation");
    let epoch_before = lossy.route_epoch;
    continuum::sim_route_change();
    check(continuum::sim_observe("sim0", 4).observation.route_epoch == epoch_before + 1,
        "route change bumps the epoch");

    // --- decision table: the daemon's whole policy in one function ---
    continuum::sim_reset(11);
    continuum::sim_set_load(1.0);
    let bloated = continuum::sim_observe("sim0", 0).observation;
    var unknown = bloated;
    unknown.metrics_known = false;
    check(continuum::daemon_decide(unknown, false, false, true, bloated.route_epoch)
            == continuum::Decision.Escalate,
        "unknown evidence escalates, never acts");
    check(continuum::daemon_decide(bloated, false, false, true, bloated.route_epoch + 9)
            == continuum::Decision.Escalate,
        "route epoch change escalates");
    check(continuum::daemon_decide(bloated, false, false, true, bloated.route_epoch)
            == continuum::Decision.Apply,
        "bloat without lease applies");
    check(continuum::daemon_decide(bloated, false, false, false, bloated.route_epoch)
            == continuum::Decision.Noop,
        "cooldown blocks a flap");
    check(continuum::daemon_decide(bloated, true, true, true, bloated.route_epoch)
            == continuum::Decision.Restore,
        "held lease restores after dwell");
    var healthy = bloated;
    healthy.loaded_rtt_ms = healthy.baseline_rtt_ms + 5.0;
    check(continuum::daemon_decide(healthy, false, false, true, healthy.route_epoch)
            == continuum::Decision.Noop,
        "healthy without lease does nothing");
    let pol = continuum::daemon_policy_default();
    check(pol.bloat_threshold_ms == 100.0 && pol.cooldown_ms > 0 && pol.hold_ms > 0
            && pol.max_applies_per_hour >= 1,
        "policy table carries threshold, cooldown, hold, budget");

    // --- router-profile contract + simulated stock-router backend ---
    let rp = continuum::router_profile();
    check(continuum::router_profile_valid(rp), "sim router profile is valid");
    check(rp.can_qos && rp.can_client_list && rp.access_kind == continuum::AccessKind.Sim,
        "sim router advertises its knobs");
    var undiscovered = rp;
    undiscovered.discovered = false;
    check(!continuum::router_profile_valid(undiscovered), "undiscovered profile is invalid");
    var no_endpoint = rp;
    no_endpoint.access_kind = continuum::AccessKind.WebApi;
    no_endpoint.endpoint = "";
    check(!continuum::router_profile_valid(no_endpoint), "web profile without endpoint is invalid");
    continuum::router_lock();
    check(!continuum::router_set_knob("qos", "on"), "knob set requires a session");
    check(!continuum::router_unlock("wrong-password"), "wrong password rejected");
    check(continuum::router_unlock("sim-password"), "sim password opens a session");
    check(continuum::router_set_knob("qos", "on"), "qos knob accepts a value");
    check(continuum::router_get_knob("qos") == "on", "knob reads back");
    check(continuum::sim_current_profile_id() == "sqm-fair", "qos knob drives the sim queue");
    check(continuum::router_clients() == 3, "client list knob answers");
    check(!continuum::router_set_knob("teleport", "mars"), "unknown knob rejected");
    let rev_before = continuum::router_profile().config_revision;
    continuum::router_reboot();
    check(!continuum::router_set_knob("qos", "off"), "reboot drops the session");
    check(continuum::router_profile().config_revision > rev_before, "reboot bumps revision");

    // --- onboarding: the control-channel planner (Delegate, C19/C20) ---
    // Discovery produces whatever paths actually reach the router; the
    // planner must handle a wired bench, an AP behind another network, a
    // second bound device, and the common case -- this machine's only path
    // rides the very Wi-Fi setup is about to rename. No strategy may
    // mutate until the admin credential is staged; a same-link leap
    // additionally needs the new SSID/PSK staged before the write.
    let wired = continuum::ControlPath {
        path_id: "wired0", kind: continuum::PathKind.Wired, interface_id: "en7",
        bind_addr: "192.168.50.50", endpoint: "192.168.50.1",
        rides_target_wifi: false, reachable: true,
    };
    let wifi_same = continuum::ControlPath {
        path_id: "wifi0", kind: continuum::PathKind.Wifi, interface_id: "en0",
        bind_addr: "192.168.50.173", endpoint: "192.168.50.1",
        rides_target_wifi: true, reachable: true,
    };
    var dead_wired = wired;
    dead_wired.reachable = false;
    let staged_full = continuum::StagedSetup {
        staged: true, old_ssid: "ASUS_20_5G_Gaming", new_ssid: "ContinuumLab",
        psk_ref: "continuum-lab-psk", admin_ref: "continuum-lab-admin",
    };
    var staged_admin_only = staged_full;
    staged_admin_only.new_ssid = "";
    staged_admin_only.psk_ref = "";
    let unstaged = continuum::StagedSetup {};

    let no_paths = continuum::plan_leap(continuum::ControlPaths {}, staged_full);
    check(no_paths.strategy == continuum::LeapStrategy.NoPath && !no_paths.admissible,
        "no discovered path is inadmissible");
    let dead_only = continuum::plan_leap(
        continuum::ControlPaths { items: [dead_wired] }, staged_full);
    check(dead_only.strategy == continuum::LeapStrategy.NoPath && !dead_only.admissible,
        "an unreachable path is not a control channel");

    let leap = continuum::plan_leap(
        continuum::ControlPaths { items: [wifi_same] }, staged_full);
    check(leap.strategy == continuum::LeapStrategy.SameLinkLeap && leap.admissible,
        "wifi-only with full staging may leap");
    check(leap.expects_disconnect && leap.rejoin_ssid == "ContinuumLab"
            && leap.fallback_ssid == "ASUS_20_5G_Gaming",
        "leap expects the drop and knows both SSIDs");
    check(leap.control_path_id == "wifi0" && leap.bind_addr == "192.168.50.173",
        "leap carries the interface binding for the backend");
    let leap_unstaged = continuum::plan_leap(
        continuum::ControlPaths { items: [wifi_same] }, unstaged);
    check(leap_unstaged.strategy == continuum::LeapStrategy.SameLinkLeap
            && !leap_unstaged.admissible && leap_unstaged.requires_staging,
        "unstaged leap is named but never admissible");
    let leap_admin_only = continuum::plan_leap(
        continuum::ControlPaths { items: [wifi_same] }, staged_admin_only);
    check(!leap_admin_only.admissible,
        "leap without staged ssid/psk is inadmissible");

    let wired_plan = continuum::plan_leap(
        continuum::ControlPaths { items: [wired] }, staged_admin_only);
    check(wired_plan.strategy == continuum::LeapStrategy.SurvivingPath
            && wired_plan.admissible && !wired_plan.expects_disconnect,
        "wired path survives the rename and needs only the admin staging");
    let wired_unstaged = continuum::plan_leap(
        continuum::ControlPaths { items: [wired] }, unstaged);
    check(wired_unstaged.strategy == continuum::LeapStrategy.SurvivingPath
            && !wired_unstaged.admissible,
        "even a surviving path may not write before the admin credential is staged");
    let both = continuum::plan_leap(
        continuum::ControlPaths { items: [wifi_same, wired] }, staged_full);
    check(both.strategy == continuum::LeapStrategy.SurvivingPath
            && both.control_path_id == "wired0",
        "a surviving path outranks a leap in any discovery order");
    let dead_then_wifi = continuum::plan_leap(
        continuum::ControlPaths { items: [dead_wired, wifi_same] }, staged_full);
    check(dead_then_wifi.strategy == continuum::LeapStrategy.SameLinkLeap
            && dead_then_wifi.admissible,
        "a dead wired path does not mask a usable leap");

    // After the leap the outcome is a decision table, not improvisation.
    check(continuum::classify_leap(true, false, true, true)
            == continuum::LeapOutcome.Verified,
        "joined new ssid and admin auth verified the leap");
    check(continuum::classify_leap(true, true, true, true)
            == continuum::LeapOutcome.Verified,
        "a verified join wins even while another band still shows the old ssid");
    check(continuum::classify_leap(true, false, true, false)
            == continuum::LeapOutcome.AdminAuthFailed,
        "joined but the staged admin credential is rejected");
    check(continuum::classify_leap(true, false, false, false)
            == continuum::LeapOutcome.CredentialMismatch,
        "new ssid visible but the staged psk does not join it");
    check(continuum::classify_leap(false, true, false, false)
            == continuum::LeapOutcome.NotApplied,
        "old ssid back and no new ssid means setup never applied");
    check(continuum::classify_leap(false, false, false, false)
            == continuum::LeapOutcome.Unreachable,
        "neither ssid visible is unreachable, not a credential verdict");
    check(!continuum::leap_needs_physical_reset(continuum::LeapOutcome.Verified)
            && !continuum::leap_needs_physical_reset(continuum::LeapOutcome.NotApplied)
            && !continuum::leap_needs_physical_reset(continuum::LeapOutcome.Unreachable),
        "verified, not-applied and unreachable never demand a reset");
    check(continuum::leap_needs_physical_reset(continuum::LeapOutcome.CredentialMismatch)
            && continuum::leap_needs_physical_reset(continuum::LeapOutcome.AdminAuthFailed),
        "staged-credential divergence on a class B device is the physical-reset case");

    // --- persistence + crash recovery ---
    continuum::sim_reset(5);
    continuum::actuator_use_store(lease_path, sim_path);
    continuum::journal_enable_file(journal_path);
    let obs0 = continuum::sim_observe("sim0", 0).observation;
    let prof = continuum::sim_profile(1);
    let req = continuum::propose_apply(obs0, prof, 0);
    let adm = continuum::admit_action(req, obs0, prof, 0);
    check(adm.admitted, "persistence apply admitted");
    let applied = continuum::apply_profile(req, adm);
    check(applied.applied, "persistence apply applied");
    let saved = continuum::lease_load(lease_path);
    check(saved.found && saved.profile_id == "sqm-fair" && saved.prev_profile_id == "baseline-fifo",
        "lease intent is on disk before anything else can happen");
    continuum::append_event(continuum::Event {
        event_type: "foundation-beat", run_id: "foundation-test", timestamp_ms: 1,
        provenance: continuum::Provenance.Synthetic, payload_json: "{}",
    });
    continuum::sim_advance_ms(20000);
    check(continuum::sim_save(sim_path), "sim state saves");
    continuum::actuator_forget_state();
    continuum::sim_reset(999);
    check(continuum::sim_current_profile_id() == "baseline-fifo", "crash loses in-memory state");
    let recovered = continuum::actuator_recover(20000);
    check(recovered.restored, "watchdog recovery restores the expired lease after crash");
    check(continuum::sim_current_profile_id() == "baseline-fifo", "queue is back at baseline");
    check(!continuum::lease_load(lease_path).found, "lease file cleared after recovery");
    var journal_text: u8[>..] = [];
    check(read_file(journal_path, journal_text), "journal file readable");
    check(find(journal_text, "foundation-beat") >= 0, "journal beat reached disk");

    // --- daemon: token-free loop over a load schedule ---
    let result = continuum::run_daemon(12);
    check(result.outcome.status == continuum::Status.Completed, "daemon completes");
    check(result.ticks == 12 && result.observations == 12, "daemon observed every tick");
    check(result.applies == 1, "daemon applied exactly once");
    check(result.restores == 1, "daemon restored exactly once");
    check(result.model_calls == 0 && result.tokens_estimated == 0, "daemon spent no tokens");
    check(result.escalations == 0, "daemon needed no escalation on the known path");
    check(continuum::sim_current_profile_id() == "baseline-fifo", "daemon leaves baseline active");

    print("FOUNDATION_ALL_GREEN");
}
