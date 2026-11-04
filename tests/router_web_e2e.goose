// End-to-end (item 6): the full Goose loop against the virtual router
// over real HTTP. NOT part of `make test`: it talks to the C++ double
// (tests/router_double.cpp), which `make web-e2e-run` spawns itself
// with a test-only password. ROUTER_HOST/ROUTER_PORT/ROUTER_PASSWORD
// can still point the binary at any other double instance.
//
//   make web-e2e-run        # self-contained
//
// What it proves: an envelope validated by tooljson, admitted by the
// guardian, applied through the C++ transport to a router that bumps its
// revision, verified by readback, restored, and reconciled - with the lease
// echo checked at every step. Exit 0 prints WEB_E2E_ALL_GREEN.
import lib from "../src";
import std;
import os;
import json;

fn check(cond: bool, label: const u8[:]) {
    if !cond {
        print("FAIL ", label);
        abort(str("web_e2e contract violated: ", label));
    }
    print("ok ", label);
}

fn getenv_into(name: const u8[:], fallback: const u8[:], out: u8[>..]&) {
    var v: u8[>..] = [];
    if env(name, v) && v.len > 0 && v.len <= 256 {
        out.append(v);
        return;
    }
    out.append(fallback);
}

fn getenv_i64(name: const u8[:], fallback: i64) -> i64 {
    var v: u8[>..] = [];
    if env(name, v) && v.len > 0 && v.len < 20 {
        var doc: json::Node[>..] = [];
        var decoded: u8[>..] = [];
        let root, err = json::parse(v, doc, decoded);
        let n, is_i = json::as_i64(root);
        if is_i {
            return n;
        }
    }
    return fallback;
}

