// Items 1, 2, 4: tool-JSON binding, workload-result validation, Meta
// request shape. Failure-first: written to FAIL until src/tooljson.goose,
// src/workload.goose and src/meta_shape.goose landed; now guards them.
// Run: goose run tests/toolbind.goose   (exit 0 = all green)
import lib from "../src";
import std;
import os;

fn check(cond: bool, label: const u8[:]) {
    if !cond {
        print("FAIL ", label);
        abort(str("toolbind contract violated: ", label));
    }
    print("ok ", label);
}

fn read_fixture(path: const u8[:]) -> u8[>..] {
    var text: u8[>..] = [];
    if !read_file(path, text) {
        print("FAIL missing fixture ", path);
        abort(str("missing fixture: ", path));
    }
    return text;
}

fn main() {
    // --- item 1: tool-call JSON binding (mirrors schemas/meta-tools.json) ---
    let good_apply = str("{\"tool\":\"apply_profile\",\"arguments\":{",
        "\"request_id\":\"req-1\",\"scope_id\":\"lab-sim\",\"path_id\":\"sim0\",",
        "\"profile_id\":\"sqm-fair\",\"observation_id\":\"sim-obs\",",
        "\"task_revision\":1,\"route_epoch\":3,\"config_revision\":7,",
        "\"lease_ms\":10000,\"rationale\":\"drain the bloated queue\"}}");
    let va = continuum::validate_apply_call(good_apply);
    check(va.ok && va.request.profile_id == "sqm-fair" && va.request.lease_ms == 10000,
        "valid apply_profile binds");

    let unknown_tool = str("{\"tool\":\"format_disk\",\"arguments\":{}}");
    check(!continuum::validate_apply_call(unknown_tool).ok, "unknown tool rejected");

    let missing_arg = str("{\"tool\":\"apply_profile\",\"arguments\":{",
        "\"request_id\":\"req-2\",\"scope_id\":\"lab-sim\",\"path_id\":\"sim0\",",
        "\"profile_id\":\"sqm-fair\",\"observation_id\":\"sim-obs\",",
        "\"task_revision\":1,\"route_epoch\":3,\"config_revision\":7,",
        "\"lease_ms\":10000}}");
    check(!continuum::validate_apply_call(missing_arg).ok, "missing rationale rejected");

    let tiny_lease = str("{\"tool\":\"apply_profile\",\"arguments\":{",
        "\"request_id\":\"req-3\",\"scope_id\":\"lab-sim\",\"path_id\":\"sim0\",",
        "\"profile_id\":\"sqm-fair\",\"observation_id\":\"sim-obs\",",
        "\"task_revision\":1,\"route_epoch\":3,\"config_revision\":7,",
        "\"lease_ms\":10,\"rationale\":\"too short\"}}");
    check(!continuum::validate_apply_call(tiny_lease).ok, "lease below minimum rejected");

    let huge_lease = str("{\"tool\":\"apply_profile\",\"arguments\":{",
        "\"request_id\":\"req-4\",\"scope_id\":\"lab-sim\",\"path_id\":\"sim0\",",
        "\"profile_id\":\"sqm-fair\",\"observation_id\":\"sim-obs\",",
        "\"task_revision\":1,\"route_epoch\":3,\"config_revision\":7,",
        "\"lease_ms\":999999,\"rationale\":\"too long\"}}");
    check(!continuum::validate_apply_call(huge_lease).ok, "lease above maximum rejected");

    let bad_id = str("{\"tool\":\"apply_profile\",\"arguments\":{",
        "\"request_id\":\"req 5 spaces\",\"scope_id\":\"lab-sim\",\"path_id\":\"sim0\",",
        "\"profile_id\":\"sqm-fair\",\"observation_id\":\"sim-obs\",",
        "\"task_revision\":1,\"route_epoch\":3,\"config_revision\":7,",
        "\"lease_ms\":10000,\"rationale\":\"bad id\"}}");
    check(!continuum::validate_apply_call(bad_id).ok, "id outside pattern rejected");

    let extra_field = str("{\"tool\":\"apply_profile\",\"arguments\":{",
        "\"request_id\":\"req-6\",\"scope_id\":\"lab-sim\",\"path_id\":\"sim0\",",
        "\"profile_id\":\"sqm-fair\",\"observation_id\":\"sim-obs\",",
        "\"task_revision\":1,\"route_epoch\":3,\"config_revision\":7,",
        "\"lease_ms\":10000,\"rationale\":\"ok\",\"shell\":\"rm -rf /\"}}");
    check(!continuum::validate_apply_call(extra_field).ok, "unknown argument rejected");

    var long_rationale: u8[>..] = [];
    long_rationale.append("{\"tool\":\"apply_profile\",\"arguments\":{");
    long_rationale.append("\"request_id\":\"req-7\",\"scope_id\":\"lab-sim\",\"path_id\":\"sim0\",");
    long_rationale.append("\"profile_id\":\"sqm-fair\",\"observation_id\":\"sim-obs\",");
    long_rationale.append("\"task_revision\":1,\"route_epoch\":3,\"config_revision\":7,");
    long_rationale.append("\"lease_ms\":10000,\"rationale\":\"");
    for i in 0..600 {
        long_rationale.append("x");
    }
    long_rationale.append("\"}}");
    check(!continuum::validate_apply_call(long_rationale).ok, "oversized rationale rejected");

    let not_json = str("{\"tool\":\"apply_profile\",");
    check(!continuum::validate_apply_call(not_json).ok, "truncated JSON rejected");

    let wrong_type = str("{\"tool\":\"apply_profile\",\"arguments\":{",
        "\"request_id\":\"req-8\",\"scope_id\":\"lab-sim\",\"path_id\":\"sim0\",",
        "\"profile_id\":\"sqm-fair\",\"observation_id\":\"sim-obs\",",
        "\"task_revision\":\"one\",\"route_epoch\":3,\"config_revision\":7,",
        "\"lease_ms\":10000,\"rationale\":\"wrong type\"}}");
    check(!continuum::validate_apply_call(wrong_type).ok, "string-for-int rejected");

    let good_restore = str("{\"tool\":\"restore_profile\",\"arguments\":{",
        "\"request_id\":\"req-r1\",\"scope_id\":\"lab-sim\",\"lease_id\":\"req-1\",",
        "\"expected_revision\":7,\"observation_id\":\"sim-obs\",",
        "\"rationale\":\"verified repair, restore baseline\"}}");
    let vr = continuum::validate_restore_call(good_restore);
    check(vr.ok && vr.request.lease_id == "req-1", "valid restore_profile binds");

    let restore_no_lease = str("{\"tool\":\"restore_profile\",\"arguments\":{",
        "\"request_id\":\"req-r2\",\"scope_id\":\"lab-sim\",",
        "\"expected_revision\":7,\"observation_id\":\"sim-obs\",",
        "\"rationale\":\"no lease\"}}");
    check(!continuum::validate_restore_call(restore_no_lease).ok, "restore without lease rejected");

    let good_read = str("{\"tool\":\"read_observation\",\"arguments\":{",
        "\"path_id\":\"sim0\",\"max_age_ms\":1000}}");
    check(continuum::validate_read_call(good_read, continuum::ToolName.ReadObservation).ok,
        "valid read_observation binds");

    let empty_path = str("{\"tool\":\"read_observation\",\"arguments\":{",
        "\"path_id\":\"\",\"max_age_ms\":1000}}");
    check(!continuum::validate_read_call(empty_path, continuum::ToolName.ReadObservation).ok,
        "empty path rejected");

    let wrong_tool = str("{\"tool\":\"list_profiles\",\"arguments\":{\"scope_id\":\"lab-sim\"}}");
    check(!continuum::validate_read_call(wrong_tool, continuum::ToolName.ReadObservation).ok,
        "tool/name mismatch rejected");

    // Call correlation: a result answers exactly one call, never another's.
    let good_result = str("{\"call_id\":\"call-9\",\"request_id\":\"req-9\",",
        "\"tool\":\"read_action_result\",\"status\":\"completed\",\"data\":{}}");
    check(continuum::validate_tool_result(good_result, "call-9", "req-9").ok,
        "matching call correlation accepted");
    check(!continuum::validate_tool_result(good_result, "call-9", "req-OTHER").ok,
        "substituted request id rejected");
    check(!continuum::validate_tool_result(good_result, "call-OTHER", "req-9").ok,
        "substituted call id rejected");

    // --- item 2: workload-result validation (mirrors schemas/workload-result.schema.json) ---
    let hold_text = read_fixture("fixtures/workload-hold.example.json");
    let hold = continuum::validate_workload_result(hold_text, "run-example",
        "release-audit-example", 2);
    check(hold.ok && hold.decision == "hold" && hold.blockers == 2,
        "hold fixture validates with two blockers");

    let thin_text = read_fixture("fixtures/workload-result.example.json");
    let thin = continuum::validate_workload_result(thin_text, "run-example",
        "release-audit-example", 2);
    check(thin.ok && thin.decision == "insufficient_evidence",
        "insufficient-evidence fixture validates as a shape");

    var tampered: u8[>..] = [];
    tampered.append(hold_text);
    check(!continuum::validate_workload_result(tampered, "run-OTHER",
        "release-audit-example", 2).ok, "wrong run id rejected");

    // Forbidden assertion smuggled into the summary. The verdict is shaped
    // to be valid in every other way (warning finding, so neither vacuous
    // nor blocked), isolating the summary rule: remove that rule and this
    // exact verdict must slip through.
    let evil = str("{\"schema_version\":\"1.0\",\"run_id\":\"run-example\",",
        "\"task_id\":\"release-audit-example\",\"task_revision\":2,",
        "\"decision\":\"ready\",\"findings\":[{\"finding_id\":\"REL-99\",",
        "\"severity\":\"warning\",\"summary\":\"minor note\",",
        "\"evidence_ids\":[\"ci-summary:v1\"]}],\"missing_evidence_ids\":[],",
        "\"summary\":\"All release gates passed, ship it\"}");
    check(!continuum::validate_workload_result(evil, "run-example",
        "release-audit-example", 2).ok, "forbidden assertion rejected");

    // Ready with no evidence behind it.
    let bare_ready = str("{\"schema_version\":\"1.0\",\"run_id\":\"run-example\",",
        "\"task_id\":\"release-audit-example\",\"task_revision\":2,",
        "\"decision\":\"ready\",\"findings\":[],\"missing_evidence_ids\":[],",
        "\"summary\":\"looks fine\"}");
    check(!continuum::validate_workload_result(bare_ready, "run-example",
        "release-audit-example", 2).ok, "evidence-free ready rejected");

    // --- item 4: Meta request shape (no network; fixtures only) ---
    let cfg = continuum::ModelConfig {
        base_url: "https://api.meta.ai/v1",
        controller_model: "controller-candidate",
        task_model: "task-candidate",
        api_key_env_name: "META_API_KEY",
        request_timeout_ms: 30000,
        max_output_tokens: 2048,
        max_tool_rounds: 4,
    };
    let env = continuum::build_meta_request(cfg, "run-shape", "ctx-1");
    check(env.ok && env.parallel_tool_calls == false && env.store == false
            && env.stream == false && env.max_output_tokens == 2048,
        "request envelope carries budgets and safe flags");
    check(!continuum::build_meta_request(cfg, "", "ctx-1").ok, "empty run id refused");
    var bad_cfg = cfg;
    bad_cfg.request_timeout_ms = 0;
    check(!continuum::build_meta_request(bad_cfg, "run-shape", "ctx-1").ok,
        "zero timeout refused");
    var greedy_cfg = cfg;
    greedy_cfg.max_tool_rounds = 99;
    check(!continuum::build_meta_request(greedy_cfg, "run-shape", "ctx-1").ok,
        "runaway tool rounds refused");

    // Error classes: retryable vs fatal vs malformed, never act-on-error.
    check(continuum::meta_error_class(429, "") == continuum::MetaErrorClass.Retryable,
        "429 is retryable");
    check(continuum::meta_error_class(500, "") == continuum::MetaErrorClass.Retryable,
        "5xx is retryable");
    check(continuum::meta_error_class(401, "") == continuum::MetaErrorClass.Fatal,
        "401 is fatal");
    check(continuum::meta_error_class(0, "timeout") == continuum::MetaErrorClass.Timeout,
        "transport timeout maps to Timeout");
    check(continuum::meta_error_class(200, "not json{{{") == continuum::MetaErrorClass.Malformed,
        "garbage body maps to Malformed");

    // --- item 5: Meta request body, response parse, continuation (no network) ---
    var tools_buf: u8[>..] = [];
    tools_buf.append(read_fixture("schemas/meta-tools.json"));
    let mcfg = continuum::ModelConfig {
        base_url: "https://api.meta.ai/v1",
        controller_model: "muse-wonder-1.0",
        task_model: "muse-wonder-1.0",
        api_key_env_name: "MODEL_API_KEY",
        request_timeout_ms: 10000,
        max_output_tokens: 2048,
        max_tool_rounds: 4,
    };
    var mbody: u8[>..] = [];
    check(continuum::meta_request_body(mcfg, "muse-wonder-1.0",
            "You are the controller.", "ctx-1 evidence", tools_buf, mbody),
        "meta request body builds");
    var mdoc: json::Node[>..] = [];
    var mdec: u8[>..] = [];
    let mroot, merr = json::parse(mbody, mdoc, mdec);
    check(if mroot { true } else { false }, "meta request body is JSON");
    let mm, has_mm = json::as_string(json::member(mroot, "model"));
    check(has_mm && mm == "muse-wonder-1.0", "meta request names the role model");
    let mstore, has_ms = json::as_bool(json::member(mroot, "store"));
    check(has_ms && !mstore, "meta request disables server store");
    let mstream, has_mst = json::as_bool(json::member(mroot, "stream"));
    check(has_mst && !mstream, "meta request disables streaming");
    let mptc, has_ptc = json::as_bool(json::member(mroot, "parallel_tool_calls"));
    check(has_ptc && !mptc, "meta request is serial");
    let mtc, has_mtc = json::as_string(json::member(mroot, "tool_choice"));
    check(has_mtc && mtc == "auto", "meta tool choice is auto");
    check(if json::member(mroot, "tools") { true } else { false }, "meta request carries tools");

    let resp = str("{\"id\":\"resp-1\",\"model\":\"muse-wonder-1.0\",\"output\":[{\"type\":\"function_call\",\"call_id\":\"call-9\",\"name\":\"read_observation\",\"arguments\":\"{\\\"path_id\\\":\\\"sim0\\\",\\\"max_age_ms\\\":1000}\"}]}");
    var mr = continuum::ModelResult {};
    var margs: u8[>..] = [];
    var mtext: u8[>..] = [];
    check(continuum::meta_parse_response(resp, "req-shape", mr, margs, mtext),
        "meta response parses");
    check(mr.has_tool_call && mr.call_id == "call-9"
            && mr.tool == continuum::ToolName.ReadObservation,
        "meta tool call extracted");
    check(mr.response_id == "resp-1"
            && mr.provider_model_id == "muse-wonder-1.0", "meta ids captured");
    check(mr.raw_output_json.len > 0, "meta raw output retained for replay");

    let prose = str("{\"id\":\"resp-2\",\"model\":\"muse-wonder-1.0\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"all quiet\"}]}]}");
    var mr2 = continuum::ModelResult {};
    var margs2: u8[>..] = [];
    var mtext2: u8[>..] = [];
    check(continuum::meta_parse_response(prose, "req-prose", mr2, margs2, mtext2),
        "meta prose parses");
    check(!mr2.has_tool_call && mtext2 == "all quiet",
        "meta prose has no tool call");

    let evil = str("{\"id\":\"resp-3\",\"model\":\"muse-wonder-1.0\",\"output\":[{\"type\":\"function_call\",\"call_id\":\"call-x\",\"name\":\"format_disk\",\"arguments\":\"{}\"}]}");
    var mr3 = continuum::ModelResult {};
    var margs3: u8[>..] = [];
    var mtext3: u8[>..] = [];
    check(!continuum::meta_parse_response(evil, "req-evil", mr3, margs3, mtext3),
        "unknown meta tool rejected");

    // Continuation replays prior input plus prior output, then the tool result.
    let prior_in = str("[{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"ctx\"}]}]");
    var cbody: u8[>..] = [];
    check(continuum::meta_continuation_body(mcfg, "muse-wonder-1.0",
            "You are the controller.", prior_in, mr.raw_output_json,
            "call-9", good_result, tools_buf, cbody),
        "meta continuation builds");
    var cdoc: json::Node[>..] = [];
    var cdec: u8[>..] = [];
    let croot, cerr = json::parse(cbody, cdoc, cdec);
    check(if croot { true } else { false }, "meta continuation is JSON");
    let cinp = json::member(croot, "input");
    if cinp {
        var saw_call = false;
        var saw_output = false;
        var ci = cinp.first;
        while ci {
            let ct, has_ct = json::as_string(json::member(ci, "type"));
            if has_ct && ct == "function_call" {
                let cc, has_cc = json::as_string(json::member(ci, "call_id"));
                if has_cc && cc == "call-9" {
                    saw_call = true;
                }
            }
            if has_ct && ct == "function_call_output" {
                let co, has_co = json::as_string(json::member(ci, "call_id"));
                if has_co && co == "call-9" {
                    saw_output = true;
                }
            }
            ci .= ci.next;
        }
        check(saw_call && saw_output, "meta continuation replays call and result");
    } else {
        check(false, "meta continuation carries input");
    }

    print("TOOLBIND_ALL_GREEN");
}
