// One capability boundary for foreground dialogue/setup and resident Meta.
// Callers hold the exclusive selected-device binding lock through dispatch.
// Policy lives in model workflows; effect guards and evidence live here/native.
import .device;
import .programs;
import .meta_provider;
import json;
import os;
namespace continuum;

struct DeviceToolResult {
    receipt: u8[..8192] = "{}",
    mutation_attempted: bool = false,
    ok: bool = false,
}
struct DeviceAgentReport {
    ok: bool = false,
    reason: u8[..256] = "",
    summary: u8[..2048] = "",
    model_calls: i64 = 0,
    mutation_attempted: bool = false,
}
fn device_tool_rejected(reason: const u8[:]) -> DeviceToolResult {
    return DeviceToolResult { receipt: discovery_rejected(reason) };
}
fn device_agent_tools(d: DeviceState) -> u8[>..] {
    var out: u8[>..] = [];
    if d.candidate_id.len == 0 {
        var policy = OwnerPolicy {};
        if !owner_load(policy) || owner_host_admit(policy).len > 0 { out.append("[]"); return out; }
    }
    if !read_file("schemas/device-tools.json", out) || out.len > 8192 { return []; }
    return out;
}
fn device_agent_instructions() -> u8[>..] {
    var out: u8[>..] = [];
    if !read_file("docs/prompts/device.md", out) || out.len > 8192 { return []; }
    return out;
}
fn device_skill(name: const u8[:]) -> DeviceToolResult {
    var path: u8[..128] = "";
    if name == "commissioning" { path = "docs/prompts/workflows/commissioning.md"; }
    else if name == "optimization" { path = "docs/prompts/workflows/optimization.md"; }
    else if name == "programs" { path = "docs/prompts/workflows/programs.md"; }
    else { return device_tool_rejected("unknown_workflow_skill"); }
    var content: u8[>..] = [];
    if !read_file(path, content) || content.len > 4096 { return device_tool_rejected("workflow_skill_unavailable"); }
    var out: u8[>..] = [];
    out.append("{\"status\":\"completed\",\"content\":"); json::format_string(out, content); out.append("}");
    if out.len > 8192 { return device_tool_rejected("workflow_skill_over_bound"); }
    return DeviceToolResult { receipt: out, ok: true };
}
// The model selects capability ids the device itself reported. Core validates
// the shape, uniqueness and owner protection; the adapter resolves each id to
// its own primitive and refuses one it never advertised.
fn device_selection(payload: const u8[:], disable: u8[..128]&) -> const u8[:] {
    var doc: json::Node[>..] = []; var decoded: u8[>..] = [];
    let root, err = json::parse(payload, doc, decoded);
    let keys: const u8[:][..1] = ["disable"];
    if !root || !no_unknown(root, keys) { return "select_at_least_one_supported_capability"; }
    match root.val { Obj o => { if o.count != 1 { return "select_at_least_one_supported_capability"; } }, _ => { return "select_at_least_one_supported_capability"; }, }
    let entries = json::member(root, "disable");
    if !entries { return "select_at_least_one_supported_capability"; }
    match entries.val { Arr a => { if a.count < 1 || a.count > 8 { return "select_at_least_one_supported_capability"; } }, _ => { return "select_at_least_one_supported_capability"; }, }
    var node = entries.first;
    var seen: const u8[:][..8] = [];
    while node {
        let id, valid = json::as_string(node);
        if !valid || id.len == 0 || id.len > 32 { return "capability_id_invalid"; }
        for old in seen { if old == id { return "capability_id_duplicate"; } }
        let protected = owner_protects(id);
        if protected.len > 0 { return protected; }
        seen.push(id);
        if disable.len > 0 { disable.append(","); }
        disable.append(id);
        node .= node.next;
    }
    if disable.len == 0 || disable.len > 128 { return "capability_id_invalid"; }
    return "";
}
// A qdisc profile is a closed vocabulary, validated before any device I/O.
// The native adapter rechecks every bound independently of this caller.
fn device_qos_profile(payload: const u8[:], profile: QosProfile&) -> bool {
    var doc: json::Node[>..] = [];
    var decoded: u8[>..] = [];
    let root, err = json::parse(payload, doc, decoded);
    let names: const u8[:][..4] = ["bandwidth_kbps", "interface", "mode", "overhead_bytes"];
    if !root || !no_unknown(root, names) { return false; }
    match root.val { Obj o => { if o.count != names.len { return false; } }, _ => { return false; }, }
    let bandwidth, b = json::as_i64(json::member(root, "bandwidth_kbps"));
    let iface, i = json::as_string(json::member(root, "interface"));
    let mode, m = json::as_string(json::member(root, "mode"));
    let overhead, h = json::as_i64(json::member(root, "overhead_bytes"));
    if !b || !i || !m || !h { return false; }
    if bandwidth < 256 || bandwidth > 100000 || overhead < 0 || overhead > 200 { return false; }
    if iface != "eth0" && iface != "ppp0" { return false; }
    if mode != "cake" && mode != "fq_codel" { return false; }
    profile.bandwidth_kbps = bandwidth;
    profile.interface_id = iface;
    profile.mode = mode;
    profile.overhead_bytes = overhead;
    return true;
}
// A qdisc change is an apply-class effect; undoing it is restore-class. The
// owner's existing grants gate both, so QoS cannot bypass a denied apply.
fn device_qos(d: DeviceState&, directory: const u8[:], operation: const u8[:], payload: const u8[:]) -> DeviceToolResult {
    if !d.setup_approved { return device_tool_rejected("standing_device_permission_required"); }
    let is_status = operation == "read_qos";
    let grant = if operation == "apply_qos" { "apply" } else if is_status { "runtime" } else { "restore" };
    let refused = owner_admit(grant, 0);
    if refused.len > 0 { return device_tool_rejected(refused); }
    // A read needs a durable receipt directory, not a mutation; apply/restore
    // need the owned baseline that directory stands for.
    if d.recovery_directory.len == 0 && !is_status { return device_tool_rejected("owned_baseline_required"); }
    if d.phase != "enrolled" && d.phase != "baseline_applied" && d.phase != "network_qualification_required" {
        return device_tool_rejected("owned_baseline_required");
    }
    if d.recovery_directory.len == 0 {
        d.recovery_directory = str(directory, "/device/recovery-", time_ns());
        if !device_save(d) { return device_tool_rejected("device_intent_not_durable"); }
    }
    var profile = QosProfile {};
    if operation == "apply_qos" {
        if !device_qos_profile(payload, profile) { return device_tool_rejected("invalid_qos_profile"); }
    } else if payload.len != 0 {
        return device_tool_rejected("unexpected_operation_payload");
    }
    let observed = device_inventory(d);
    if !observed.authenticated || !device_identity(d, observed.receipt) {
        return device_tool_rejected(if observed.authenticated { d.reason } else { observed.reason });
    }
    let op = if operation == "restore_qos" { "restore" } else if operation == "read_qos" { "status" } else { "apply" };
    var raw: u8[>..] = [];
    let attempted = !is_status;
    let ok = commission_qos(d.connection, d.recovery_directory, true, op, profile, raw, true);
    if !ok {
        d.reason = "qos_operation_unresolved_inspect_before_retry";
        if !device_save(d) { return DeviceToolResult { receipt: discovery_rejected("device_result_not_durable"), mutation_attempted: attempted }; }
        return DeviceToolResult { receipt: if raw.len > 0 && raw.len <= 8192 { raw } else { discovery_rejected(d.reason) }, mutation_attempted: attempted };
    }
    if !device_identity(d, raw) {
        device_save(d);
        return DeviceToolResult { receipt: discovery_rejected(d.reason), mutation_attempted: attempted };
    }
    var doc: json::Node[>..] = [];
    var decoded: u8[>..] = [];
    let receipt, err = json::parse(raw, doc, decoded);
    let verified, v = json::as_bool(json::member(receipt, "qos_verified"));
    if !verified || !v {
        return DeviceToolResult { receipt: discovery_rejected("qos_readback_unverified"), mutation_attempted: attempted };
    }
    // A read changes nothing; an apply or restore replaces the qdisc the last
    // measurement described, so a qualification earned against the old shape is
    // no longer about this baseline and must be re-earned.
    if !is_status {
        d.network_load_verified = false;
        d.baseline_at = time_ns();
        d.reason = "qdisc_changed_measurement_required";
    }
    if !device_save(d) { return DeviceToolResult { receipt: discovery_rejected("device_result_not_durable"), mutation_attempted: attempted }; }
    if raw.len > 8192 { return DeviceToolResult { receipt: discovery_rejected("device_receipt_over_bound"), mutation_attempted: attempted }; }
    return DeviceToolResult { receipt: raw, mutation_attempted: attempted, ok: true };
}
fn device_dispatch(directory: const u8[:], d: DeviceState&, response: ModelResult) -> DeviceToolResult {
    if response.tool != ToolName.ManageDevice && response.tool != ToolName.InspectSystem {
        return device_tool_rejected("physical_actuation_unqualified");
    }
    var doc: json::Node[>..] = []; var decoded: u8[>..] = [];
    let root, err = json::parse(response.arguments_json, doc, decoded);
    let id, i = json::as_string(json::member(root, "candidate_id"));
    let local = d.candidate_id.len == 0;
    let target = if local { "local" } else { d.candidate_id };
    if !root || !i || id != target {
        return device_tool_rejected("owner_selected_device_required");
    }
    var operation: u8[..32] = "inspect"; var payload: u8[..2048] = "";
    if response.tool == ToolName.ManageDevice {
        let known: const u8[:][..3] = ["candidate_id", "operation", "payload"];
        let op, o = json::as_string(json::member(root, "operation"));
        let text, t = json::as_string(json::member(root, "payload"));
        if !no_unknown(root, known) || !o || !t || op.len > 32 || text.len > 2048 {
            return device_tool_rejected("invalid_device_tool_arguments");
        }
        operation = op; payload = text;
    } else {
        let known: const u8[:][..1] = ["candidate_id"];
        if !no_unknown(root, known) { return device_tool_rejected("invalid_device_tool_arguments"); }
    }
    if operation == "read_skill" { return device_skill(payload); }
    if operation == "read_policy" {
        var policy = OwnerPolicy {};
        if payload.len != 0 || !owner_load(policy) { return device_tool_rejected("invalid_owner_policy"); }
        return DeviceToolResult { receipt: owner_record(policy), ok: true };
    }
    if operation == "install_program" || operation == "list_programs" || operation == "read_program" ||
            operation == "run_program" || operation == "disable_program" || operation == "enable_program" ||
            operation == "reconcile_program" || operation == "prune_programs" {
        return program_tool(directory, d, operation, payload);
    }
    if local { return device_tool_rejected("owner_selected_device_required"); }
    return device_execute(directory, d, operation, payload);
}
// Both model dispatch and admitted straight-line programs enter the same
// authority/effect boundary. Programs cannot recursively invoke model tools.
fn device_execute(directory: const u8[:], d: DeviceState&, operation: const u8[:], payload: const u8[:], approved: bool = false) -> DeviceToolResult {
    // No model-supplied approval field is accepted. Reboot authority can only
    // come from the owner's separate policy editor, not a tool argument.
    if operation == "reboot" {
        let refused = owner_admit(operation);
        if refused.len > 0 { return device_tool_rejected(refused); }
        if !d.setup_approved { return device_tool_rejected("standing_device_permission_required"); }
        let ok = device_request_reboot(d);
        if !device_save(d) { return DeviceToolResult { receipt: discovery_rejected("device_result_not_durable"), mutation_attempted: true }; }
        return DeviceToolResult { receipt: device_record(d), mutation_attempted: true, ok: ok };
    }
    if operation == "remember" {
        d.knowledge = payload;
        if !device_save(d) { return device_tool_rejected("device_context_not_durable"); }
        return DeviceToolResult { receipt: "{\"status\":\"completed\",\"knowledge_saved\":true}", ok: true };
    }
    if operation == "capabilities" {
        // Read-only architecture description. The device reports capability
        // classes; core never names a vendor key or an optional-service list.
        if payload.len != 0 { return device_tool_rejected("unexpected_operation_payload"); }
        let observed = device_inventory(d);
        if !observed.authenticated || !device_identity(d, observed.receipt) {
            return device_tool_rejected(if observed.authenticated { d.reason } else { observed.reason });
        }
        var raw: u8[>..] = [];
        if !commission_request(d.connection, "capabilities", "", false, raw, true) {
            return DeviceToolResult { receipt: if raw.len > 0 && raw.len <= 8192 { raw } else { discovery_rejected("capabilities_unavailable") }, mutation_attempted: false };
        }
        var doc: json::Node[>..] = []; var decoded: u8[>..] = [];
        let receipt, err = json::parse(raw, doc, decoded);
        let identity = json::member(receipt, "identity");
        let product, p = json::as_string(json::member(identity, "productid"));
        let mac, m = json::as_string(json::member(identity, "mac"));
        if !receipt || !identity || !p || !m || product != d.productid || mac != d.mac {
            return device_tool_rejected("capability_identity_mismatch");
        }
        if raw.len > 8192 { return device_tool_rejected("device_receipt_over_bound"); }
        return DeviceToolResult { receipt: raw, ok: true };
    }
    if operation == "apply_qos" || operation == "restore_qos" || operation == "read_qos" {
        return device_qos(d, directory, operation, payload);
    }
    if operation != "inspect" && operation != "enroll" && operation != "runtime" &&
            operation != "apply" && operation != "restore" && operation != "verify" {
        return device_tool_rejected("unsupported_device_capability");
    }
    if operation != "apply" && payload.len != 0 { return device_tool_rejected("unexpected_operation_payload"); }
    if operation == "inspect" {
        let observed = device_inventory(d);
        if observed.authenticated && device_identity(d, observed.receipt) {
            if d.phase == "selected" || d.phase == "enrolling" { d.phase = "enrolled"; }
            if !device_save(d) { return device_tool_rejected("device_identity_not_durable"); }
        }
        return DeviceToolResult { receipt: device_view(d, observed), ok: observed.authenticated };
    }
    if !d.setup_approved { return device_tool_rejected("standing_device_permission_required"); }
    // `approved` is only ever set by an owner-confirmed CLI step, never by a
    // model tool argument or a program.
    let permitted = owner_admit(operation, 0, approved);
    if permitted.len > 0 { return device_tool_rejected(permitted); }
    if operation == "enroll" {
        if d.phase != "selected" && d.phase != "enrolling" && d.phase != "enrolled" {
            return device_tool_rejected("reconcile_existing_device_before_enrollment");
        }
        let ok = device_enroll(directory, d, false);
        if !device_save(d) { return device_tool_rejected("device_intent_not_durable"); }
        return DeviceToolResult { receipt: if ok { "{\"status\":\"completed\",\"phase\":\"enrolled\"}" }
            else { discovery_rejected(d.reason) }, mutation_attempted: true, ok: ok };
    }
    let observed = device_inventory(d);
    if !observed.authenticated || !device_identity(d, observed.receipt) {
        return device_tool_rejected(if observed.authenticated { d.reason } else { observed.reason });
    }
    var disable: u8[..128] = "";
    if operation == "apply" {
        let selection = device_selection(payload, disable);
        if selection.len > 0 { return device_tool_rejected(selection); }
        if d.phase != "enrolled" { return device_tool_rejected("reconcile_existing_baseline_before_apply"); }
        d.recovery_directory = str(directory, "/device/recovery-", time_ns());
        d.phase = "commissioning";
    } else if d.recovery_directory.len == 0 {
        if operation != "runtime" { return device_tool_rejected("owned_baseline_required"); }
        d.recovery_directory = str(directory, "/device/recovery-", time_ns());
    }
    // Intent is durable before the native transaction; errors never imply no effect.
    if !device_save(d) { return device_tool_rejected("device_intent_not_durable"); }
    var raw: u8[>..] = [];
    let attempted = true;
    let ok = commission_request(d.connection, operation, d.recovery_directory, true, raw, true, disable);
    if !ok {
        d.reason = "device_operation_unresolved_inspect_before_retry";
        // The native apply writes this apply's baseline.json before its first
        // router write, in a directory created for this apply. Without it the
        // router was never touched, so the unit is still plainly enrolled and a
        // retry needs no restore (which would refuse: no baseline to restore).
        var written: u8[>..] = [];
        if operation == "apply" && !read_file(str(d.recovery_directory, "/baseline.json"), written) { d.phase = "enrolled"; }
        if !device_save(d) { return DeviceToolResult { receipt: discovery_rejected("device_result_not_durable"), mutation_attempted: attempted }; }
        return DeviceToolResult { receipt: if raw.len > 0 && raw.len <= 8192 { raw } else { discovery_rejected(d.reason) }, mutation_attempted: attempted };
    }
    if !device_identity(d, raw) {
        device_save(d);
        return DeviceToolResult { receipt: discovery_rejected(d.reason), mutation_attempted: attempted };
    }
    var receipt_doc: json::Node[>..] = []; var receipt_text: u8[>..] = [];
    let receipt, receipt_err = json::parse(raw, receipt_doc, receipt_text);
    let runtime, rt = json::as_bool(json::member(receipt, "runtime_verified"));
    let recovery, re = json::as_bool(json::member(receipt, "recovery_verified"));
    let persistence, pe = json::as_bool(json::member(receipt, "persistence_verified"));
    if operation == "apply" {
        if !rt || !runtime || !re || !recovery {
            return DeviceToolResult { receipt: discovery_rejected("runtime_or_recovery_unverified"), mutation_attempted: attempted };
        }
        d.runtime_verified = true; d.recovery_verified = true; d.persistence_verified = false; d.phase = "baseline_applied";
        d.network_load_verified = false; d.baseline_at = time_ns();
    } else if operation == "restore" {
        d.phase = "enrolled"; d.runtime_verified = false; d.recovery_verified = false; d.persistence_verified = false;
        d.network_load_verified = false; d.baseline_at = 0;
    } else if operation == "verify" && pe && persistence {
        d.persistence_verified = true; d.phase = "network_qualification_required";
        d.network_load_verified = false; d.baseline_at = time_ns();
    }
    d.reason = "routed_load_and_general_crash_recovery_unqualified";
    if !device_save(d) { return DeviceToolResult { receipt: discovery_rejected("device_result_not_durable"), mutation_attempted: attempted }; }
    if operation == "runtime" {
        let path, p = json::as_string(json::member(receipt, "runtime_path"));
        var inventory: u8[>..] = [];
        if !p || !read_file(path, inventory) { return DeviceToolResult { receipt: discovery_rejected("runtime_artifact_unavailable"), mutation_attempted: attempted }; }
        let shown = if inventory.len > 4096 { 4096 } else { inventory.len };
        var enriched: u8[>..] = [];
        enriched.append("{\"receipt\":"); enriched.append(raw); enriched.append(",\"runtime\":");
        json::format_string(enriched, inventory[..shown]); enriched.append(",\"truncated\":");
        json::format_bool(enriched, shown < inventory.len); enriched.append("}"); raw = []; raw.append(enriched);
    }
    if raw.len > 8192 { return DeviceToolResult { receipt: discovery_rejected("device_receipt_over_bound"), mutation_attempted: attempted }; }
    return DeviceToolResult { receipt: raw, mutation_attempted: attempted, ok: true };
}
fn device_agent_input(d: DeviceState, observed: DeviceObservation, message: const u8[:], budget: i64) -> u8[>..] {
    var out: u8[>..] = [];
    out.append("{\"role\":\"device_agent\",\"owner_message\":"); json::format_string(out, message);
    out.append(",\"execution_target\":"); json::format_string(out, if d.candidate_id.len == 0 { "local" } else { d.candidate_id });
    out.append(",\"standing_device_permission\":"); json::format_bool(out, d.setup_approved);
    out.append(",\"model_call_budget\":"); json::format_int(out, budget);
    out.append(",\"budget_note\":\"Each tool call and the final summary use one model call; the run stops when the budget is spent.\"");
    out.append(",\"device\":"); out.append(device_view(d, observed));
    var policy = OwnerPolicy {};
    out.append(",\"owner_policy\":");
    if owner_load(policy) { out.append(owner_record(policy)); } else { out.append("null"); }
    out.append(",\"knowledge\":"); json::format_string(out, d.knowledge);
    out.append(",\"last_exchange\":"); json::format_string(out, d.last_exchange); out.append("}"); return out;
}
fn run_device_agent(model: ModelConfig, directory: const u8[:], message: const u8[:], approve_setup: bool) -> DeviceAgentReport {
    var report = DeviceAgentReport {};
    if message.len == 0 || message.len > 1024 || !meta_credentials_available(model) {
        report.reason = "bounded_message_and_model_credentials_required"; return report;
    }
    let instructions = device_agent_instructions();
    if instructions.len == 0 || !device_open(directory, 1) { report.reason = "agent_resources_or_device_binding_unavailable"; return report; }
    var d = DeviceState {};
    if !device_load(d) || (approve_setup && d.candidate_id.len == 0) {
        ct_device_close(); report.reason = "select_device_before_granting_authority"; return report;
    }
    if approve_setup {
        d.setup_approved = true;
        if !device_save(d) { ct_device_close(); report.reason = "device_permission_not_durable"; return report; }
    }
    let opening = device_inventory(d);
    // A router that refuses Continuum's saved admin password (typically a
    // factory reset since enrollment) cannot be worked by any tool; say so
    // before spending a model call.
    if !opening.authenticated && opening.reason == "protected_authentication_refused" {
        ct_device_close(); report.reason = "protected_authentication_refused"; return report;
    }
    let input = device_agent_input(d, opening, message, model.max_tool_rounds);
    let tools = device_agent_tools(d);
    var body: u8[>..] = []; var sent: u8[>..] = []; var trail: u8[>..] = [];
    if tools.len == 0 || !meta_request_body(model, model.controller_model, instructions, input, tools, body) || !opening_input(input, sent) {
        ct_device_close(); report.reason = "agent_request_over_bound_or_resources_missing"; return report;
    }
    while report.model_calls < model.max_tool_rounds {
        report.model_calls += 1;
        let response = meta_exchange(model, "device-agent", body);
        if response.outcome.status != Status.Completed { report.reason = "model_failed_no_automatic_retry"; break; }
        if !response.has_tool_call {
            if response.text.len == 0 || response.text.len > 2048 { report.reason = "model_summary_over_bound"; break; }
            report.summary = response.text;
            if d.candidate_id.len > 0 {
                // One bounded exchange, not an unbounded resident transcript.
                // Preserve a complete answer; trim only the oldest request tail
                // when the combined byte bound would otherwise be exceeded.
                let kept = if message.len > 1000 { 1000 } else { message.len };
                let exchange = str("Owner: ", message[..kept], "\nMeta: ", response.text);
                d.last_exchange = exchange;
                if !device_save(d) { report.reason = "dialogue_not_durable"; break; }
            }
            report.ok = true; break;
        }
        let result = device_dispatch(directory, d, response);
        // Which operations the budget went to, for a refusal the owner can act on.
        var adoc: json::Node[>..] = []; var atext: u8[>..] = [];
        let aroot, aerr = json::parse(response.arguments_json, adoc, atext);
        let aop, has_op = json::as_string(json::member(aroot, "operation"));
        if trail.len > 0 { trail.append(", "); }
        if response.tool == ToolName.InspectSystem { trail.append("inspect_system"); }
        else if has_op && aop.len <= 32 { trail.append(aop); } else { trail.append("?"); }
        report.mutation_attempted = report.mutation_attempted || result.mutation_attempted;
        var next: u8[>..] = []; var replayed: u8[>..] = [];
        if !meta_continuation_body(model, model.controller_model, instructions, sent, response.raw_output_json,
                response.call_id, result.receipt, tools, next) ||
                !meta_replay_input(sent, response.raw_output_json, response.call_id, result.receipt, replayed) {
            report.reason = "agent_continuation_over_bound"; break;
        }
        body = []; body.append(next); sent = []; sent.append(replayed);
    }
    ct_device_close();
    if !report.ok && report.reason.len == 0 {
        var why: u8[>..] = []; why.append("model_round_budget_exhausted after: "); why.append(trail);
        report.reason = if why.len <= 256 { why[..why.len] } else { why[..256] };
    }
    return report;
}
fn device_agent_record(report: DeviceAgentReport) -> u8[>..] {
    var out: u8[>..] = [];
    out.append("{\"status\":"); json::format_string(out, if report.ok { "completed" } else { "failed" });
    out.append(",\"model_calls\":"); json::format_int(out, report.model_calls);
    out.append(",\"mutation_attempted\":"); json::format_bool(out, report.mutation_attempted);
    out.append(",\"summary\":"); json::format_string(out, report.summary);
    out.append(",\"reason\":"); json::format_string(out, report.reason); out.append("}"); return out;
}
