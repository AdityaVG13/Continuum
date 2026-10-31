// Simulated six-tool controller: the mechanical loop, not a model.
// Failure-first against the tick that returned canned discovery success
// and a constructed verified:true. No key, no socket, no scripted model
// response. Run: goose run tests/sim_controller.goose
import lib from "../src";
import std;

fn check(cond: bool, label: const u8[:]) {
    if !cond {
        print("FAIL ", label);
        abort(str("sim_controller contract violated: ", label));
    }
    print("ok ", label);
}

fn has(text: const u8[:], needle: const u8[:]) -> bool {
    return text.find(needle) >= 0;
}

fn apply_env(request_id: const u8[:], config_revision: i64) -> u8[>..] {
    return str("{\"tool\":\"apply_profile\",\"arguments\":{",
        "\"request_id\":\"", request_id, "\",\"scope_id\":\"lab-sim\",\"path_id\":\"sim0\",",
        "\"profile_id\":\"sqm-fair\",\"observation_id\":\"sim-obs\",",
        "\"task_revision\":1,\"route_epoch\":3,\"config_revision\":", config_revision,
        ",\"lease_ms\":10000,\"rationale\":\"drain the bloated queue\"}}");
}

fn main() {
    continuum::sim_reset(7);
    continuum::actuator_forget_state();

    let discover = continuum::dispatch_sim_tool(
        "{\"tool\":\"discover_topology\",\"arguments\":{\"path_id\":\"sim0\",\"scope_id\":\"lab-sim\"}}",
        "loop-1");
    check(discover.outcome.status == continuum::Status.Rejected, "discover is not a tool");
    check(!discover.verified, "discover does not verify");
    check(!has(discover.result_json, "discovered"), "discover receipt is not a success");
    check(!has(discover.result_json, "compiled_auto"), "discover receipt invents no ruleset");
    check(continuum::sim_current_profile_id() == "baseline-fifo", "discover mutates nothing");

    let inspect = continuum::dispatch_sim_tool(
        "{\"tool\":\"inspect_system\",\"arguments\":{\"path_id\":\"sim0\",\"what\":\"qdisc\"}}",
        "loop-1");
    check(inspect.outcome.status == continuum::Status.Rejected, "inspect is not a tool");
    check(!has(inspect.result_json, "inspected"), "inspect receipt is not a success");

    let propose = continuum::dispatch_sim_tool(
        "{\"tool\":\"propose_ruleset\",\"arguments\":{\"path_id\":\"sim0\"}}",
        "loop-1");
    check(propose.outcome.status == continuum::Status.Rejected, "propose is not a tool");
    check(!has(propose.result_json, "accepted"), "propose receipt is not accepted");

    let obs = continuum::dispatch_sim_tool(
        "{\"tool\":\"read_observation\",\"arguments\":{\"path_id\":\"sim0\",\"max_age_ms\":1000}}",
        "loop-1");
    let fresh = continuum::sim_observe("sim0", 0);
    check(obs.outcome.status == continuum::Status.Completed, "observation read completes");
    check(obs.observation_id == "sim-obs", "observation id is the sim window");
    check(obs.loaded_rtt_ms == fresh.observation.loaded_rtt_ms, "observation rtt is the sim window");
    check(has(obs.result_json, "sim-obs"), "observation receipt names the window");
    check(has(obs.result_json, "metrics_known"), "observation receipt carries evidence");
    check(!has(obs.result_json, "\"status\":\"ok\""), "observation receipt is not a canned ok");

    let task = continuum::dispatch_sim_tool(
        "{\"tool\":\"read_task_context\",\"arguments\":{\"run_id\":\"loop-1\"}}",
        "loop-1");
    check(task.outcome.status == continuum::Status.Completed, "task context completes");
    check(has(task.result_json, "loop-1"), "task receipt names the run");
    check(has(task.result_json, "audit"), "task receipt is the lab audit context");
    check(!has(task.result_json, "\"status\":\"ok\""), "task receipt is not a canned ok");

    let profiles = continuum::dispatch_sim_tool(
        "{\"tool\":\"list_profiles\",\"arguments\":{\"scope_id\":\"lab-sim\"}}",
        "loop-1");
    check(profiles.outcome.status == continuum::Status.Completed, "profile list completes");
    check(has(profiles.result_json, "baseline-fifo"), "catalogue includes the fifo profile");
    check(has(profiles.result_json, "sqm-fair"), "catalogue includes the fair profile");
    check(!has(profiles.result_json, "\"status\":\"ok\""), "profile receipt is not a canned ok");

    let bad = continuum::dispatch_sim_tool(apply_env("disp-badrev", 1), "loop-1");
    check(bad.outcome.status == continuum::Status.Rejected, "wrong revision is rejected");
    check(!bad.verified, "rejected apply is not verified");
    check(!has(bad.result_json, "\"verified\":true"), "rejected receipt does not claim verified");
    check(continuum::sim_current_profile_id() == "baseline-fifo", "rejected apply does not mutate");

    let applied = continuum::dispatch_sim_tool(apply_env("disp-apply", 7), "loop-1");
    let readback = continuum::read_action_result("disp-apply");
    check(applied.outcome.status == continuum::Status.Completed, "admitted apply completes");
    check(applied.verified, "apply verified only after readback");
    check(applied.verified == readback.verification_complete, "verified is the actuator readback");
    check(applied.profile_id == "sqm-fair", "apply receipt names the readback profile");
    check(continuum::sim_current_profile_id() == "sqm-fair", "apply changed the sim");
    check(has(applied.result_json, "sqm-fair"), "apply receipt json names the readback profile");
    check(has(applied.result_json, "\"verified\":true"), "matching readback is verified");
    check(has(applied.result_json, "disp-apply"), "apply receipt names the lease");

    let again = continuum::dispatch_sim_tool(
        "{\"tool\":\"read_action_result\",\"arguments\":{\"action_id\":\"disp-apply\"}}",
        "loop-1");
    check(again.outcome.status == continuum::Status.Completed, "action read completes");
    check(again.verified == readback.verification_complete, "action read is the stored readback");
    check(has(again.result_json, "sqm-fair"), "action read names the current profile");

    let restored = continuum::dispatch_sim_tool(
        "{\"tool\":\"restore_profile\",\"arguments\":{\"request_id\":\"disp-restore\",\"scope_id\":\"lab-sim\",\"lease_id\":\"disp-apply\",\"expected_revision\":7,\"observation_id\":\"sim-obs\",\"rationale\":\"lease done\"}}",
        "loop-1");
    check(restored.outcome.status == continuum::Status.Completed, "restore completes");
    check(restored.verified, "restore verified only after readback");
    check(restored.profile_id == "baseline-fifo", "restore receipt names the readback profile");
    check(continuum::sim_current_profile_id() == "baseline-fifo", "restore returned the sim");
    check(has(restored.result_json, "baseline-fifo"), "restore receipt json names the readback profile");

    let report = continuum::run_simulated_loop("loop-run");
    check(report.outcome.status == continuum::Status.Completed, "simulated loop completes");
    check(report.simulated, "loop is labelled simulated");
    check(report.model_calls == 0, "loop spends no model call");
    check(report.saw_sqm, "loop applied the fair profile");
    check(report.profile_after == "baseline-fifo", "loop restored the fifo profile");
    check(report.observation_id == "sim-obs", "loop observed the sim window");

    // Participant loop. The mechanical walk above still spends no model
    // call. These checks drive the same dispatch with recorded replies so
    // a missing key cannot hide a substituted profile.
    continuum::sim_apply("sqm-fair");
    check(!continuum::arm_case("nope"), "unknown case is refused");
    check(continuum::sim_current_profile_id() == "sqm-fair", "refused case mutates nothing");

    check(continuum::arm_case("queue"), "queue case arms");
    let qobs = continuum::sim_observe("sim0", 0).observation;
    check(qobs.loaded_rtt_ms > 300.0, "queue case is a saturated fifo");
    check(qobs.provider_service_ms == 0.0, "queue case delay is not the provider");
    check(qobs.utilization == 1.0, "queue case is the full link");
    let qtask = continuum::read_task_context("case-queue");
    check(qtask.context.deadline_at_ms == 8000, "queue task deadline is this window");
    check(has(qtask.context.task_summary, "interactive evidence fetch"), "queue task is the fetch");
    let qctx = continuum::participant_context("case-queue");
    check(has(qctx, "interactive evidence fetch"), "queue context carries the task");
    check(has(qctx, "sqm-fair"), "queue context lists the catalogue");
    check(has(qctx, "provider_service_ms"), "queue context carries the provider field");
    check(!has(qctx, "apply_profile"), "queue context does not name the action");

    check(continuum::arm_case("provider"), "provider case arms");
    let pobs = continuum::sim_observe("sim0", 0).observation;
    check(pobs.provider_service_ms == 400.0, "provider case names the provider delay");
    check(pobs.utilization < 0.2, "provider case is not a full queue");
    let ptask = continuum::read_task_context("case-provider");
    check(ptask.context.deadline_at_ms == 600000, "provider task can wait");
    check(has(ptask.context.task_summary, "bulk transfer"), "provider task is the bulk transfer");
    let pctx = continuum::participant_context("case-provider");
    check(has(pctx, "bulk transfer"), "provider context carries the task");
    check(has(pctx, "provider_service_ms"), "provider context carries the delay");

    var cfg = continuum::ModelConfig {};
    cfg.max_tool_rounds = 4;
    cfg.max_output_tokens = 2048;
    continuum::participant_clear();
    check(continuum::participant_push(abstain_reply()), "queue abstain recorded");
    let abstained = continuum::run_participant("case-queue", "queue", cfg, true);
    check(abstained.outcome.status == continuum::Status.Completed, "queue abstain completes");
    check(abstained.scripted && abstained.model_calls == 1, "queue abstain spent the recorded reply");
    check(abstained.abstained && !abstained.applied, "queue abstain is not an apply");
    check(abstained.profile_after == "baseline-fifo", "queue abstain leaves fifo");
    check(continuum::sim_current_profile_id() == "baseline-fifo", "loop did not substitute sqm-fair");

    continuum::participant_clear();
    check(continuum::participant_push(apply_reply("sqm-fair", "case-apply")), "queue apply recorded");
    let applied_case = continuum::run_participant("case-apply", "queue", cfg, true);
    check(applied_case.applied, "recorded apply landed");
    check(applied_case.profile_after == "sqm-fair", "recorded apply read back");
    check(applied_case.receipt_replayed, "apply receipt is replayable");
    check(!applied_case.abstained, "recorded apply is not an abstain");
    check(applied_case.model_calls == 1, "recorded apply spent one reply");

    continuum::participant_clear();
    check(continuum::participant_push(apply_reply("not-a-profile", "case-bad")), "bad profile recorded");
    let rejected = continuum::run_participant("case-bad", "queue", cfg, true);
    check(!rejected.applied, "unknown profile is not applied");
    check(rejected.profile_after == "baseline-fifo", "rejected apply leaves fifo");
    check(rejected.receipt_replayed, "rejection receipt is replayable");
    check(continuum::sim_current_profile_id() == "baseline-fifo", "rejected apply mutates nothing");

    continuum::participant_clear();
    check(continuum::participant_push(read_reply("call-r1")), "budget reply 1");
    check(continuum::participant_push(read_reply("call-r2")), "budget reply 2");
    check(continuum::participant_push(read_reply("call-r3")), "budget reply 3");
    var short_cfg = continuum::ModelConfig {};
    short_cfg.max_tool_rounds = 2;
    let budget = continuum::run_participant("case-budget", "provider", short_cfg, true);
    check(budget.outcome.status == continuum::Status.Completed, "budget stop completes");
    check(budget.model_calls == 2 && budget.rounds == 2, "budget stops at the cap");
    check(!budget.applied && !budget.abstained, "budget does not invent an apply or an abstain");
    check(budget.profile_after == "baseline-fifo", "budget leaves the path alone");

    let prior_in = "[{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"case\"}]}]";
    let prior_out = "[{\"type\":\"function_call\",\"call_id\":\"call-9\"}]";
    let receipt = "{\"status\":\"rejected\",\"reason\":\"profile is not in the catalogue\"}";
    var replayed: u8[>..] = [];
    check(continuum::meta_replay_input(prior_in, prior_out, "call-9", receipt, replayed),
        "replay builds");
    check(replayed != "[]", "replay is not the empty array the old tick sent");
    check(replayed.len > 2 && has(replayed, "profile is not in the catalogue"),
        "replay carries the receipt");
    var cbody: u8[>..] = [];
    check(continuum::meta_continuation_body(cfg, "muse-wonder-1.0",
            "You are the controller.", replayed, prior_out,
            "call-9", receipt, "[]", cbody),
        "replay is a continuation input");

    print("SIM_CONTROLLER_ALL_GREEN");
}

