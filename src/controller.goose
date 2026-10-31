import .contracts;
import .sim;
import .telemetry;
import .task_runner;
import .guardian;
import .actuator;
import .policy;
import .router_web;
import .meta_provider;
import .tooljson;
import .meta_shape;
import json;
namespace continuum;

struct ProfileListResult { outcome: Outcome = Outcome {}, profiles: ActionProfile[..8] = [] }

// Server-owned allowlist: only listed, owned profiles can ever be admitted.
// The sim catalogue answers for the lab-sim scope; every other scope gets
// an empty list, never an error masquerading as profiles.
fn list_profiles(scope_id: const u8[:]) -> ProfileListResult {
    if scope_id != "lab-sim" {
        return ProfileListResult {
            outcome: Outcome { status: Status.Completed, message: "no profiles for scope" },
        };
    }
    var out = ProfileListResult {
        outcome: Outcome { status: Status.Completed, message: "sim catalogue" },
    };
    for i in 0..sim_profile_count() {
        out.profiles.push(sim_profile(i));
    }
    return out;
}

struct RouterLoopReport {
    outcome: Outcome = Outcome {},
    verified: bool = false,
    revision_before: i64 = -1,
    revision_after: i64 = -1,
    restored_drift: bool = false,
}

// Same admission as the sim loop, different actuator: the C++ router.
// verified is true only when the router revision advanced by one, a
// second read confirms that revision, and restore makes that revision
// drift. The transport's own verified bit is not enough.
fn run_router_loop(host: const u8[:], port: i64) -> RouterLoopReport {
    var report = RouterLoopReport {};
    if host.len == 0 || port <= 0 || port > 65535 {
        report.outcome = Outcome { status: Status.Failed, message: "router target missing" };
        return report;
    }
    sim_reset(11);
    let obs = read_observation("sim0");
    if obs.outcome.status != Status.Completed || !obs.observation.metrics_known {
        report.outcome = Outcome { status: Status.Failed, message: "router loop has no observation" };
        return report;
    }
    let plist = list_profiles("lab-sim");
    var prof = ActionProfile {};
    var found = false;
    for p in plist.profiles {
        if p.profile_id == "sqm-fair" && p.owned {
            prof = p;
            found = true;
        }
    }
    if !found {
        report.outcome = Outcome { status: Status.Failed, message: "router loop has no owned fair profile" };
        return report;
    }
    let rate = prof.configured_rate_kbit / 1000;
    if rate < 1 || rate > 1000 {
        report.outcome = Outcome { status: Status.Failed, message: "router rate outside 1..1000 mbit" };
        return report;
    }
    var env: u8[>..] = [];
    env.append("{\"tool\":\"apply_profile\",\"arguments\":{");
    env.append("\"request_id\":\"router-apply\",\"scope_id\":\"lab-sim\",\"path_id\":\"sim0\",");
    env.append("\"profile_id\":\"sqm-fair\",\"observation_id\":\"");
    env.append(obs.observation.observation_id);
    env.append("\",\"task_revision\":1,\"route_epoch\":");
    json::format_int(env, obs.observation.route_epoch);
    env.append(",\"config_revision\":");
    json::format_int(env, prof.revision);
    env.append(",\"lease_ms\":10000,\"rationale\":\"router loop: drain the bloated queue\"}}");
    let vc = validate_apply_call(env);
    if !vc.ok {
        report.outcome = Outcome { status: Status.Rejected, message: vc.reason };
        return report;
    }
    var req = vc.request;
    req.expected_revision = req.config_revision;
    req.issued_at_ms = sim_now_ms();
    req.run_id = "router-loop";
    let adm = admit_action(req, obs.observation, prof, sim_now_ms());
    if !adm.admitted {
        report.outcome = Outcome { status: Status.Rejected, message: adm.outcome.message };
        return report;
    }
    let before = web_reconcile("lab-sim", "probe", 0, host, port);
    report.revision_before = before.revision;
    if before.revision < 0 {
        report.outcome = Outcome { status: Status.Failed, message: before.reason };
        return report;
    }
    let ap = web_apply(prof.profile_id, rate, "lab-sim", adm.action_id, prof.revision, host, port);
    report.revision_after = ap.revision;
    let advanced = ap.ok && ap.verified && ap.revision == before.revision + 1;
    if !advanced {
        report.outcome = Outcome { status: Status.Failed, message: ap.reason };
        return report;
    }
    let sync = web_reconcile("lab-sim", adm.action_id, ap.revision, host, port);
    if !sync.ok || sync.revision != ap.revision {
        report.outcome = Outcome { status: Status.Failed, message: "router readback did not hold the applied revision" };
        return report;
    }
    let rs = web_restore("lab-sim", adm.action_id, ap.revision, host, port);
    if !rs.ok || !rs.verified {
        report.outcome = Outcome { status: Status.Failed, message: rs.reason };
        return report;
    }
    let after = web_reconcile("lab-sim", adm.action_id, ap.revision, host, port);
    report.restored_drift = !after.ok;
    if after.ok {
        report.outcome = Outcome { status: Status.Failed, message: "restore left the applied revision in sync" };
        return report;
    }
    report.verified = true;
    report.outcome = Outcome { status: Status.Completed, message: "router loop read back" };
    return report;
}

