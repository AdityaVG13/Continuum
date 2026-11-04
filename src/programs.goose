// Model-authored local logic and action sequences reuse the device guardian.
// Eight inline slots, four steps each, one private bounded registry; no daemon,
// answer cache or provider request is needed to execute a due program.
import .device;
import .meta_provider;
import json;
namespace continuum;

extern fn ct_setup_programs_load(out: u8[:], length: i64&) -> i32;
extern fn ct_setup_programs_store(data: const u8[:]) -> i32;
extern fn ct_setup_program_execute(source: const u8[:], input: const u8[:], timeout_ms: i64, out: u8[:], length: i64&) -> i32;

struct ProgramStep {
    operation: u8[..16] = "",
    payload: u8[..256] = "",
}
struct DeviceProgram {
    id: u8[..32] = "",
    purpose: u8[..256] = "",
    interval_ms: i64 = 0,
    steps: ProgramStep[..4] = [],
    source: u8[..1024] = "",
    installed_wall_ms: i64 = 0,
    candidate_id: u8[..64] = "",
    mac: u8[..64] = "",
    firmware: u8[..128] = "",
    enabled: bool = true,
    status: u8[..32] = "installed",
    last_attempt_wall_ms: i64 = 0,
    runs: i64 = 0,
    cursor: i64 = 0,
    last_result: u8[..4096] = "{}",
}
struct ProgramRegistry { programs: DeviceProgram[..8] = [] }