fn main() {
    var host_b: u8[>..] = [];
    getenv_into("ROUTER_HOST", "127.0.0.1", host_b);
    let port = getenv_i64("ROUTER_PORT", 18081);
    continuum::beat("e2e-start", "web loop against virtual router");

    // One bloated observation from the sim, one validated apply envelope.
    // The envelope carries the ten arguments schemas/meta-tools.json
    // requires; every value is chosen to satisfy the guardian below
    // (owned lab-sim profile, sim-obs evidence, epoch 3, lease in bounds).
    continuum::sim_reset(77);
    let obs = continuum::sim_observe("sim0", 0).observation;
    check(continuum::bloat_detected(obs, 100.0), "sim is bloated");
    var env_text: u8[>..] = [];
    env_text.append("{\"tool\":\"apply_profile\",\"arguments\":{");
    env_text.append("\"request_id\":\"web-req-1\",");
    env_text.append("\"scope_id\":\"lab-sim\",\"path_id\":\"sim0\",");
    env_text.append("\"profile_id\":\"sqm-fair\",\"observation_id\":\"sim-obs\",");
    env_text.append("\"task_revision\":1,\"route_epoch\":3,");
    env_text.append("\"config_revision\":1,\"lease_ms\":10000,");
    env_text.append("\"rationale\":\"web e2e: drain bloated queue with fair profile\"}}");
    let vc0 = continuum::validate_apply_call(env_text);
    check(vc0.ok, "tooljson validates the apply envelope");
    let cat = continuum::list_profiles("lab-sim");
    check(cat.profiles.len == 2, "catalogue lists both sim profiles");
    let fair = cat.profiles[1];
    check(fair.profile_id == "sqm-fair", "slot 1 is the fair profile");

    // Dispatch binding (the controller's job, not the model's): the envelope
    // carries no revision; the dispatcher stamps the catalogue revision the
    // guardian must match before admission.
    var vc = vc0;
    vc.request.expected_revision = fair.revision;
    let adm = continuum::admit_action(vc.request, obs, fair, continuum::sim_now_ms());
    check(adm.admitted, "guardian admits the validated request");

    let before = continuum::web_reconcile("lab-sim", "probe", 0, host_b, port);
    check(before.revision >= 0, "pre-apply revision reads back");
    print("WEB-E2E pre revision=", before.revision);

    let ap = continuum::web_apply(fair.profile_id, fair.configured_rate_kbit / 1000,
        "lab-sim", adm.action_id, fair.revision, host_b, port);
    check(ap.ok && ap.verified, "apply returns a verified receipt");
    check(ap.revision == before.revision + 1, "router revision advances by exactly one");
    print("WEB-E2E applied verified revision=", ap.revision);
    continuum::beat("e2e-apply", "virtual router applied and verified");

    let sync = continuum::web_reconcile("lab-sim", adm.action_id, ap.revision,
        host_b, port);
    check(sync.ok, "reconcile confirms the applied revision");
    check(sync.revision == ap.revision, "reconciled revision matches the receipt");
    print("WEB-E2E reconcile in_sync revision=", sync.revision);

    let rs = continuum::web_restore("lab-sim", adm.action_id, ap.revision, host_b, port);
    check(rs.ok && rs.verified, "restore returns a verified receipt");
    let after = continuum::web_reconcile("lab-sim", adm.action_id, ap.revision,
        host_b, port);
    check(!after.ok, "post-restore state reports drift");
    print("WEB-E2E restored, drift reported as expected");
    continuum::beat("e2e-done", "web loop green");

    // The participant must drive this SAME HTTP actuator. Previously the
    // router proof above ran beside a model loop that only mutated sim.
    check(continuum::controller_select_router(host_b, port), "HTTP actuator selected");
    let baseline = continuum::web_qos(host_b, port);
    continuum::participant_clear();
    check(continuum::participant_push(reply(continuum::ToolName.ApplyProfile,
        "model-apply", str("{\"request_id\":\"model-apply\",\"scope_id\":\"lab-sim\",",
        "\"path_id\":\"sim0\",\"profile_id\":\"sqm-fair\",\"observation_id\":\"sim-obs\",",
        "\"task_revision\":1,\"route_epoch\":3,\"config_revision\":", baseline.revision,
        ",\"lease_ms\":10000,\"rationale\":\"controlled queue experiment\"}"))), "model apply queued");
    check(continuum::participant_push(reply(continuum::ToolName.ReadActionResult,
        "model-read", "{\"action_id\":\"model-apply\"}")), "model readback queued");
    check(continuum::participant_push(reply(continuum::ToolName.RestoreProfile,
        "model-restore", str("{\"request_id\":\"model-restore\",\"scope_id\":\"lab-sim\",",
        "\"lease_id\":\"model-apply\",\"expected_revision\":", baseline.revision + 1,
        ",\"observation_id\":\"sim-obs\",\"rationale\":\"experiment finished\"}"))), "model restore queued");
    var done = continuum::ModelResult {};
    done.outcome = continuum::Outcome { status: continuum::Status.Completed, message: "recorded final" };
    done.raw_output_json = "[{\"type\":\"message\"}]";
    check(continuum::participant_push(done), "model final queued");
    var config = continuum::ModelConfig {};
    config.max_tool_rounds = 4;
    let participant = continuum::run_participant("http-participant", "queue", config, true);
    let landed = continuum::web_qos(host_b, port);
    check(landed.ok && landed.revision == baseline.revision + 2,
        "participant tool requests reach the selected HTTP router");
    check(participant.applied && participant.restored, "participant reports verified apply and restore");
    check(landed.qos_on == baseline.qos_on && landed.rate_mbit == baseline.rate_mbit,
        "participant restores the actual starting configuration");
    check(continuum::sim_current_profile_id() == "baseline-fifo", "HTTP dispatch never mutates sim");
    check(participant.replay_json.find("model-apply") >= 0
        && participant.replay_json.find("verified") >= 0,
        "model continuation contains execution receipts");
    check(continuum::controller_select_sim(), "HTTP session releases authority");

    // A non-default starting state catches a restore that merely switches
    // QoS off. These are authored responses, NOT calls to Meta. The live
    // command uses the same session/dispatch/validation/cleanup functions.
    check(continuum::web_apply("seed-config", 75, "lab-sim", "seed-lease",
        landed.revision, host_b, port).verified, "non-default baseline staged");
    for variant in 0..3 {
        check(continuum::controller_select_router(host_b, port), "protected HTTP target selected");
        let start = continuum::web_qos(host_b, port);
        let run_id = str("protected-", variant);
        let apply_id = str(run_id, ":apply");
        continuum::participant_clear();
        check(continuum::participant_push(reply(continuum::ToolName.ApplyProfile,
            apply_id, str("{\"request_id\":\"", apply_id, "\",\"scope_id\":\"lab-sim\",",
            "\"path_id\":\"sim0\",\"profile_id\":\"sqm-fair\",\"observation_id\":\"sim-obs\",",
            "\"task_revision\":1,\"route_epoch\":3,\"config_revision\":", start.revision,
            ",\"lease_ms\":60000,\"rationale\":\"protect the useful task\"}"))), "protection decision queued");
        done.provenance = continuum::Provenance.Recorded;
        check(continuum::participant_push(done), "controller final queued");
        var task = audit_reply(run_id);
        if variant == 1 { task.text = "hold deployment: not JSON"; }
        if variant == 2 {
            task.outcome = continuum::Outcome { status: continuum::Status.Failed, message: "recorded provider outage" };
            task.text = "";
        }
        check(continuum::participant_push(task), "task response queued");
        let protected = continuum::run_protected_task(run_id, "queue", config, true);
        let end = continuum::web_qos(host_b, port);
        check(protected.applied && protected.task_profile == "sqm-fair",
            "task executes under the model-requested intervention");
        check(protected.restored && end.ok && end.qos_on == start.qos_on
            && end.rate_mbit == start.rate_mbit && end.revision == start.revision + 2,
            "success and failures restore the exact non-default baseline");
        check(continuum::sim_current_profile_id() == "baseline-fifo"
            && continuum::active_task.run_id.len == 0, "session retires without sim or task leakage");
        if variant == 0 {
            check(protected.outcome.status == continuum::Status.Completed
                && protected.task.independently_validated && !protected.task.committed,
                "valid workload completes without claiming an unwritten checkpoint");
            check(protected.task.provenance == continuum::Provenance.Recorded,
                "authored workload cannot claim live model provenance");
            let record_text = continuum::session_record(protected);
            var record_doc: json::Node[>..] = [];
            var record_dec: u8[>..] = [];
            let record, record_err = json::parse(record_text, record_doc, record_dec);
            let task_result = json::member(record, "task_result");
            let result_run, has_run = json::as_string(json::member(task_result, "run_id"));
            check(has_run && result_run == run_id, "one parseable run record contains the validated result");
            print("SUPERVISED_RECORD ", continuum::session_record(protected));
        } else {
            check(protected.outcome.status != continuum::Status.Completed
                && !protected.task.independently_validated,
                "malformed output and provider outages cannot become task success");
        }
        check(continuum::controller_select_sim(), "protected session releases authority");
    }
    check(!continuum::controller_select_router("192.0.2.1", port),
        "synthetic evidence cannot open a physical router target");
    print("WEB_E2E_ALL_GREEN");
}