// Operator tuner. status is a QoS read. apply admits one owned fair
// profile, sends it, and leaves it. restore is the separate undo: it
// fails unless the revision it replaced is gone.
struct RouterView {
    outcome: Outcome = Outcome {},
    ok: bool = false,
    qos_on: bool = false,
    rate_mbit: i64 = -1,
    revision: i64 = -1,
    revision_before: i64 = -1,
}

fn router_status(host: const u8[:], port: i64) -> RouterView {
    var view = RouterView {};
    if host.len == 0 || port <= 0 || port > 65535 {
        view.outcome = Outcome { status: Status.Failed, message: "router target missing" };
        return view;
    }
    let q = web_qos(host, port);
    if !q.ok {
        view.outcome = Outcome { status: Status.Failed, message: q.reason };
        return view;
    }
    view.ok = true;
    view.qos_on = q.qos_on;
    view.rate_mbit = q.rate_mbit;
    view.revision = q.revision;
    view.outcome = Outcome { status: Status.Completed, message: "router qos read" };
    return view;
}

fn router_apply(host: const u8[:], port: i64, profile_id: const u8[:], rate_mbit: i64) -> RouterView {
    var view = RouterView {};
    if host.len == 0 || port <= 0 || port > 65535 {
        view.outcome = Outcome { status: Status.Failed, message: "router target missing" };
        return view;
    }
    if profile_id != "sqm-fair" {
        view.outcome = Outcome { status: Status.Rejected, message: "apply accepts the owned fair profile only" };
        return view;
    }
    if rate_mbit < 1 || rate_mbit > 1000 {
        view.outcome = Outcome { status: Status.Rejected, message: "router rate outside 1..1000 mbit" };
        return view;
    }
    let plist = list_profiles("lab-sim");
    var prof = ActionProfile {};
    var found = false;
    for p in plist.profiles {
        if p.profile_id == profile_id && p.owned {
            prof = p;
            found = true;
        }
    }
    if !found {
        view.outcome = Outcome { status: Status.Failed, message: "router apply has no owned fair profile" };
        return view;
    }
    if prof.configured_rate_kbit != rate_mbit * 1000 {
        view.outcome = Outcome { status: Status.Rejected, message: "rate does not match the owned profile" };
        return view;
    }
    sim_reset(11);
    let obs = read_observation("sim0");
    if obs.outcome.status != Status.Completed || !obs.observation.metrics_known {
        view.outcome = Outcome { status: Status.Failed, message: "router apply has no observation" };
        return view;
    }
    var env: u8[>..] = [];
    env.append("{\"tool\":\"apply_profile\",\"arguments\":{");
    env.append("\"request_id\":\"router-apply\",\"scope_id\":\"lab-sim\",\"path_id\":\"sim0\",");
    env.append("\"profile_id\":\"sqm-fair\",\"observation_id\":\"");
    env.append(obs.observation.observation_id);
    env.append("\",\"task_revision\":1,\"route_epoch\":");
    json::format_int(env, obs.observation.route_epoch);
    env.append(",\"config_revision\":");
    json::format_int(env, prof.revision);
    env.append(",\"lease_ms\":10000,\"rationale\":\"operator apply: set the owned fair profile\"}}");
    let vc = validate_apply_call(env);
    if !vc.ok {
        view.outcome = Outcome { status: Status.Rejected, message: vc.reason };
        return view;
    }
    var req = vc.request;
    req.expected_revision = req.config_revision;
    req.issued_at_ms = sim_now_ms();
    req.run_id = "router-apply";
    let adm = admit_action(req, obs.observation, prof, sim_now_ms());
    if !adm.admitted {
        view.outcome = Outcome { status: Status.Rejected, message: adm.outcome.message };
        return view;
    }
    let before = web_qos(host, port);
    if !before.ok {
        view.outcome = Outcome { status: Status.Failed, message: before.reason };
        return view;
    }
    let ap = web_apply(prof.profile_id, rate_mbit, "lab-sim", adm.action_id, prof.revision, host, port);
    if !ap.ok || !ap.verified || ap.revision != before.revision + 1 {
        if ap.ok {
            view.outcome = Outcome { status: Status.Failed, message: "apply did not advance the router revision" };
        } else {
            view.outcome = Outcome { status: Status.Failed, message: ap.reason };
        }
        return view;
    }
    let after = web_qos(host, port);
    if !after.ok || !after.qos_on || after.rate_mbit != rate_mbit || after.revision != ap.revision {
        view.outcome = Outcome { status: Status.Failed, message: "router readback did not hold the applied qos" };
        return view;
    }
    view.ok = true;
    view.qos_on = after.qos_on;
    view.rate_mbit = after.rate_mbit;
    view.revision = after.revision;
    view.revision_before = before.revision;
    view.outcome = Outcome { status: Status.Completed, message: "router apply read back" };
    return view;
}

