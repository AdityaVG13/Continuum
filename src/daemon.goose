// The token-free daemon: a deterministic tick loop over the policy table.
// It observes, decides, acts through the guardian/actuator, verifies, and
// restores -- spending zero model calls on the known path. Anything the
// policy table does not cover (unknown evidence, route change, a knob the
// profile cannot do) becomes an Escalate beat: that, and only that, is
// where a model gets woken up later.
import .contracts;
import .sim;
import .policy;
import .guardian;
import .actuator;
import .events;
namespace continuum;

struct DaemonResult {
    outcome: Outcome = Outcome {},
    ticks: i64 = 0,
    observations: i64 = 0,
    applies: i64 = 0,
    restores: i64 = 0,
    model_calls: i64 = 0,
    escalations: i64 = 0,
    tokens_estimated: i64 = 0,
}

fn daemon_policy_default() -> PolicyConfig {
    return PolicyConfig {};
}

// The whole policy in one pure function, so the decision table is testable
// without running the loop. Order matters: evidence problems escalate
// before anything acts, and a held lease outranks a fresh apply.
fn daemon_decide(obs: Observation, lease_active: bool, dwell_met: bool,
                 cooldown_ok: bool, last_route_epoch: i64) -> Decision {
    if !obs.metrics_known || obs.attempts <= 0 || obs.successes <= 0 {
        return Decision.Escalate;
    }
    if obs.route_epoch != last_route_epoch {
        return Decision.Escalate;
    }
    if lease_active {
        return if dwell_met { Decision.Restore } else { Decision.Noop };
    }
    if bloat_detected(obs, daemon_policy_default().bloat_threshold_ms) {
        return if cooldown_ok { Decision.Apply } else { Decision.Noop };
    }
    return Decision.Noop;
}

// Fixed load schedule for the test environment: quiet, saturating, quiet.
// One apply under saturation, one restore after the hold, no flap when the
// cooldown has not elapsed, no escalation on the known path.
fn run_daemon(ticks: i64) -> DaemonResult {
    sim_reset(7);
    let pol = daemon_policy_default();
    let fair = sim_profile(1);
    var res = DaemonResult {
        outcome: Outcome { status: Status.Completed, message: "daemon completed" },
    };
    var lease_active = false;
    var lease_id: u8[..64] = "";
    var applied_at_ms: i64 = 0;
    var last_mutation_ms: i64 = -1000000000;
    var last_epoch: i64 = -1;
    for tick in 0..ticks {
        if tick < 2 {
            sim_set_load(0.2);
        } else if tick < 8 {
            sim_set_load(1.0);
        } else {
            sim_set_load(0.2);
        }
        // Watchdog first: an expired lease is restored even if this tick
        // would otherwise do nothing.
        if lease_active && sim_now_ms() >= applied_at_ms + pol.lease_ms {
            let wd = reconcile_expired_lease(lease_id, sim_now_ms());
            if wd.restored {
                res.restores += 1;
                lease_active = false;
                print("DAEMON watchdog-restore tick=", tick);
            }
        }
        let obs = sim_observe("sim0", tick).observation;
        res.ticks += 1;
        res.observations += 1;
        if last_epoch < 0 {
            last_epoch = obs.route_epoch;
        }
        let dwell_met = lease_active && sim_now_ms() - applied_at_ms >= pol.hold_ms;
        var cooldown_ok = sim_now_ms() - last_mutation_ms >= pol.cooldown_ms;
        if res.applies >= pol.max_applies_per_hour {
            cooldown_ok = false;
        }
        let decision = daemon_decide(obs, lease_active, dwell_met, cooldown_ok, last_epoch);
        last_epoch = obs.route_epoch;
        if decision == Decision.Apply {
            let req = propose_apply(obs, fair, sim_now_ms());
            let adm = admit_action(req, obs, fair, sim_now_ms());
            if adm.admitted {
                let receipt = apply_profile(req, adm);
                if receipt.applied && receipt.verification_complete {
                    lease_active = true;
                    lease_id = receipt.lease_id;
                    applied_at_ms = sim_now_ms();
                    last_mutation_ms = sim_now_ms();
                    res.applies += 1;
                    beat("daemon-apply", "fair profile active");
                    print("DAEMON apply tick=", tick, " loaded=", obs.loaded_rtt_ms);
                } else {
                    res.escalations += 1;
                    beat("daemon-escalate", "apply did not verify");
                }
            } else {
                res.escalations += 1;
                beat("daemon-escalate", "clean apply rejected");
            }
        } else if decision == Decision.Restore {
            let req = propose_restore(lease_id, fair.scope_id, fair.path_id,
                fair.revision, sim_now_ms());
            let adm = admit_action(req, obs, fair, sim_now_ms());
            if adm.admitted {
                let receipt = restore_profile(req, adm);
                if receipt.restored && receipt.verification_complete {
                    lease_active = false;
                    last_mutation_ms = sim_now_ms();
                    res.restores += 1;
                    beat("daemon-restore", "baseline profile active");
                    print("DAEMON restore tick=", tick);
                } else {
                    res.escalations += 1;
                    beat("daemon-escalate", "restore did not verify");
                }
            } else {
                res.escalations += 1;
                beat("daemon-escalate", "clean restore rejected");
            }
        } else if decision == Decision.Escalate {
            res.escalations += 1;
            beat("daemon-escalate", "policy table has no answer");
            print("DAEMON escalate tick=", tick);
        }
        sim_advance_ms(pol.tick_ms);
    }
    print("DAEMON ticks=", res.ticks, " applies=", res.applies, " restores=", res.restores,
        " escalations=", res.escalations, " model_calls=", res.model_calls);
    return res;
}