fn program_object(n: json::Node?, keys: const u8[:][:]) -> bool {
    if !n || !no_unknown(n, keys) { return false; }
    match n.val { Obj o => { return o.count == keys.len; }, _ => { return false; }, }
}
fn program_array(n: json::Node?) -> i64 {
    if !n { return -1; }
    match n.val { Arr a => { return a.count; }, _ => { return -1; }, }
}
fn program_spec(root: json::Node?, p: DeviceProgram&) -> const u8[:] {
    let keys: const u8[:][..5] = ["id", "purpose", "interval_ms", "steps", "source"];
    if !root || !no_unknown(root, keys) { return "invalid_program_schema"; }
    match root.val { Obj o => { if o.count != 4 && o.count != 5 { return "invalid_program_schema"; } }, _ => { return "invalid_program_schema"; }, }
    return program_fields(root, p);
}
// Both installation and durable loading borrow the owning document's nodes.
fn program_fields(root: json::Node?, p: DeviceProgram&) -> const u8[:] {
    let id, i = json::as_string(json::member(root, "id"));
    let purpose, u = json::as_string(json::member(root, "purpose"));
    let interval, t = json::as_i64(json::member(root, "interval_ms"));
    let source_node = json::member(root, "source");
    var source: u8[..1024] = "";
    if source_node {
        let text, valid = json::as_string(source_node);
        if !valid || text.len > 1024 { return "program_resource_bounds"; }
        source = text;
    }
    let steps = json::member(root, "steps"); let count = program_array(steps);
    if !steps || !i || !valid_id(id, 32) || !u || purpose.len == 0 || purpose.len > 256 || !t ||
            (interval != 0 && (interval < 60000 || interval > 86400000)) ||
            count < 0 || count > 4 || (source.len == 0 && count == 0) || (source.len > 0 && count != 0) {
        return "program_resource_bounds";
    }
    p = DeviceProgram { id: id, purpose: purpose, interval_ms: interval, source: source };
    return program_steps(steps, p);
}
fn program_steps(steps: json::Node?, p: DeviceProgram&) -> const u8[:] {
    let count = program_array(steps);
    if !steps || count < 0 || count > 4 { return "program_resource_bounds"; }
    let step_keys: const u8[:][..2] = ["operation", "payload"];
    var step = steps.first;
    while step {
        let operation, o = json::as_string(json::member(step, "operation"));
        let payload, v = json::as_string(json::member(step, "payload"));
        if !program_object(step, step_keys) || !o || !v || payload.len > 256 { return "invalid_program_step"; }
        if operation != "sample_host" && operation != "inspect" && operation != "runtime" &&
                operation != "apply" && operation != "restore" && operation != "verify" {
            return "unsupported_program_step";
        }
        if (operation == "apply" && device_features(payload) <= 0) || (operation != "apply" && payload.len > 0) {
            return "invalid_program_step_payload";
        }
        p.steps.push(ProgramStep { operation: operation, payload: payload });
        step .= step.next;
    }
    return "";
}
fn program_record(p: DeviceProgram, full: bool) -> u8[>..] {
    var out: u8[>..] = [];
    out.append("{\"id\":"); json::format_string(out, p.id);
    if !full {
        // List summaries stay bounded for every admitted slot, irrespective of
        // escaped source/results. Read one full specification by id instead.
        out.append(",\"enabled\":"); json::format_bool(out, p.enabled);
        out.append(",\"status\":"); json::format_string(out, p.status);
        out.append(",\"interval_ms\":"); json::format_int(out, p.interval_ms);
        out.append(",\"runs\":"); json::format_int(out, p.runs);
        out.append(",\"cursor\":"); json::format_int(out, p.cursor);
        out.append(",\"step_count\":"); json::format_int(out, p.steps.len);
        out.append("}"); return out;
    }
    out.append(",\"purpose\":"); json::format_string(out, p.purpose);
    out.append(",\"interval_ms\":"); json::format_int(out, p.interval_ms);
    out.append(",\"source\":"); json::format_string(out, p.source);
    out.append(",\"installed_wall_ms\":"); json::format_int(out, p.installed_wall_ms);
    out.append(",\"steps\":[");
    for step, index in p.steps {
        if index > 0 { out.append(","); }
        out.append("{\"operation\":"); json::format_string(out, step.operation);
        out.append(",\"payload\":"); json::format_string(out, step.payload); out.append("}");
    }
    out.append("],\"candidate_id\":"); json::format_string(out, p.candidate_id);
    out.append(",\"mac\":"); json::format_string(out, p.mac);
    out.append(",\"firmware\":"); json::format_string(out, p.firmware);
    out.append(",\"enabled\":"); json::format_bool(out, p.enabled);
    out.append(",\"status\":"); json::format_string(out, p.status);
    out.append(",\"last_attempt_wall_ms\":"); json::format_int(out, p.last_attempt_wall_ms);
    out.append(",\"runs\":"); json::format_int(out, p.runs);
    out.append(",\"cursor\":"); json::format_int(out, p.cursor);
    if full { out.append(",\"last_result\":"); json::format_string(out, p.last_result); }
    out.append("}"); return out;
}
fn programs_record(registry: ProgramRegistry, full: bool) -> u8[>..] {
    var out: u8[>..] = []; out.append("{\"schema_version\":1,\"programs\":[");
    for p, index in registry.programs {
        if index > 0 { out.append(","); }
        out.append(program_record(p, full));
    }
    out.append("]}"); return out;
}
fn programs_save(registry: ProgramRegistry) -> bool {
    let record = programs_record(registry, true);
    return record.len <= 65536 && ct_setup_programs_store(record) == 0;
}
fn programs_load(registry: ProgramRegistry&) -> bool {
    var buffer: u8[..65536] = [0; 65536]; var n: i64 = 0;
    if ct_setup_programs_load(buffer, n) != 0 || n < 0 || n > buffer.len { return false; }
    registry = ProgramRegistry {};
    if n == 0 { return true; }
    var doc: json::Node[>..] = []; var decoded: u8[>..] = [];
    let root, err = json::parse(buffer[..n], doc, decoded);
    let keys: const u8[:][..2] = ["schema_version", "programs"];
    let version, v = json::as_i64(json::member(root, "schema_version"));
    let entries = json::member(root, "programs"); let count = program_array(entries);
    if !entries || !program_object(root, keys) || !v || version != 1 || count < 0 || count > 8 { return false; }
    let fields: const u8[:][..15] = ["id", "purpose", "interval_ms", "steps", "candidate_id", "mac", "firmware",
        "enabled", "status", "last_attempt_wall_ms", "runs", "cursor", "last_result", "source", "installed_wall_ms"];
    var entry = entries.first;
    while entry {
        if !program_object(entry, fields) { return false; }
        var p = DeviceProgram {};
        if program_fields(entry, p).len > 0 { return false; }
        let target, b = json::as_string(json::member(entry, "candidate_id"));
        let mac, m = json::as_string(json::member(entry, "mac"));
        let firmware, f = json::as_string(json::member(entry, "firmware"));
        let enabled, e = json::as_bool(json::member(entry, "enabled"));
        let status, s = json::as_string(json::member(entry, "status"));
        let installed, a = json::as_i64(json::member(entry, "installed_wall_ms"));
        let last, l = json::as_i64(json::member(entry, "last_attempt_wall_ms"));
        let runs, r = json::as_i64(json::member(entry, "runs"));
        let cursor, c = json::as_i64(json::member(entry, "cursor"));
        let result, z = json::as_string(json::member(entry, "last_result"));
        if !b || !m || !f || !e || !s || !l || !r || !c || !z || !a || installed < 0 || installed > MAX_REVISIONS ||
                !valid_id(target, 64) || mac.len == 0 || mac.len > 64 || firmware.len == 0 || firmware.len > 128 ||
                last < 0 || last > MAX_REVISIONS || runs < 0 || runs > MAX_REVISIONS || result.len > 4096 ||
                (status != "installed" && status != "completed" && status != "running" && status != "failed" && status != "reconciled") {
            return false;
        }
        if cursor < 0 || cursor > (if p.source.len > 0 { 4 } else { p.steps.len }) { return false; }
        p.installed_wall_ms = installed;
        for previous in registry.programs { if previous.id == p.id { return false; } }
        p.candidate_id = target; p.mac = mac; p.firmware = firmware; p.enabled = enabled;
        p.status = status; p.last_attempt_wall_ms = last; p.runs = runs; p.cursor = cursor; p.last_result = result;
        registry.programs.push(p); entry .= entry.next;
    }
    return true;
}
fn program_index(registry: ProgramRegistry, id: const u8[:]) -> i64 {
    for p, index in registry.programs { if p.id == id { return index; } }
    return -1;
}
fn program_matches(p: DeviceProgram, d: DeviceState) -> bool {
    return p.candidate_id == "local" ||
        (p.candidate_id == d.candidate_id && p.mac == d.mac && p.firmware == d.firmware);
}
fn program_failed(registry: ProgramRegistry&, index: i64, reason: const u8[:]) -> DeviceToolResult {
    registry.programs[index].status = "failed";
    registry.programs[index].last_result = discovery_rejected(reason);
    if !programs_save(registry) { return device_tool_rejected("program_result_not_durable"); }
    return device_tool_rejected(reason);
}
fn program_run(directory: const u8[:], d: DeviceState&, registry: ProgramRegistry&, index: i64) -> DeviceToolResult {
    if index < 0 || index >= registry.programs.len { return device_tool_rejected("unknown_program"); }
    var p = registry.programs[index];
    var policy = OwnerPolicy {};
    if !owner_load(policy) { return device_tool_rejected("invalid_owner_policy"); }
    if p.source.len > 0 {
        let refused = owner_host_admit(policy);
        if refused.len > 0 { return device_tool_rejected(refused); }
    }
    if p.candidate_id != "local" && !d.setup_approved { return device_tool_rejected("standing_device_permission_required"); }
    if !p.enabled { return device_tool_rejected("program_disabled"); }
    if p.status == "running" || p.status == "failed" { return device_tool_rejected("program_reconciliation_required"); }
    var observed = DeviceObservation {};
    if p.candidate_id != "local" {
        observed = device_inventory(d);
        if !observed.authenticated || !device_identity(d, observed.receipt) {
            return device_tool_rejected(if observed.authenticated { d.reason } else { observed.reason });
        }
    }
    if !program_matches(p, d) { return device_tool_rejected("program_device_binding_changed"); }
    if p.runs >= MAX_REVISIONS { return device_tool_rejected("program_run_budget_exhausted"); }
    // Reserve timing and an ambiguous execution marker before the first step.
    // A crash never turns an unacknowledged effect into permission to retry.
    registry.programs[index].status = "running";
    registry.programs[index].last_attempt_wall_ms = ct_service_wall_ms();
    registry.programs[index].runs += 1; registry.programs[index].cursor = 0;
    if !programs_save(registry) { return device_tool_rejected("program_intent_not_durable"); }
    let start = ct_service_now_ms();
    var summary: u8[..512] = "";
    if p.source.len > 0 {
        var sample: u8[..4096] = [0; 4096]; var sample_len: i64 = 0;
        var input: u8[>..] = []; input.append("{\"host\":");
        if ct_setup_service_sample(sample, sample_len) == 0 && sample_len > 0 && sample_len <= sample.len {
            input.append(sample[..sample_len]);
        } else { input.append("null"); }
        input.append(",\"device\":"); input.append(device_view(d, observed));
        input.append(",\"owner_policy\":"); input.append(owner_record(policy)); input.append("}");
        var output: u8[..4096] = [0; 4096]; var output_len: i64 = 0;
        let executed = ct_setup_program_execute(p.source, input, policy.program_timeout_ms, output, output_len);
        if executed == -100 { return program_failed(registry, index, "program_sandbox_unavailable"); }
        if executed != 0 || output_len <= 0 || output_len > output.len { return program_failed(registry, index, "program_execution_failed"); }
        var doc: json::Node[>..] = []; var decoded: u8[>..] = [];
        let root, err = json::parse(output[..output_len], doc, decoded);
        let keys: const u8[:][..2] = ["actions", "summary"];
        let text, valid = json::as_string(json::member(root, "summary"));
        if !program_object(root, keys) || !valid || text.len > 512 { return program_failed(registry, index, "invalid_program_output"); }
        let reason = program_steps(json::member(root, "actions"), p);
        if reason.len > 0 { return program_failed(registry, index, reason); }
        // A host-only program never acquires a later-selected device's grant.
        if p.candidate_id == "local" {
            for step in p.steps { if step.operation != "sample_host" { return program_failed(registry, index, "program_device_binding_required"); } }
        }
        summary = text;
    }
    var receipts: u8[>..] = []; receipts.append("[");
    var completed: i64 = 0; var attempted = false; var ok = true;
    for step in p.steps {
        if ct_service_now_ms() - start >= 120000 { ok = false; break; }
        registry.programs[index].cursor = completed + 1;
        if !programs_save(registry) { return DeviceToolResult { receipt: discovery_rejected("program_step_not_durable"), mutation_attempted: attempted }; }
        var result = DeviceToolResult {};
        if step.operation == "sample_host" {
            var buffer: u8[..4096] = [0; 4096]; var n: i64 = 0;
            if ct_setup_service_sample(buffer, n) == 0 && n > 0 && n <= buffer.len {
                result = DeviceToolResult { receipt: buffer[..n], ok: true };
            } else { result = device_tool_rejected("host_sample_unavailable"); }
        } else {
            result = device_execute(directory, d, step.operation, step.payload);
        }
        attempted = attempted || result.mutation_attempted;
        if completed > 0 { receipts.append(","); }
        receipts.append("{\"operation\":"); json::format_string(receipts, step.operation);
        receipts.append(",\"ok\":"); json::format_bool(receipts, result.ok);
        receipts.append(",\"receipt\":");
        if result.receipt.len <= 1024 { receipts.append(result.receipt); }
        else {
            receipts.append("{\"truncated\":true,\"prefix\":"); json::format_string(receipts, result.receipt[..384]); receipts.append("}");
        }
        receipts.append("}");
        if !result.ok { ok = false; break; }
        completed += 1;
    }
    receipts.append("]");
    var report: u8[>..] = []; report.append("{\"status\":"); json::format_string(report, if ok { "completed" } else { "failed" });
    report.append(",\"program_id\":"); json::format_string(report, p.id);
    report.append(",\"steps_completed\":"); json::format_int(report, completed);
    report.append(",\"mutation_attempted\":"); json::format_bool(report, attempted);
    report.append(",\"elapsed_ms\":"); json::format_int(report, ct_service_now_ms() - start);
    report.append(",\"program_summary\":"); json::format_string(report, summary);
    report.append(",\"receipts\":"); report.append(receipts); report.append("}");
    if report.len > 4096 { return DeviceToolResult { receipt: discovery_rejected("program_result_over_bound"), mutation_attempted: attempted }; }
    registry.programs[index].status = if ok { "completed" } else { "failed" };
    registry.programs[index].cursor = completed; registry.programs[index].last_result = report;
    if !programs_save(registry) { return DeviceToolResult { receipt: discovery_rejected("program_result_not_durable"), mutation_attempted: attempted }; }
    return DeviceToolResult { receipt: report, mutation_attempted: attempted, ok: ok };
}
fn program_tool(directory: const u8[:], d: DeviceState&, operation: const u8[:], payload: const u8[:]) -> DeviceToolResult {
    var registry = ProgramRegistry {};
    if !programs_load(registry) { return device_tool_rejected("invalid_private_program_registry"); }
    if operation == "list_programs" {
        let record = programs_record(registry, false);
        if payload.len > 0 || record.len > 8192 { return device_tool_rejected("program_list_over_bound"); }
        return DeviceToolResult { receipt: record, ok: true };
    }
    var policy = OwnerPolicy {};
    if !owner_load(policy) { return device_tool_rejected("invalid_owner_policy"); }
    if operation == "prune_programs" {
        if payload.len > 0 { return device_tool_rejected("unexpected_operation_payload"); }
        let pruned = programs_prune(registry, d, policy);
        if pruned < 0 { return device_tool_rejected("program_control_not_durable"); }
        return DeviceToolResult { receipt: str("{\"status\":\"completed\",\"pruned\":", pruned, "}"), ok: true };
    }
    if operation == "install_program" {
        var doc: json::Node[>..] = []; var decoded: u8[>..] = [];
        let root, err = json::parse(payload, doc, decoded);
        var p = DeviceProgram {}; let reason = program_spec(root, p);
        if reason.len > 0 { return device_tool_rejected(reason); }
        if p.source.len > 0 {
            let refused = owner_host_admit(policy);
            if refused.len > 0 { return device_tool_rejected(refused); }
        } else if !d.setup_approved { return device_tool_rejected("standing_device_permission_required"); }
        if programs_prune(registry, d, policy) < 0 { return device_tool_rejected("program_control_not_durable"); }
        if registry.programs.len >= policy.max_programs || program_index(registry, p.id) >= 0 { return device_tool_rejected("program_slot_exhausted_or_id_exists"); }
        if d.candidate_id.len > 0 && d.setup_approved {
            let observed = device_inventory(d);
            if !observed.authenticated || !device_identity(d, observed.receipt) { return device_tool_rejected(observed.reason); }
            p.candidate_id = d.candidate_id; p.mac = d.mac; p.firmware = d.firmware;
            if !device_save(d) { return device_tool_rejected("program_install_not_durable"); }
        } else {
            p.candidate_id = "local"; p.mac = "local"; p.firmware = "local";
        }
        p.installed_wall_ms = ct_service_wall_ms();
        registry.programs.push(p);
        if !programs_save(registry) { return device_tool_rejected("program_install_not_durable"); }
        return DeviceToolResult { receipt: "{\"status\":\"installed\",\"installed\":true}", ok: true };
    }
    let index = program_index(registry, payload);
    if index < 0 { return device_tool_rejected("unknown_program"); }
    if operation == "run_program" { return program_run(directory, d, registry, index); }
    if operation == "read_program" {
        let record = program_record(registry.programs[index], true);
        if record.len > 8192 { return device_tool_rejected("program_result_over_bound"); }
        return DeviceToolResult { receipt: record, ok: true };
    }
    if operation == "disable_program" || operation == "enable_program" {
        if operation == "enable_program" {
            if registry.programs[index].candidate_id != "local" && !d.setup_approved { return device_tool_rejected("standing_device_permission_required"); }
            if registry.programs[index].source.len > 0 {
                let refused = owner_host_admit(policy);
                if refused.len > 0 { return device_tool_rejected(refused); }
            }
        }
        registry.programs[index].enabled = operation == "enable_program";
    } else if operation == "reconcile_program" {
        if registry.programs[index].candidate_id != "local" {
            if !d.setup_approved { return device_tool_rejected("standing_device_permission_required"); }
            let observed = device_inventory(d);
            if !observed.authenticated || !device_identity(d, observed.receipt) || !program_matches(registry.programs[index], d) {
                return device_tool_rejected("program_device_binding_changed");
            }
            if registry.programs[index].source.len > 0 && d.phase != "enrolled" {
                return device_tool_rejected("restore_owned_baseline_before_reconciliation");
            }
        }
        // Fresh inventory suffices only for observation-only programs. Effects
        // require a separately reconciled native baseline, never a guessed cursor.
        for step in registry.programs[index].steps {
            if step.operation == "apply" || step.operation == "restore" || step.operation == "verify" || step.operation == "runtime" {
                if d.phase != "enrolled" { return device_tool_rejected("restore_owned_baseline_before_reconciliation"); }
            }
        }
        registry.programs[index].status = "reconciled";
    } else { return device_tool_rejected("unsupported_program_operation"); }
    if !programs_save(registry) { return device_tool_rejected("program_control_not_durable"); }
    var out: u8[>..] = []; out.append("{\"status\":\"completed\",\"operation\":"); json::format_string(out, operation);
    out.append(",\"reconciled\":"); json::format_bool(out, operation == "reconcile_program");
    out.append(",\"enabled\":"); json::format_bool(out, registry.programs[index].enabled); out.append("}");
    return DeviceToolResult { receipt: out, ok: true };
}
// Compact records, never unlink files or delete active/unresolved evidence.
// Zero days disables expiry; clock rollback cannot age a newer record.
fn programs_prune(registry: ProgramRegistry&, d: DeviceState, policy: OwnerPolicy) -> i64 {
    if policy.program_retention_days == 0 { return 0; }
    let now = ct_service_wall_ms(); var kept = ProgramRegistry {}; var removed: i64 = 0;
    for p in registry.programs {
        let last = if p.last_attempt_wall_ms > 0 { p.last_attempt_wall_ms } else { p.installed_wall_ms };
        var effectful = p.source.len > 0 && p.candidate_id != "local";
        for step in p.steps { if step.operation != "inspect" && step.operation != "sample_host" { effectful = true; } }
        let inactive = !p.enabled || (p.interval_ms == 0 && p.status == "completed");
        if inactive && p.status != "running" && p.status != "failed" &&
                !(effectful && d.phase != "enrolled") && last > 0 && now >= last &&
                now - last >= policy.program_retention_days * 86400000 {
            removed += 1;
        } else { kept.programs.push(p); }
    }
    if removed > 0 {
        if !programs_save(kept) { return -1; }
        registry = kept;
    }
    return removed;
}
// Called under the same binding lock as owner operations. At most one program
// runs per sample; durable wall time prevents restart replay and clock rollback.
fn programs_tick(directory: const u8[:], d: DeviceState&) -> DeviceToolResult {
    var registry = ProgramRegistry {}; var policy = OwnerPolicy {};
    if !owner_load(policy) { return device_tool_rejected("invalid_owner_policy"); }
    if !programs_load(registry) { return device_tool_rejected("invalid_private_program_registry"); }
    if programs_prune(registry, d, policy) < 0 { return device_tool_rejected("program_control_not_durable"); }
    let now = ct_service_wall_ms();
    var chosen: i64 = -1; var earliest: i64 = MAX_REVISIONS;
    for p, index in registry.programs {
        if !p.enabled || p.interval_ms == 0 || p.status == "running" || p.status == "failed" || !program_matches(p, d) ||
                (p.candidate_id != "local" && !d.setup_approved) || (p.source.len > 0 && owner_host_admit(policy).len > 0) ||
                now < p.last_attempt_wall_ms || (p.last_attempt_wall_ms > 0 && now - p.last_attempt_wall_ms < p.interval_ms) { continue; }
        if p.last_attempt_wall_ms < earliest { earliest = p.last_attempt_wall_ms; chosen = index; }
    }
    if chosen < 0 { return DeviceToolResult { ok: true }; }
    return program_run(directory, d, registry, chosen);
}
fn programs_view(directory: const u8[:], out: u8[>..]&) {
    out.append("PROGRAMS / LOCAL\n\n");
    if !device_open(directory, 0) { out.append("Device binding busy; no state replaced.\n"); return; }
    var registry = ProgramRegistry {};
    let ok = programs_load(registry); ct_device_close();
    if !ok { out.append("Invalid private program registry; execution refused.\n"); return; }
    if registry.programs.len == 0 { out.append("No installed programs.\n"); }
    for p in registry.programs {
        out.append(str(p.id, " / ", p.status, if p.enabled { " / enabled" } else { " / disabled" },
            "\n  ", p.purpose, "\n  Interval ", p.interval_ms, " ms; runs ", p.runs, "; cursor ", p.cursor, "\n\n"));
    }
    out.append("No model call or device access was needed for this view.\nTUI actions (Programs screen): [Enter] Read by id  [x] Disable  [E] Enable  [R] Reconcile.\nCLI equivalents remain available: --program-read / --program-disable / --program-enable / --program-reconcile.\nInterrupted programs need explicit reconciliation, never automatic replay.\n");
}
fn program_cli(directory: const u8[:], operation: const u8[:], id: const u8[:]) -> i64 {
    if !device_open(directory, 1) { print(discovery_rejected("device_binding_busy")); return 1; }
    var d = DeviceState {};
    if !device_load(d) { ct_device_close(); print(discovery_rejected("invalid_private_device_binding")); return 1; }
    let result = program_tool(directory, d, operation, id);
    print(result.receipt); ct_device_close(); return if result.ok { 0 } else { 1 };
}
