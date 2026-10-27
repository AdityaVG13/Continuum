// Item 4: the Meta adapter's pure shape. Building the request envelope,
// validating budgets, and classifying transport failures are deterministic
// and testable without any network; the HTTPS submit itself stays a native
// build ticket (native/ct_meta_*), so request_meta below keeps its TODO.
// Credentials never appear here: the native adapter reads META_API_KEY
// from the environment at submit time, and this module never asks for it.
// Every error class escalates; nothing authorizes action on failure.
import .contracts;
import .tooljson;
namespace continuum;

const MAX_TOOL_ROUNDS: i64 = 8;
const MAX_OUTPUT_TOKENS: i64 = 128000;
const MIN_TIMEOUT_MS: i64 = 1000;
const MAX_TIMEOUT_MS: i64 = 300000;

struct MetaEnvelope {
    ok: bool = false,
    reason: u8[..256] = "",
    run_id: u8[..64] = "",
    context_ref: u8[..64] = "",
    max_output_tokens: i64 = 0,
    max_tool_rounds: i64 = 0,
    request_timeout_ms: i64 = 0,
    parallel_tool_calls: bool = false,
    store: bool = true,
    stream: bool = true,
}

// The envelope the controller would submit: fixed safe flags (serial tool
// calls, no server-side store, no stream), budgets from config, ids bound
// to this run and context. False by default only as a struct literal; the
// builder always pins the safe values or fails.
fn build_meta_request(config: ModelConfig, run_id: const u8[:],
        context_ref: const u8[:]) -> MetaEnvelope {
    if !valid_id(run_id, 64) {
        return MetaEnvelope { ok: false, reason: "run id invalid" };
    }
    if !valid_id(context_ref, 64) {
        return MetaEnvelope { ok: false, reason: "context ref invalid" };
    }
    if config.base_url.len <= 0 || config.base_url.len > 256 {
        return MetaEnvelope { ok: false, reason: "base url outside 1..256" };
    }
    if !valid_id(config.controller_model, 128) {
        return MetaEnvelope { ok: false, reason: "controller model invalid" };
    }
    if !valid_id(config.task_model, 128) {
        return MetaEnvelope { ok: false, reason: "task model invalid" };
    }
    if config.api_key_env_name.len <= 0 {
        return MetaEnvelope { ok: false, reason: "no credential env named" };
    }
    if config.request_timeout_ms < MIN_TIMEOUT_MS
            || config.request_timeout_ms > MAX_TIMEOUT_MS {
        return MetaEnvelope { ok: false, reason: "timeout outside 1s..300s" };
    }
    if config.max_output_tokens <= 0 || config.max_output_tokens > MAX_OUTPUT_TOKENS {
        return MetaEnvelope { ok: false, reason: "output tokens outside 1..128000" };
    }
    if config.max_tool_rounds <= 0 || config.max_tool_rounds > MAX_TOOL_ROUNDS {
        return MetaEnvelope { ok: false, reason: "tool rounds outside 1..8" };
    }
    return MetaEnvelope {
        ok: true,
        run_id: run_id,
        context_ref: context_ref,
        max_output_tokens: config.max_output_tokens,
        max_tool_rounds: config.max_tool_rounds,
        request_timeout_ms: config.request_timeout_ms,
        parallel_tool_calls: false,
        store: false,
        stream: false,
    };
}

// Transport outcome to error class. 200 with a non-JSON body is Malformed;
// timeouts are their own class; auth failures are Fatal (retrying a bad
// credential burns budget and leaks nothing); rate limits and 5xx may be
// retried within the round budget. Unknown statuses fail closed to Fatal.
fn meta_error_class(status: i64, body_preview: const u8[:]) -> MetaErrorClass {
    if status == 200 {
        var i = 0;
        while i < body_preview.len {
            let b = body_preview[i];
            if b == ' ' || b == '\n' || b == '\r' || b == '\t' {
                i += 1;
                continue;
            }
            if b == '{' || b == '[' {
                return MetaErrorClass.Retryable;
            }
            return MetaErrorClass.Malformed;
        }
        return MetaErrorClass.Malformed;
    }
    if status == 0 {
        return MetaErrorClass.Timeout;
    }
    if status == 429 || status == 408 || status == 500 || status == 502
            || status == 503 || status == 504 {
        return MetaErrorClass.Retryable;
    }
    if status == 401 || status == 403 {
        return MetaErrorClass.Fatal;
    }
    return MetaErrorClass.Fatal;
}

