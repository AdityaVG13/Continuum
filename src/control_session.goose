// One supervised controller session owns one explicitly selected actuator.
// Router HTTP here is the loopback lab API, not an ASUS firmware claim.
// Synthetic observations must not authorize mutations on physical hardware.
import .contracts;
import .router_web;
import .actuator;
import .tooljson;
import json;
namespace continuum;

struct WebController {
    enabled: bool = false,
    host: u8[..253] = "",
    port: i64 = 0,
    baseline: QosView = QosView {},
    active: bool = false,
    lease_id: u8[..64] = "",
    applied_revision: i64 = -1,
    receipt: ActionReceipt = ActionReceipt {},
    run_id: u8[..64] = "",
}

var web_controller: WebController = WebController {};

fn controller_select_router(host: const u8[:], port: i64) -> bool {
    if web_controller.active || active_lease.active { return false; }
    web_controller = WebController {};
    if (host != "127.0.0.1" && host != "localhost") || port <= 0 || port > 65535 {
        return false;
    }
    let before = web_qos(host, port);
    if !before.ok { return false; }
    web_controller.enabled = true;
    web_controller.host = host;
    web_controller.port = port;
    web_controller.baseline = before;
    return true;
}

fn controller_select_sim() -> bool {
    if web_controller.active || active_lease.active { return false; }
    web_controller = WebController {};
    return true;
}

fn controller_begin(run_id: const u8[:]) -> bool {
    if web_controller.active || active_lease.active || !valid_id(run_id, 64) { return false; }
    if !web_controller.enabled { return true; }
    let baseline = web_qos(web_controller.host, web_controller.port);
    if !baseline.ok { return false; }
    web_controller.baseline = baseline;
    web_controller.run_id = run_id;
    web_controller.receipt = ActionReceipt {};
    return true;
}

fn controller_current_profile() -> u8[..64] {
    if !web_controller.enabled { return sim_current_profile_id(); }
    let q = web_qos(web_controller.host, web_controller.port);
    if !q.ok { return ""; }
    if !q.qos_on { return "baseline-fifo"; }
    if q.rate_mbit == 90 { return "sqm-fair"; }
    return "router-qos";
}

fn web_controller_profiles(scope_id: const u8[:]) -> ProfileListResult {
    var out = ProfileListResult {
        outcome: Outcome { status: Status.Completed, message: "owned loopback router catalogue" },
    };
    if scope_id != "lab-sim" { return out; }
    let current = web_qos(web_controller.host, web_controller.port);
    if !current.ok {
        out.outcome = Outcome { status: Status.Failed, message: current.reason };
        return out;
    }
    out.profiles.push(ActionProfile {
        profile_id: "sqm-fair", scope_id: "lab-sim", path_id: "sim0",
        owned: true, configured_rate_kbit: 90000, maximum_lease_ms: 60000,
        revision: current.revision,
    });
    return out;
}

fn web_dispatch_failure(status: Status, reason: const u8[:]) -> ToolDispatch {
    var body: u8[>..] = [];
    body.append("{\"status\":");
    json::format_string(body, status_name(status));
    body.append(",\"reason\":");
    json::format_string(body, reason);
    body.append(",\"actuator\":\"router-http-lab\"}");
    return ToolDispatch {
        outcome: Outcome { status: status, message: reason },
        result_json: body, simulated: false,
    };
}

fn web_dispatch_receipt(word: const u8[:], receipt: ActionReceipt) -> ToolDispatch {
    let profile = controller_current_profile();
    return ToolDispatch {
        outcome: receipt.outcome,
        result_json: mutation_body(word, receipt, profile, receipt.verification_complete),
        simulated: false, verified: receipt.verification_complete, profile_id: profile,
    };
}

