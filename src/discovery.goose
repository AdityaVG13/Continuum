// A separate read-only Meta role. Its tool responses are real host receipts;
// it cannot dispatch the optimizer's mutation tools or use guessed endpoints.
import .contracts;
import .meta_provider;
import .meta_shape;
import .tooljson;
import .controller;
import json;
import os;
namespace continuum;

extern fn ct_setup_discover(out: u8[:], length: i64&) -> i32;
extern fn ct_setup_probe(candidate: const u8[:], port: i64, out: u8[:], length: i64&) -> i32;

fn discover_host() -> u8[>..] {
    var buffer: u8[..16384] = [0; 16384];
    var n: i64 = 0;
    if ct_setup_discover(buffer, n) != 0 || n <= 0 || n > buffer.len {
        return str("{\"status\":\"failed\",\"reason\":\"host discovery unavailable or over bound\"}");
    }
    var out: u8[>..] = [];
    out.append(buffer[..n]);
    return out;
}

fn discovery_rejected(reason: const u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    out.append("{\"status\":\"rejected\",\"reason\":");
    json::format_string(out, reason);
    out.append(",\"network_changed\":false}");
    return out;
}

fn dispatch_discovery(tool: ToolName, arguments: const u8[:]) -> u8[>..] {
    var doc: json::Node[>..] = [];
    var decoded: u8[>..] = [];
    let root, err = json::parse(arguments, doc, decoded);
    if !root || arguments.len > 4096 { return discovery_rejected("arguments invalid"); }
    if tool == ToolName.DiscoverTopology {
        let known: const u8[:][..0] = [];
        if !no_unknown(root, known) { return discovery_rejected("discovery takes no arguments"); }
        return discover_host();
    }
    if tool != ToolName.InspectSystem { return discovery_rejected("tool outside read-only discovery scope"); }
    let known: const u8[:][..2] = ["candidate_id", "port"];
    if !no_unknown(root, known) { return discovery_rejected("unknown inspection argument"); }
    let id, has_id = json::as_string(json::member(root, "candidate_id"));
    let port, has_port = json::as_i64(json::member(root, "port"));
    if !has_id || !valid_id(id, 64) || !has_port ||
            !(port == 80 || port == 443 || port == 8080 || port == 8443) {
        return discovery_rejected("observed candidate and fixed management port required");
    }
    var buffer: u8[..4096] = [0; 4096];
    var n: i64 = 0;
    if ct_setup_probe(id, port, buffer, n) != 0 || n <= 0 || n > buffer.len {
        return discovery_rejected("candidate absent from current on-link evidence or probe unavailable");
    }
    var out: u8[>..] = [];
    out.append(buffer[..n]);
    return out;
}

struct DiscoveryReport {
    ok: bool = false,
    model_calls: i64 = 0,
    summary: u8[..8192] = "",
    reason: u8[..256] = "",
    tools_json: u8[..16384] = "[]",
}

fn discovery_record(report: DiscoveryReport) -> u8[>..] {
    var out: u8[>..] = [];
    out.append("{\"status\":");
    json::format_string(out, if report.ok { "completed" } else { "failed" });
    out.append(",\"network_changed\":false,\"model_calls\":");
    json::format_int(out, report.model_calls);
    out.append(",\"summary\":"); json::format_string(out, report.summary);
    out.append(",\"reason\":"); json::format_string(out, report.reason);
    out.append(",\"tools\":"); out.append(report.tools_json); out.append("}");
    return out;
}

fn run_discovery(config: ModelConfig) -> DiscoveryReport {
    var report = DiscoveryReport {};
    if !build_meta_request(config, "discovery", "discovery").ok || !meta_credentials_available(config) {
        report.reason = "MODEL_API_KEY or model settings unavailable; no provider call";
        return report;
    }
    var instructions: u8[>..] = [];
    var tools: u8[>..] = [];
    if !read_file("prompts/discovery.md", instructions) || !read_file("schemas/discovery-tools.json", tools) {
        report.reason = "discovery prompt/tools unavailable; run from the Continuum checkout";
        return report;
    }
    let context = discover_host();
    var body: u8[>..] = [];
    if !meta_request_body(config, config.controller_model, instructions, context, tools, body) {
        report.reason = "discovery context exceeds request bound";
        return report;
    }
    // Keep the input in its own replay buffer. find_raw_value's 8 KiB
    // provider-item ceiling is not the 32 KiB request/history ceiling.
    var sent: u8[>..] = [];
    if !opening_input(context, sent) { report.reason = "discovery input unavailable"; return report; }
    var trace: u8[>..] = []; trace.append("[");
    while report.model_calls < config.max_tool_rounds {
        report.model_calls += 1;
        let response = meta_exchange(config, "discovery", body);
        if response.outcome.status != Status.Completed {
            report.reason = response.outcome.message;
            break;
        }
        if !response.has_tool_call {
            report.summary = response.text;
            report.ok = response.text.len > 0;
            if !report.ok { report.reason = "Meta returned no discovery assessment"; }
            break;
        }
        let receipt = dispatch_discovery(response.tool, response.arguments_json);
        if trace.len > 1 { trace.append(","); }
        trace.append("{\"call_id\":"); json::format_string(trace, response.call_id);
        trace.append(",\"tool\":"); json::format_string(trace, tool_label(response.tool));
        trace.append(",\"result\":"); trace.append(receipt); trace.append("}");
        if trace.len > 16000 { report.reason = "discovery receipt bound reached"; break; }
        if report.model_calls >= config.max_tool_rounds { report.reason = "round budget reached before final assessment"; break; }
        var next_body: u8[>..] = [];
        if !meta_continuation_body(config, config.controller_model, instructions,
                sent, response.raw_output_json, response.call_id, receipt, tools, next_body) {
            report.reason = "discovery continuation exceeds bound";
            break;
        }
        var replayed: u8[>..] = [];
        if !meta_replay_input(sent, response.raw_output_json, response.call_id, receipt, replayed) {
            report.reason = "discovery continuation input unavailable";
            break;
        }
        sent = []; sent.append(replayed);
        body = []; body.append(next_body);
    }
    trace.append("]");
    if trace.len <= 16384 { report.tools_json = trace; }
    return report;
}