fn router_restore(host: const u8[:], port: i64) -> RouterView {
    var view = RouterView {};
    if host.len == 0 || port <= 0 || port > 65535 {
        view.outcome = Outcome { status: Status.Failed, message: "router target missing" };
        return view;
    }
    let before = web_qos(host, port);
    if !before.ok {
        view.outcome = Outcome { status: Status.Failed, message: before.reason };
        return view;
    }
    let rs = web_restore("lab-sim", "router-restore", before.revision, host, port);
    if !rs.ok || !rs.verified || rs.revision != before.revision + 1 {
        if rs.ok {
            view.outcome = Outcome { status: Status.Failed, message: "restore did not advance the router revision" };
        } else {
            view.outcome = Outcome { status: Status.Failed, message: rs.reason };
        }
        return view;
    }
    let sync = web_reconcile("lab-sim", "router-restore", before.revision, host, port);
    if sync.revision < 0 {
        view.outcome = Outcome { status: Status.Failed, message: sync.reason };
        return view;
    }
    if sync.ok || sync.revision == before.revision {
        view.outcome = Outcome { status: Status.Failed, message: "restore left the applied revision in sync" };
        return view;
    }
    let after = web_qos(host, port);
    if !after.ok || after.qos_on || after.rate_mbit != 100 || after.revision != rs.revision {
        view.outcome = Outcome { status: Status.Failed, message: "router readback did not show the baseline" };
        return view;
    }
    view.ok = true;
    view.qos_on = after.qos_on;
    view.rate_mbit = after.rate_mbit;
    view.revision = after.revision;
    view.revision_before = before.revision;
    view.outcome = Outcome { status: Status.Completed, message: "router restore read back" };
    return view;
}

struct ToolDispatch {
    outcome: Outcome = Outcome {},
    result_json: u8[..8192] = "",
    simulated: bool = false,
    verified: bool = false,
    observation_id: u8[..64] = "",
    loaded_rtt_ms: f64 = 0.0,
    profile_id: u8[..64] = "",
}

struct SimLoopReport {
    outcome: Outcome = Outcome {},
    simulated: bool = false,
    model_calls: i64 = 0,
    applied: bool = false,
    restored: bool = false,
    saw_sqm: bool = false,
    profile_after: u8[..64] = "",
    observation_id: u8[..64] = "",
    loaded_rtt_ms: f64 = 0.0,
}

fn tool_label(tool: ToolName) -> const u8[:] {
    if tool == ToolName.ReadObservation { return "read_observation"; }
    if tool == ToolName.ReadTaskContext { return "read_task_context"; }
    if tool == ToolName.ListProfiles { return "list_profiles"; }
    if tool == ToolName.ApplyProfile { return "apply_profile"; }
    if tool == ToolName.ReadActionResult { return "read_action_result"; }
    if tool == ToolName.RestoreProfile { return "restore_profile"; }
    if tool == ToolName.DiscoverTopology { return "discover_topology"; }
    if tool == ToolName.InspectSystem { return "inspect_system"; }
    if tool == ToolName.ProposeRuleset { return "propose_ruleset"; }
    return "unknown";
}

// Envelope the live tick submits to the dispatcher. arguments_json is the
// provider's object, already bounded by the parser. An empty or non-object
// body fails in the validator; this function does not invent arguments.
fn tool_envelope(tool: ToolName, arguments_json: const u8[:]) -> u8[>..] {
    var env: u8[>..] = [];
    env.append("{\"tool\":");
    json::format_string(env, tool_label(tool));
    env.append(",\"arguments\":");
    if arguments_json.len == 0 {
        env.append("{}");
    } else {
        env.append(arguments_json);
    }
    env.append("}");
    return env;
}

fn six_tool(name: const u8[:]) -> bool {
    return name == "read_observation" || name == "read_task_context"
        || name == "list_profiles" || name == "apply_profile"
        || name == "read_action_result" || name == "restore_profile";
}