fn abstain_reply() -> continuum::ModelResult {
    var r = continuum::ModelResult {};
    r.outcome = continuum::Outcome { status: continuum::Status.Completed, message: "scripted abstain" };
    r.has_tool_call = false;
    r.response_id = "resp-abs";
    r.provenance = continuum::Provenance.Synthetic;
    r.raw_output_json = "[{\"type\":\"message\"}]";
    return r;
}

fn apply_reply(profile_id: const u8[:], request_id: const u8[:]) -> continuum::ModelResult {
    var r = continuum::ModelResult {};
    r.outcome = continuum::Outcome { status: continuum::Status.Completed, message: "scripted apply" };
    r.has_tool_call = true;
    r.tool = continuum::ToolName.ApplyProfile;
    r.call_id = "call-apply";
    r.response_id = "resp-apply";
    r.provenance = continuum::Provenance.Synthetic;
    r.arguments_json = str("{\"request_id\":\"", request_id,
        "\",\"scope_id\":\"lab-sim\",\"path_id\":\"sim0\",\"profile_id\":\"", profile_id,
        "\",\"observation_id\":\"sim-obs\",\"task_revision\":1,\"route_epoch\":3,\"config_revision\":7,\"lease_ms\":10000,\"rationale\":\"recorded reply\"}");
    r.raw_output_json = "[{\"type\":\"function_call\",\"call_id\":\"call-apply\"}]";
    return r;
}

fn read_reply(call_id: const u8[:]) -> continuum::ModelResult {
    var r = continuum::ModelResult {};
    r.outcome = continuum::Outcome { status: continuum::Status.Completed, message: "scripted read" };
    r.has_tool_call = true;
    r.tool = continuum::ToolName.ReadObservation;
    r.call_id = call_id;
    r.response_id = "resp-read";
    r.provenance = continuum::Provenance.Synthetic;
    r.arguments_json = "{\"path_id\":\"sim0\",\"max_age_ms\":1000}";
    r.raw_output_json = "[{\"type\":\"function_call\"}]";
    return r;
}