// Item 5: the Meta Responses request/response meaning (no transport here).
// The native adapter moves bytes; this module decides what the bytes mean.
const MAX_META_BODY_BYTES: i64 = 32768;
const MAX_META_TEXT_BYTES: i64 = 8192;
const MAX_META_RAW_BYTES: i64 = 8192;

// Build the initial Responses body: fixed safe flags, role model, real
// prompt and validated context, caller-supplied tool array (validated as
// an array, then embedded raw). No credentials appear anywhere here.
fn meta_request_body(config: ModelConfig, role_model: const u8[:],
        instructions: const u8[:], input_text: const u8[:],
        tools_json: const u8[:], out: u8[>..]&) -> bool {
    if !valid_id(role_model, 128) {
        return false;
    }
    if instructions.len <= 0 || instructions.len > 8192 {
        return false;
    }
    if input_text.len <= 0 || input_text.len > 8192 {
        return false;
    }
    if config.max_output_tokens <= 0
            || config.max_output_tokens > MAX_OUTPUT_TOKENS {
        return false;
    }
    var r = json::reader(tools_json);
    if json::peek(r) != '[' {
        return false;
    }
    json::skip(r);
    if !json::finish(r) {
        return false;
    }
    out.append("{\"model\":");
    json::format_string(out, role_model);
    out.append(",\"instructions\":");
    json::format_string(out, instructions);
    out.append(",\"input\":[{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":");
    json::format_string(out, input_text);
    out.append("}]}]");
    out.append(",\"tool_choice\":\"auto\",\"parallel_tool_calls\":false,");
    out.append("\"store\":false,");
    out.append("\"include\":[\"reasoning.encrypted_content\"],\"stream\":false,");
    out.append("\"reasoning\":{\"effort\":\"low\"},\"max_output_tokens\":");
    json::format_int(out, config.max_output_tokens);
    out.append(",\"tools\":");
    out.append(tools_json);
    out.append("}");
    return out.len <= MAX_META_BODY_BYTES;
}

// Raw span of a member value for byte-exact replay. Only string escapes
// are understood; the shapes accepted here are machine-generated (the
// transport envelope, the provider body), never free model prose. Matches
// only top-level members so a nested same-named key cannot shadow the real
// one. Oversize spans fail closed.
fn find_raw_value(text: const u8[:], key: const u8[:]) -> const u8[:], bool {
    var depth = 0;
    var i = 0;
    var in_str = false;
    var esc = false;
    while i < text.len {
        let b = text[i];
        if in_str {
            if esc {
                esc = false;
            } else if b == 92 {
                esc = true;
            } else if b == 34 {
                in_str = false;
            }
            i += 1;
            continue;
        }
        if b == 34 {
            if depth == 1 {
                var j = i + 1;
                var k = 0;
                while k < key.len && j < text.len && text[j] == key[k] {
                    j += 1;
                    k += 1;
                }
                if k == key.len && j < text.len && text[j] == 34 {
                    j += 1;
                    while j < text.len && (text[j] == 32 || text[j] == 9
                            || text[j] == 10 || text[j] == 13) {
                        j += 1;
                    }
                    if j < text.len && text[j] == 58 {
                        j += 1;
                        while j < text.len && (text[j] == 32 || text[j] == 9
                                || text[j] == 10 || text[j] == 13) {
                            j += 1;
                        }
                        if j >= text.len {
                            return "", false;
                        }
                        let v = text[j];
                        if v == 123 || v == 91 {
                            let close = if v == 123 { 125 } else { 93 };
                            var nest = 0;
                            var p = j;
                            var s2 = false;
                            var e2 = false;
                            while p < text.len {
                                let c = text[p];
                                if s2 {
                                    if e2 {
                                        e2 = false;
                                    } else if c == 92 {
                                        e2 = true;
                                    } else if c == 34 {
                                        s2 = false;
                                    }
                                } else {
                                    if c == 34 {
                                        s2 = true;
                                    } else if c == v {
                                        nest += 1;
                                    } else if c == close {
                                        nest -= 1;
                                        if nest == 0 {
                                            if p + 1 - j > MAX_META_RAW_BYTES {
                                                return "", false;
                                            }
                                            return text[j..p + 1], true;
                                        }
                                    }
                                }
                                p += 1;
                            }
                            return "", false;
                        }
                        if v == 34 {
                            var p = j + 1;
                            var e2 = false;
                            while p < text.len {
                                let c = text[p];
                                if e2 {
                                    e2 = false;
                                } else if c == 92 {
                                    e2 = true;
                                } else if c == 34 {
                                    return text[j..p + 1], true;
                                }
                                p += 1;
                            }
                            return "", false;
                        }
                        var p = j;
                        while p < text.len && text[p] != 44
                                && text[p] != 125 && text[p] != 93 {
                            p += 1;
                        }
                        if p == j || p - j > 64 {
                            return "", false;
                        }
                        return text[j..p], true;
                    }
                }
            }
            in_str = true;
            i += 1;
            continue;
        }
        if b == 123 || b == 91 {
            depth += 1;
        } else if b == 125 || b == 93 {
            depth -= 1;
        }
        i += 1;
    }
    return "", false;
}

// Parse one complete Responses body: ids, at most one serial tool call
// against the six allowlisted names, collected text, and the byte-exact
// output array for stateless replay. Decoded strings are copied into the
// caller's buffers; id slices borrow the caller's body. Anything else -
// malformed JSON, unknown tool, oversize fields - fails closed.
fn meta_parse_response(body: const u8[:], request_id: const u8[:],
        result: ModelResult&, arguments_json: u8[>..]&,
        text_out: u8[>..]&) -> bool {
    result = ModelResult {};
    if body.len <= 0 || body.len > MAX_META_BODY_BYTES {
        return false;
    }
    if !valid_id(request_id, 64) {
        return false;
    }
    var doc: json::Node[>..] = [];
    var decoded: u8[>..] = [];
    let root, err = json::parse(body, doc, decoded);
    if !root {
        return false;
    }
    let rid, has_rid = json::as_string(json::member(root, "id"));
    if !has_rid || !valid_id(rid, 128) {
        return false;
    }
    let model, has_model = json::as_string(json::member(root, "model"));
    if !has_model || !valid_id(model, 128) {
        return false;
    }
    let output = json::member(root, "output");
    if !output {
        return false;
    }
    var found_call = false;
    var tool = ToolName.ReadObservation;
    var c = output.first;
    while c {
        let t, has_t = json::as_string(json::member(c, "type"));
        if has_t && t == "function_call" {
            if found_call {
                return false;
            }
            let name, has_name = json::as_string(json::member(c, "name"));
            if !has_name {
                return false;
            }
            let tn, known = tool_named(name);
            if !known {
                return false;
            }
            let cid1, has_cid1 = json::as_string(json::member(c, "call_id"));
            if has_cid1 {
                if !valid_id(cid1, 128) {
                    return false;
                }
                result.call_id = cid1;
            } else {
                let cid2, has_cid2 = json::as_string(json::member(c, "id"));
                if !has_cid2 || !valid_id(cid2, 128) {
                    return false;
                }
                result.call_id = cid2;
            }
            let args, has_args = json::as_string(json::member(c, "arguments"));
            if !has_args || args.len <= 0 || args.len > 8192 {
                return false;
            }
            var adoc: json::Node[>..] = [];
            var adec: u8[>..] = [];
            let aroot, aerr = json::parse(args, adoc, adec);
            if !aroot {
                return false;
            }
            var ar = json::reader(args);
            if json::peek(ar) != '{' {
                return false;
            }
            json::skip(ar);
            if !json::finish(ar) {
                return false;
            }
            arguments_json.append(args);
            tool = tn;
            found_call = true;
        }
        if has_t && t == "message" {
            let content = json::member(c, "content");
            if content {
                var cc = content.first;
                while cc {
                    let ct2, has_ct2 = json::as_string(json::member(cc, "type"));
                    if has_ct2 && ct2 == "output_text" {
                        let tx, has_tx = json::as_string(json::member(cc, "text"));
                        if has_tx {
                            if text_out.len + tx.len > MAX_META_TEXT_BYTES {
                                return false;
                            }
                            text_out.append(tx);
                        }
                    }
                    cc .= cc.next;
                }
            }
        }
        c .= c.next;
    }
    let raw, has_raw = find_raw_value(body, "output");
    if !has_raw || raw.len <= 0 || raw.len > MAX_META_RAW_BYTES {
        return false;
    }
    result.response_id = rid;
    result.request_id = request_id;
    result.provider_model_id = model;
    result.has_tool_call = found_call;
    result.tool = tool;
    result.raw_output_json = raw;
    return true;
}

// Continuation under stateless replay: resend the model, instructions and
// tools, then the prior input items, the prior output items byte-for-byte,
// and the new function_call_output. No previous_response_id: with
// store:false the server keeps nothing, so the history travels in input.
fn meta_continuation_body(config: ModelConfig, role_model: const u8[:],
        instructions: const u8[:], prior_input_json: const u8[:],
        prior_output_json: const u8[:], call_id: const u8[:],
        result_json: const u8[:], tools_json: const u8[:],
        out: u8[>..]&) -> bool {
    if !valid_id(role_model, 128) {
        return false;
    }
    if instructions.len <= 0 || instructions.len > 8192 {
        return false;
    }
    if !valid_id(call_id, 128) {
        return false;
    }
    if result_json.len <= 0 || result_json.len > 8192 {
        return false;
    }
    if config.max_output_tokens <= 0
            || config.max_output_tokens > MAX_OUTPUT_TOKENS {
        return false;
    }
    var r1 = json::reader(prior_input_json);
    if json::peek(r1) != '[' {
        return false;
    }
    json::skip(r1);
    if !json::finish(r1) {
        return false;
    }
    var r2 = json::reader(prior_output_json);
    if json::peek(r2) != '[' {
        return false;
    }
    json::skip(r2);
    if !json::finish(r2) {
        return false;
    }
    var r3 = json::reader(result_json);
    if json::peek(r3) != '{' {
        return false;
    }
    json::skip(r3);
    if !json::finish(r3) {
        return false;
    }
    var r4 = json::reader(tools_json);
    if json::peek(r4) != '[' {
        return false;
    }
    json::skip(r4);
    if !json::finish(r4) {
        return false;
    }
    if prior_input_json.len < 2 || prior_output_json.len < 2 {
        return false;
    }
    let inner_in = prior_input_json[1..prior_input_json.len - 1];
    let inner_out = prior_output_json[1..prior_output_json.len - 1];
    if inner_in.len <= 0 || inner_out.len <= 0 {
        return false;
    }
    out.append("{\"model\":");
    json::format_string(out, role_model);
    out.append(",\"instructions\":");
    json::format_string(out, instructions);
    out.append(",\"input\":[");
    out.append(inner_in);
    out.append(",");
    out.append(inner_out);
    out.append(",{\"type\":\"function_call_output\",\"call_id\":");
    json::format_string(out, call_id);
    out.append(",\"output\":");
    json::format_string(out, result_json);
    out.append("}]");
    out.append(",\"tool_choice\":\"auto\",\"parallel_tool_calls\":false,");
    out.append("\"store\":false,");
    out.append("\"include\":[\"reasoning.encrypted_content\"],\"stream\":false,");
    out.append("\"reasoning\":{\"effort\":\"low\"},\"max_output_tokens\":");
    json::format_int(out, config.max_output_tokens);
    out.append(",\"tools\":");
    out.append(tools_json);
    out.append("}");
    return out.len <= MAX_META_BODY_BYTES;
}