fn rejected_dispatch(reason: const u8[:]) -> ToolDispatch {
    var body: u8[>..] = [];
    body.append("{\"status\":\"rejected\",\"reason\":");
    json::format_string(body, reason);
    body.append("}");
    return ToolDispatch {
        outcome: Outcome { status: Status.Rejected, message: reason },
        result_json: body,
        simulated: true,
        profile_id: sim_current_profile_id(),
    };
}

fn failed_dispatch(reason: const u8[:]) -> ToolDispatch {
    var body: u8[>..] = [];
    body.append("{\"status\":\"failed\",\"reason\":");
    json::format_string(body, reason);
    body.append("}");
    return ToolDispatch {
        outcome: Outcome { status: Status.Failed, message: reason },
        result_json: body,
        simulated: true,
        profile_id: sim_current_profile_id(),
    };
}

fn catalogue_profile(profile_id: const u8[:]) -> ActionProfile, bool {
    let listed = list_profiles("lab-sim");
    for p in listed.profiles {
        if p.profile_id == profile_id {
            return p, true;
        }
    }
    return ActionProfile {}, false;
}

fn bool_word(v: bool) -> const u8[:] {
    if v { return "true"; }
    return "false";
}

// verified is true only when the actuator's readback flag is set and the
// sim's current profile is the one this call was supposed to land on.
fn mutation_body(status_word: const u8[:], receipt: ActionReceipt,
        readback_profile: const u8[:], verified: bool) -> u8[>..] {
    var body: u8[>..] = [];
    body.append("{\"status\":");
    json::format_string(body, status_word);
    body.append(",\"profile_id\":");
    json::format_string(body, readback_profile);
    body.append(",\"lease_id\":");
    json::format_string(body, receipt.lease_id);
    body.append(",\"action_id\":");
    json::format_string(body, receipt.action_id);
    body.append(",\"verified\":");
    body.append(bool_word(verified));
    body.append(",\"applied\":");
    body.append(bool_word(receipt.applied));
    body.append(",\"restored\":");
    body.append(bool_word(receipt.restored));
    body.append("}");
    return body;
}

fn observation_body(obs: Observation) -> u8[>..] {
    var body: u8[>..] = [];
    body.append("{\"status\":\"observation\",\"observation_id\":");
    json::format_string(body, obs.observation_id);
    body.append(",\"path_id\":");
    json::format_string(body, obs.path_id);
    body.append(",\"route_epoch\":");
    json::format_int(body, obs.route_epoch);
    body.append(",\"loaded_rtt_ms\":");
    body.append(str(obs.loaded_rtt_ms));
    body.append(",\"baseline_rtt_ms\":");
    body.append(str(obs.baseline_rtt_ms));
    body.append(",\"gateway_rtt_ms\":");
    body.append(str(obs.gateway_rtt_ms));
    body.append(",\"provider_service_ms\":");
    body.append(str(obs.provider_service_ms));
    body.append(",\"utilization\":");
    body.append(str(obs.utilization));
    body.append(",\"metrics_known\":");
    body.append(bool_word(obs.metrics_known));
    body.append(",\"provenance\":\"synthetic\"}");
    return body;
}

fn task_body(ctx: TaskContext) -> u8[>..] {
    var body: u8[>..] = [];
    body.append("{\"status\":\"task\",\"run_id\":");
    json::format_string(body, ctx.run_id);
    body.append(",\"step_id\":");
    json::format_string(body, ctx.step_id);
    body.append(",\"revision\":");
    json::format_int(body, ctx.revision);
    body.append(",\"deadline_at_ms\":");
    json::format_int(body, ctx.deadline_at_ms);
    body.append(",\"task_summary\":");
    json::format_string(body, ctx.task_summary);
    body.append(",\"at_safe_boundary\":");
    body.append(bool_word(ctx.at_safe_boundary));
    body.append("}");
    return body;
}

fn profile_list_body(listed: ProfileListResult) -> u8[>..] {
    var body: u8[>..] = [];
    body.append("{\"status\":\"profiles\",\"profiles\":[");
    var first = true;
    for p in listed.profiles {
        if !first { body.append(","); }
        first = false;
        body.append("{\"profile_id\":");
        json::format_string(body, p.profile_id);
        body.append(",\"owned\":");
        body.append(bool_word(p.owned));
        body.append(",\"configured_rate_kbit\":");
        json::format_int(body, p.configured_rate_kbit);
        body.append(",\"revision\":");
        json::format_int(body, p.revision);
        body.append("}");
    }
    body.append("]}");
    return body;
}

