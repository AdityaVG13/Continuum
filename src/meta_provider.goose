import .contracts;
import .tooljson;
import .meta_shape;
import json;
import os;
namespace continuum;

// Native Meta HTTPS transport (item M01/C03). Goose owns request identity,
// budgets, response meaning and admission; the C++ adapter (native/meta_web.cpp)
// owns TLS bytes via a curl child process. The secret never crosses this
// boundary: the adapter reads api_key_env_name from the process environment
// at submit time, and no key, token or password is ever logged.
extern fn ct_meta_open(config: const u8[:], handle: u64&) -> i32;
extern fn ct_meta_submit(handle: u64, request: const u8[:], request_id: u64&) -> i32;
extern fn ct_meta_poll(handle: u64, result: u8[:], result_len: i64&) -> i32;
extern fn ct_meta_cancel(handle: u64, request_id: u64) -> i32;
extern fn ct_meta_close(handle: u64) -> i32;

// Transport ceiling: the largest provider body the adapter will copy.
// Larger responses fail closed, never truncate.
const META_TRANSPORT_BYTES: i64 = 32768;
const META_ENVELOPE_BYTES: i64 = 33792;

fn meta_failed(reason: const u8[:]) -> ModelResult {
    return ModelResult {
        outcome: Outcome { status: Status.Failed, message: reason },
    };
}

// Adapter config: credential source name (never the secret), https base,
// timeout and byte bound. Validated again inside the adapter.
fn meta_transport_config(config: ModelConfig, out: u8[>..]&) -> bool {
    if !valid_id(config.api_key_env_name, 64) {
        return false;
    }
    if config.base_url.len <= 0 || config.base_url.len > 256 {
        return false;
    }
    if config.request_timeout_ms < MIN_TIMEOUT_MS
            || config.request_timeout_ms > MAX_TIMEOUT_MS {
        return false;
    }
    out.append("{\"api_key_env\":");
    json::format_string(out, config.api_key_env_name);
    out.append(",\"base_url\":");
    json::format_string(out, config.base_url);
    out.append(",\"timeout_ms\":");
    json::format_int(out, config.request_timeout_ms);
    out.append(",\"max_bytes\":");
    json::format_int(out, META_TRANSPORT_BYTES);
    out.append("}");
    return true;
}

// One HTTPS round trip through the adapter, then meaning on the Goose side.
// Returns Live provenance only for a 200 response that parses cleanly;
// every other outcome is Failed with a literal reason. Nothing here acts
// on the network: the caller decides what a parsed tool call authorizes.
fn meta_exchange(config: ModelConfig, request_id: const u8[:],
        body_text: const u8[:]) -> ModelResult {
    var cfg_text: u8[>..] = [];
    if !meta_transport_config(config, cfg_text) {
        return meta_failed("meta transport config invalid");
    }
    if body_text.len <= 0 || body_text.len > MAX_META_BODY_BYTES {
        return meta_failed("meta request body outside bound");
    }
    var req_text: u8[>..] = [];
    req_text.append("{\"path\":\"/responses\",\"body\":");
    req_text.append(body_text);
    req_text.append("}");
    var handle: u64 = 0;
    if ct_meta_open(cfg_text, handle) != 0 || handle == 0 {
        return meta_failed("meta transport unavailable");
    }
    var req_no: u64 = 0;
    if ct_meta_submit(handle, req_text, req_no) != 0 || req_no == 0 {
        ct_meta_close(handle);
        return meta_failed("meta submit failed");
    }
    var env: u8[..33792] = [0; 33792];
    var n: i64 = 0;
    if ct_meta_poll(handle, env, n) != 0 {
        ct_meta_cancel(handle, req_no);
        ct_meta_close(handle);
        return meta_failed("meta response over bound");
    }
    ct_meta_close(handle);
    if n <= 0 || n > env.len {
        return meta_failed("meta transport returned no envelope");
    }
    let envelope = env[..n];
    var doc: json::Node[>..] = [];
    var decoded: u8[>..] = [];
    let root, err = json::parse(envelope, doc, decoded);
    if !root {
        return meta_failed("meta envelope is not JSON");
    }
    let status, has_status = json::as_i64(json::member(root, "status"));
    if !has_status {
        return meta_failed("meta envelope lacks status");
    }
    if status == 200 {
        let raw, has_raw = find_raw_value(envelope, "body");
        if !has_raw {
            return meta_failed("meta envelope lacks body");
        }
        var args: u8[>..] = [];
        var text: u8[>..] = [];
        var mr = ModelResult {};
        if !meta_parse_response(raw, request_id, mr, args, text) {
            return meta_failed("meta response rejected");
        }
        mr.arguments_json = args;
        mr.text = text;
        mr.outcome = Outcome {
            status: Status.Completed,
            message: "meta round trip complete",
        };
        mr.provenance = Provenance.Live;
        return mr;
    }
    if status == 0 {
        return meta_failed("meta transport timeout");
    }
    if meta_error_class(status, "") == MetaErrorClass.Retryable {
        return meta_failed("meta request retryable");
    }
    return meta_failed("meta request fatal");
}

fn meta_role_model(config: ModelConfig, role_id: const u8[:]) -> u8[>..] {
    var m: u8[>..] = [];
    if role_id == "task" {
        m.append(config.task_model);
    } else {
        m.append(config.controller_model);
    }
    return m;
}

fn meta_role_prompt(role_id: const u8[:]) -> const u8[:] {
    if role_id == "task" {
        return "prompts/workload.md";
    }
    return "prompts/controller.md";
}

// First call of an incident or task turn: envelope, real prompt, validated
// context, tool array, one bounded HTTPS round trip, typed parse.
fn request_meta(config: ModelConfig, request: ModelRequest) -> ModelResult {
    let env = build_meta_request(config, request.run_id, request.request_id);
    if !env.ok {
        return meta_failed(env.reason);
    }
    let model = meta_role_model(config, request.role_id);
    var instructions: u8[>..] = [];
    if !read_file(meta_role_prompt(request.role_id), instructions) {
        return meta_failed("meta prompt file unavailable");
    }
    var tools: u8[>..] = [];
    if !read_file("schemas/meta-tools.json", tools) {
        return meta_failed("meta tools file unavailable");
    }
    var body: u8[>..] = [];
    if !meta_request_body(config, model, instructions, request.context,
            tools, body) {
        return meta_failed("meta request body invalid");
    }
    return meta_exchange(config, request.request_id, body);
}

// Later call of the same turn: replay prior input plus byte-exact prior
// output plus the new function_call_output, then parse the next step.
// request_id is the originating request so the follow-up stays correlated.
fn submit_tool_result(config: ModelConfig, request_id: const u8[:],
        response_id: const u8[:], call_id: const u8[:],
        prior_input_json: const u8[:], prior_output_json: const u8[:],
        result_json: const u8[:]) -> ModelResult {
    if !valid_id(request_id, 64) {
        return meta_failed("continuation request id invalid");
    }
    if !valid_id(response_id, 128) {
        return meta_failed("continuation response id invalid");
    }
    var instructions: u8[>..] = [];
    if !read_file("prompts/controller.md", instructions) {
        return meta_failed("meta prompt file unavailable");
    }
    var tools: u8[>..] = [];
    if !read_file("schemas/meta-tools.json", tools) {
        return meta_failed("meta tools file unavailable");
    }
    var body: u8[>..] = [];
    if !meta_continuation_body(config, config.controller_model, instructions,
            prior_input_json, prior_output_json, call_id, result_json,
            tools, body) {
        return meta_failed("meta continuation body invalid");
    }
    return meta_exchange(config, request_id, body);
}