fn dispatch_web_apply(envelope: const u8[:], run_id: const u8[:]) -> ToolDispatch {
    let call = validate_apply_call(envelope);
    if !call.ok { return web_dispatch_failure(Status.Rejected, call.reason); }
    if web_controller.active { return web_dispatch_failure(Status.Rejected, "a lease is already active"); }
    var req = call.request;
    req.run_id = run_id;
    req.expected_revision = req.config_revision;
    req.issued_at_ms = sim_now_ms();
    let obs = read_observation(req.path_id);
    let task = read_task_context(run_id);
    if obs.outcome.status != Status.Completed || task.outcome.status != Status.Completed {
        return web_dispatch_failure(Status.Failed, "controller context unavailable");
    }
    if req.observation_id != obs.observation.observation_id || req.task_revision != task.context.revision {
        return web_dispatch_failure(Status.Rejected, "observation or task revision changed");
    }
    let prof, found = catalogue_profile(req.profile_id);
    if !found { return web_dispatch_failure(Status.Rejected, "profile is not in the catalogue"); }
    let admission = admit_action(req, obs.observation, prof, sim_now_ms());
    if !admission.admitted { return web_dispatch_failure(Status.Rejected, admission.outcome.message); }
    let before = web_qos(web_controller.host, web_controller.port);
    if !before.ok { return web_dispatch_failure(Status.Failed, before.reason); }
    if before.revision != req.config_revision {
        return web_dispatch_failure(Status.Rejected, "router configuration changed before apply");
    }
    // Intent precedes the write. An ambiguous failure must still reach
    // exit reconciliation, rather than losing the baseline it may need.
    web_controller.baseline = before;
    web_controller.active = true;
    web_controller.lease_id = req.lease_id;
    web_controller.applied_revision = before.revision + 1;
    let applied = web_apply(prof.profile_id, prof.configured_rate_kbit / 1000,
        req.scope_id, req.lease_id, before.revision, web_controller.host, web_controller.port);
    let after = web_qos(web_controller.host, web_controller.port);
    if !applied.ok || !applied.verified || !after.ok || !after.qos_on
            || after.rate_mbit != prof.configured_rate_kbit / 1000
            || applied.revision != before.revision + 1 || after.revision != applied.revision {
        return web_dispatch_failure(Status.Failed, "router apply was not independently read back");
    }
    web_controller.receipt = ActionReceipt {
        outcome: Outcome { status: Status.Completed, message: "router apply read back" },
        action_id: req.request_id, lease_id: req.lease_id,
        observed_revision: after.revision, applied: true, verification_complete: true,
    };
    return web_dispatch_receipt("applied", web_controller.receipt);
}

// Preserve outside edits. Retain the lease if restoration is uncertain.
fn restore_web_owned(action_id: const u8[:]) -> ToolDispatch {
    if !web_controller.active { return web_dispatch_failure(Status.Rejected, "no active router lease"); }
    let before = web_qos(web_controller.host, web_controller.port);
    if !before.ok { return web_dispatch_failure(Status.Failed, before.reason); }
    let base = web_controller.baseline;
    if before.revision == base.revision && before.qos_on == base.qos_on && before.rate_mbit == base.rate_mbit {
        web_controller.active = false;
        return web_dispatch_failure(Status.Completed, "router write was not applied; baseline is unchanged");
    }
    if before.revision != web_controller.applied_revision || !before.qos_on || before.rate_mbit != 90 {
        return web_dispatch_failure(Status.Rejected, "router changed outside this lease; refusing to overwrite it");
    }
    let restored = web_restore_state("lab-sim", web_controller.lease_id, before.revision,
        base.qos_on, base.rate_mbit, web_controller.host, web_controller.port);
    let after = web_qos(web_controller.host, web_controller.port);
    if !restored.ok || !after.ok || !restored.verified
            || after.revision != before.revision + 1 || restored.revision != after.revision
            || after.qos_on != base.qos_on || after.rate_mbit != base.rate_mbit {
        return web_dispatch_failure(Status.Failed, "router baseline restoration was not independently read back");
    }
    web_controller.active = false;
    web_controller.receipt = ActionReceipt {
        outcome: Outcome { status: Status.Completed, message: "router baseline restored and read back" },
        action_id: action_id, lease_id: web_controller.lease_id,
        observed_revision: after.revision, restored: true, verification_complete: true,
    };
    return web_dispatch_receipt("restored", web_controller.receipt);
}

fn dispatch_web_restore(envelope: const u8[:], run_id: const u8[:]) -> ToolDispatch {
    let call = validate_restore_call(envelope);
    if !call.ok { return web_dispatch_failure(Status.Rejected, call.reason); }
    var req = call.request;
    if !web_controller.active || req.lease_id != web_controller.lease_id {
        return web_dispatch_failure(Status.Rejected, "no matching active router lease");
    }
    req.run_id = run_id;
    req.path_id = "sim0";
    req.lease_ms = 60000;
    let prof = ActionProfile {
        profile_id: "sqm-fair", scope_id: "lab-sim", path_id: "sim0", owned: true,
        revision: web_controller.applied_revision, maximum_lease_ms: 60000,
    };
    let obs = read_observation("sim0");
    let admission = admit_action(req, obs.observation, prof, sim_now_ms());
    if !admission.admitted { return web_dispatch_failure(Status.Rejected, admission.outcome.message); }
    return restore_web_owned(req.request_id);
}

fn dispatch_web_result(envelope: const u8[:]) -> ToolDispatch {
    let call = validate_read_call(envelope, ToolName.ReadActionResult);
    if !call.ok { return web_dispatch_failure(Status.Rejected, call.reason); }
    let receipt = web_controller.receipt;
    if receipt.action_id.len == 0 || call.arg != receipt.action_id {
        return web_dispatch_failure(Status.Rejected, "unknown router action id");
    }
    let current = web_qos(web_controller.host, web_controller.port);
    let base = web_controller.baseline;
    if !current.ok || current.revision != receipt.observed_revision
            || (receipt.applied && (!current.qos_on || current.rate_mbit != 90))
            || (receipt.restored && (current.qos_on != base.qos_on || current.rate_mbit != base.rate_mbit)) {
        return web_dispatch_failure(Status.Failed, "router state no longer matches the action receipt");
    }
    return web_dispatch_receipt("readback", receipt);
}