fn dispatch_read(envelope: const u8[:], expected: ToolName, run_id: const u8[:]) -> ToolDispatch {
    let call = validate_read_call(envelope, expected);
    if !call.ok {
        return rejected_dispatch(call.reason);
    }
    if expected == ToolName.ReadObservation {
        let got = read_observation(call.arg);
        if got.outcome.status != Status.Completed {
            return failed_dispatch(got.outcome.message);
        }
        return ToolDispatch {
            outcome: got.outcome,
            result_json: observation_body(got.observation),
            simulated: true,
            observation_id: got.observation.observation_id,
            loaded_rtt_ms: got.observation.loaded_rtt_ms,
            profile_id: sim_current_profile_id(),
        };
    }
    if expected == ToolName.ReadTaskContext {
        if call.arg != run_id {
            return rejected_dispatch("run id does not match this controller");
        }
        let got = read_task_context(call.arg);
        if got.outcome.status != Status.Completed {
            return failed_dispatch(got.outcome.message);
        }
        return ToolDispatch {
            outcome: got.outcome,
            result_json: task_body(got.context),
            simulated: true,
            profile_id: sim_current_profile_id(),
        };
    }
    if expected == ToolName.ListProfiles {
        let got = list_profiles(call.arg);
        return ToolDispatch {
            outcome: got.outcome,
            result_json: profile_list_body(got),
            simulated: true,
            profile_id: sim_current_profile_id(),
        };
    }
    let got = read_action_result(call.arg);
    if got.outcome.status != Status.Completed {
        return failed_dispatch(got.outcome.message);
    }
    let after = sim_current_profile_id();
    let verified = got.verification_complete;
    var word: u8[>..] = [];
    word.append("readback");
    return ToolDispatch {
        outcome: got.outcome,
        result_json: mutation_body(word, got, after, verified),
        simulated: true,
        verified: verified,
        profile_id: after,
    };
}

fn dispatch_apply(envelope: const u8[:], run_id: const u8[:]) -> ToolDispatch {
    let call = validate_apply_call(envelope);
    if !call.ok {
        return rejected_dispatch(call.reason);
    }
    var req = call.request;
    req.run_id = run_id;
    req.expected_revision = req.config_revision;
    req.issued_at_ms = sim_now_ms();
    let obs = read_observation(req.path_id);
    if obs.outcome.status != Status.Completed {
        return failed_dispatch(obs.outcome.message);
    }
    if req.observation_id != obs.observation.observation_id {
        return rejected_dispatch("observation id does not match the current window");
    }
    let prof, found = catalogue_profile(req.profile_id);
    if !found {
        return rejected_dispatch("profile is not in the catalogue");
    }
    let adm = admit_action(req, obs.observation, prof, sim_now_ms());
    if !adm.admitted {
        return rejected_dispatch(adm.outcome.message);
    }
    let receipt = apply_profile(req, adm);
    let after = sim_current_profile_id();
    let verified = receipt.verification_complete && receipt.applied && after == req.profile_id;
    var outcome = receipt.outcome;
    if !verified {
        outcome = Outcome { status: Status.Failed, message: "readback did not match the requested profile" };
    }
    var word: u8[>..] = [];
    word.append("applied");
    return ToolDispatch {
        outcome: outcome,
        result_json: mutation_body(word, receipt, after, verified),
        simulated: true,
        verified: verified,
        profile_id: after,
    };
}

fn dispatch_restore(envelope: const u8[:], run_id: const u8[:]) -> ToolDispatch {
    let call = validate_restore_call(envelope);
    if !call.ok {
        return rejected_dispatch(call.reason);
    }
    var req = call.request;
    req.run_id = run_id;
    let current = sim_current_profile_id();
    let prof, found = catalogue_profile(current);
    if !found {
        return rejected_dispatch("current profile is not in the catalogue");
    }
    // The restore tool names a lease, not a path. The host binds the path
    // of the owned profile that is actually applied. It does not let the
    // model pick a different one. lease_ms is not on the restore schema;
    // the bound was enforced at apply, so admission sees the profile max.
    req.path_id = prof.path_id;
    if req.lease_ms <= 0 {
        req.lease_ms = prof.maximum_lease_ms;
    }
    let obs = read_observation(req.path_id);
    if obs.outcome.status != Status.Completed {
        return failed_dispatch(obs.outcome.message);
    }
    let before = sim_current_profile_id();
    let adm = admit_action(req, obs.observation, prof, sim_now_ms());
    if !adm.admitted {
        return rejected_dispatch(adm.outcome.message);
    }
    let receipt = restore_profile(req, adm);
    let after = sim_current_profile_id();
    let verified = receipt.verification_complete && receipt.restored && after != before;
    var outcome = receipt.outcome;
    if !verified {
        outcome = Outcome { status: Status.Failed, message: "readback did not match the restored profile" };
    }
    var word: u8[>..] = [];
    word.append("restored");
    return ToolDispatch {
        outcome: outcome,
        result_json: mutation_body(word, receipt, after, verified),
        simulated: true,
        verified: verified,
        profile_id: after,
    };
}