fn reply(tool: continuum::ToolName, call_id: const u8[:], arguments: const u8[:]) -> continuum::ModelResult {
    var r = continuum::ModelResult {};
    r.outcome = continuum::Outcome { status: continuum::Status.Completed, message: "recorded tool" };
    r.tool = tool;
    r.has_tool_call = true;
    r.call_id = call_id;
    r.response_id = "recorded-response";
    r.arguments_json = arguments;
    r.raw_output_json = str("[{\"type\":\"function_call\",\"call_id\":\"", call_id, "\"}]");
    r.provenance = continuum::Provenance.Recorded;
    return r;
}

fn audit_reply(run_id: const u8[:]) -> continuum::ModelResult {
    return continuum::ModelResult {
        outcome: continuum::Outcome { status: continuum::Status.Completed },
        provenance: continuum::Provenance.Recorded, provider_model_id: "authored-response",
        text: str("{\"schema_version\":\"1.0\",\"run_id\":\"", run_id,
            "\",\"task_id\":\"release-audit\",\"task_revision\":1,\"decision\":\"hold\",",
            "\"findings\":[{\"finding_id\":\"REL-17\",\"severity\":\"blocker\",",
            "\"summary\":\"Candidate rollback rehearsal has not passed.\",",
            "\"evidence_ids\":[\"ci-summary:v1\",\"rollout-policy:v1\"]},",
            "{\"finding_id\":\"SEC-42\",\"severity\":\"blocker\",",
            "\"summary\":\"High-severity authorization defect has no approved exception.\",",
            "\"evidence_ids\":[\"security-review:v1\",\"rollout-policy:v1\"]}],",
            "\"missing_evidence_ids\":[],\"summary\":\"Hold for the two unresolved policy blockers.\"}"),
    };
}