// One allowlisted tool against the simulator. Tools outside the six are
// rejected. Nothing here returns a discovered network, an inspected host,
// or verified:true that the actuator did not read back.
fn dispatch_sim_tool(envelope: const u8[:], run_id: const u8[:]) -> ToolDispatch {
    if run_id.len == 0 {
        return failed_dispatch("controller: run_id required");
    }
    var doc: json::Node[>..] = [];
    var decoded: u8[>..] = [];
    let root, err = json::parse(envelope, doc, decoded);
    if !root {
        return rejected_dispatch("envelope is not JSON");
    }
    let tool, has_tool = json::as_string(json::member(root, "tool"));
    if !has_tool || !six_tool(tool) {
        return rejected_dispatch("tool is not one of the six");
    }
    if tool == "read_observation" {
        return dispatch_read(envelope, ToolName.ReadObservation, run_id);
    }
    if tool == "read_task_context" {
        return dispatch_read(envelope, ToolName.ReadTaskContext, run_id);
    }
    if tool == "list_profiles" {
        return dispatch_read(envelope, ToolName.ListProfiles, run_id);
    }
    if tool == "read_action_result" {
        return dispatch_read(envelope, ToolName.ReadActionResult, run_id);
    }
    if tool == "apply_profile" {
        return dispatch_apply(envelope, run_id);
    }
    return dispatch_restore(envelope, run_id);
}

fn loop_step(report: SimLoopReport&, step: ToolDispatch) -> bool {
    if step.outcome.status != Status.Completed {
        report.outcome = step.outcome;
        return false;
    }
    return true;
}

// The six documented tools, in order, against the simulator. No model
// call. model_calls stays 0 so this cannot be reported as the live leg.
fn run_simulated_loop(run_id: const u8[:]) -> SimLoopReport {
    var report = SimLoopReport { simulated: true };
    if run_id.len == 0 {
        report.outcome = Outcome { status: Status.Failed, message: "controller: run_id required" };
        return report;
    }
    actuator_forget_state();
    sim_reset(7);
    let obs = dispatch_sim_tool(
        "{\"tool\":\"read_observation\",\"arguments\":{\"path_id\":\"sim0\",\"max_age_ms\":1000}}",
        run_id);
    if !loop_step(report, obs) { return report; }
    report.observation_id = obs.observation_id;
    report.loaded_rtt_ms = obs.loaded_rtt_ms;
    var task_env: u8[>..] = [];
    task_env.append("{\"tool\":\"read_task_context\",\"arguments\":{\"run_id\":");
    json::format_string(task_env, run_id);
    task_env.append("}}");
    if !loop_step(report, dispatch_sim_tool(task_env, run_id)) { return report; }
    if !loop_step(report, dispatch_sim_tool(
        "{\"tool\":\"list_profiles\",\"arguments\":{\"scope_id\":\"lab-sim\"}}",
        run_id)) { return report; }
    let applied = dispatch_sim_tool(
        "{\"tool\":\"apply_profile\",\"arguments\":{\"request_id\":\"loop-apply\",\"scope_id\":\"lab-sim\",\"path_id\":\"sim0\",\"profile_id\":\"sqm-fair\",\"observation_id\":\"sim-obs\",\"task_revision\":1,\"route_epoch\":3,\"config_revision\":7,\"lease_ms\":10000,\"rationale\":\"drain the bloated queue\"}}",
        run_id);
    report.saw_sqm = applied.verified && sim_current_profile_id() == "sqm-fair";
    if !loop_step(report, applied) || !report.saw_sqm {
        if report.outcome.status == Status.Completed || report.outcome.message.len == 0 {
            report.outcome = Outcome { status: Status.Failed, message: "simulated apply did not read back" };
        }
        return report;
    }
    if !loop_step(report, dispatch_sim_tool(
        "{\"tool\":\"read_action_result\",\"arguments\":{\"action_id\":\"loop-apply\"}}",
        run_id)) { return report; }
    let restored = dispatch_sim_tool(
        "{\"tool\":\"restore_profile\",\"arguments\":{\"request_id\":\"loop-restore\",\"scope_id\":\"lab-sim\",\"lease_id\":\"loop-apply\",\"expected_revision\":7,\"observation_id\":\"sim-obs\",\"rationale\":\"lease done\"}}",
        run_id);
    report.profile_after = sim_current_profile_id();
    report.restored = restored.verified && report.profile_after == "baseline-fifo";
    if !loop_step(report, restored) || !report.restored {
        report.outcome = Outcome { status: Status.Failed, message: "simulated restore did not read back" };
        return report;
    }
    report.applied = true;
    report.outcome = Outcome { status: Status.Completed, message: "simulated six-tool loop" };
    return report;
}

// Two labelled worlds. The loop does not choose between them, and it does
// not apply because a case looks congested. Unknown names change nothing.
fn arm_case(name: const u8[:]) -> bool {
    if name == "queue" {
        sim_reset(11);
        sim_set_load(1.0);
        sim_set_provider_ms(0.0);
        return set_case_task("fetch", 8000, "interactive evidence fetch with a deadline this window");
    }
    if name == "provider" {
        sim_reset(11);
        sim_set_load(0.1);
        sim_set_provider_ms(400.0);
        return set_case_task("bulk", 600000, "bulk transfer with no deadline this window");
    }
    return false;
}

// The view the model is given: the observation, the task, and the catalogue.
// It lists profiles. It does not name an action.
fn participant_context(run_id: const u8[:]) -> u8[>..] {
    var ctx: u8[>..] = [];
    if run_id.len == 0 {
        return ctx;
    }
    let obs = read_observation("sim0");
    if obs.outcome.status != Status.Completed {
        return ctx;
    }
    let task = read_task_context(run_id);
    if task.outcome.status != Status.Completed {
        return ctx;
    }
    let listed = list_profiles("lab-sim");
    ctx.append("{\"simulated\":true,\"run_id\":");
    json::format_string(ctx, run_id);
    ctx.append(",\"observation\":");
    ctx.append(observation_body(obs.observation));
    ctx.append(",\"task\":");
    ctx.append(task_body(task.context));
    ctx.append(",\"profiles\":");
    ctx.append(profile_list_body(listed));
    ctx.append("}");
    return ctx;
}

fn opening_input(context: const u8[:], out: u8[>..]&) -> bool {
    if context.len == 0 || context.len > 8192 {
        return false;
    }
    out.append("[{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":");
    json::format_string(out, context);
    out.append("}]}]");
    return true;
}

// Recorded replies for the contract test. The live path never reads this
// queue. Eight is the tool-round cap, so a longer script cannot hide here.
var reply_q: ModelResult[..8] = [];
var reply_n: i64 = 0;
var reply_i: i64 = 0;

fn participant_clear() {
    reply_n = 0;
    reply_i = 0;
}

fn participant_push(reply: ModelResult) -> bool {
    if reply_n >= 8 {
        return false;
    }
    if reply_n < reply_q.len {
        reply_q[reply_n] = reply;
    } else {
        reply_q.push(reply);
    }
    reply_n += 1;
    return true;
}

fn participant_take() -> ModelResult, bool {
    if reply_i >= reply_n || reply_i >= reply_q.len {
        return ModelResult {}, false;
    }
    let reply = reply_q[reply_i];
    reply_i += 1;
    return reply, true;
}

struct ParticipantReport {
    outcome: Outcome = Outcome {},
    scripted: bool = false,
    model_calls: i64 = 0,
    applied: bool = false,
    abstained: bool = false,
    receipt_replayed: bool = false,
    profile_after: u8[..64] = "",
    rounds: i64 = 0,
}

fn participant_done(report: ParticipantReport, status: Status, message: const u8[:]) -> ParticipantReport {
    var out = report;
    out.profile_after = sim_current_profile_id();
    out.outcome = Outcome { status: status, message: message };
    return out;
}

// Recorded replies exercise the same dispatch the live command uses. A
// missing reply ends the script; it is not an abstain, and it is not an
// apply. This function does not call the model. The live command is in
// main, so a test run does not link the HTTPS adapter.
fn run_participant(run_id: const u8[:], case_name: const u8[:],
        config: ModelConfig, scripted: bool) -> ParticipantReport {
    var report = ParticipantReport { scripted: true };
    if !scripted {
        return participant_done(report, Status.Failed, "participant: recorded entry only");
    }
    if run_id.len == 0 {
        return participant_done(report, Status.Failed, "participant: run_id required");
    }
    if config.max_tool_rounds < 1 || config.max_tool_rounds > 8 {
        return participant_done(report, Status.Failed, "participant: tool round cap invalid");
    }
    if !arm_case(case_name) {
        return participant_done(report, Status.Failed, "participant: unknown case");
    }
    let ctx = participant_context(run_id);
    var sent_input: u8[>..] = [];
    if !opening_input(ctx, sent_input) {
        return participant_done(report, Status.Failed, "participant: context invalid");
    }
    reply_i = 0;
    while true {
        if report.rounds >= config.max_tool_rounds {
            return participant_done(report, Status.Completed, "participant budget");
        }
        let got, ok = participant_take();
        if !ok {
            if report.model_calls == 0 {
                return participant_done(report, Status.Failed, "participant: no recorded reply");
            }
            return participant_done(report, Status.Completed, "recorded replies ended");
        }
        if got.outcome.status != Status.Completed {
            report.outcome = got.outcome;
            report.profile_after = sim_current_profile_id();
            return report;
        }
        report.rounds += 1;
        report.model_calls += 1;
        if !got.has_tool_call {
            report.abstained = true;
            return participant_done(report, Status.Completed, "participant abstained");
        }
        let dispatched = dispatch_sim_tool(tool_envelope(got.tool, got.arguments_json), run_id);
        if got.tool == ToolName.ApplyProfile && dispatched.verified {
            report.applied = true;
        }
        var folded: u8[>..] = [];
        if meta_replay_input(sent_input, got.raw_output_json, got.call_id, dispatched.result_json, folded) {
            report.receipt_replayed = true;
            sent_input = [];
            sent_input.append(folded);
        }
    }
    return participant_done(report, Status.Failed, "participant: loop ended");
}

// Live entry. The model sees the case, calls tools, and gets each receipt
// back. This function does not name a profile. It is not called by the
// recorded-reply tests.
fn run_participant_live(run_id: const u8[:], case_name: const u8[:],
        config: ModelConfig) -> ParticipantReport {
    var report = ParticipantReport {};
    if run_id.len == 0 {
        return participant_done(report, Status.Failed, "participant: run_id required");
    }
    if config.max_tool_rounds < 1 || config.max_tool_rounds > 8 {
        return participant_done(report, Status.Failed, "participant: tool round cap invalid");
    }
    if config.controller_model.len == 0 || config.base_url.len == 0 {
        return participant_done(report, Status.Failed, "controller: model/config required");
    }
    if !arm_case(case_name) {
        return participant_done(report, Status.Failed, "participant: unknown case");
    }
    let ctx = participant_context(run_id);
    var sent_input: u8[>..] = [];
    if !opening_input(ctx, sent_input) {
        return participant_done(report, Status.Failed, "participant: context invalid");
    }
    var next_input: u8[>..] = [];
    var held_output: u8[>..] = [];
    var held_receipt: u8[>..] = [];
    var held_response: u8[>..] = [];
    var held_call: u8[>..] = [];
    while true {
        if report.rounds >= config.max_tool_rounds {
            return participant_done(report, Status.Completed, "participant budget");
        }
        var mres = ModelResult {};
        if report.rounds == 0 {
            var mreq = ModelRequest {};
            mreq.request_id = run_id;
            mreq.run_id = run_id;
            mreq.role_id = "controller";
            mreq.context = ctx;
            mreq.prompt_revision = "controller.md";
            mres = request_meta(config, mreq);
        } else {
            mres = submit_tool_result(config, run_id, held_response, held_call,
                sent_input, held_output, held_receipt);
            sent_input = [];
            sent_input.append(next_input);
        }
        if mres.outcome.status != Status.Completed {
            report.outcome = mres.outcome;
            report.profile_after = sim_current_profile_id();
            return report;
        }
        if mres.provenance != Provenance.Live {
            return participant_done(report, Status.Failed, "participant model call was not live");
        }
        report.rounds += 1;
        report.model_calls += 1;
        if !mres.has_tool_call {
            report.abstained = true;
            return participant_done(report, Status.Completed, "participant abstained");
        }
        let dispatched = dispatch_sim_tool(tool_envelope(mres.tool, mres.arguments_json), run_id);
        if mres.tool == ToolName.ApplyProfile && dispatched.verified {
            report.applied = true;
        }
        var folded: u8[>..] = [];
        if meta_replay_input(sent_input, mres.raw_output_json, mres.call_id, dispatched.result_json, folded) {
            report.receipt_replayed = true;
            next_input = [];
            next_input.append(folded);
        }
        held_output = [];
        held_output.append(mres.raw_output_json);
        held_receipt = [];
        held_receipt.append(dispatched.result_json);
        held_response = [];
        held_response.append(mres.response_id);
        held_call = [];
        held_call.append(mres.call_id);
    }
    return participant_done(report, Status.Failed, "participant: loop ended");
}

// Fail-closed probe. Empty state never reaches a model call. A configured
// state does not invent one either: the live entry is --loop.
fn controller_tick(state: ControllerState, config: ModelConfig) -> Outcome {
    if state.run_id.len == 0 {
        return Outcome { status: Status.Failed, message: "controller: run_id required" };
    }
    if config.controller_model.len == 0 || config.base_url.len == 0 {
        return Outcome { status: Status.Failed, message: "controller: model/config required" };
    }
    return Outcome { status: Status.Failed, message: "controller: live entry is --loop" };
}
