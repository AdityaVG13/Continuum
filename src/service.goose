// Resident observations plus owner-scoped Meta capabilities. The simulator is a separate
// comparison lane; host counters never authorize its simulated actuator.
import .setup;
import .meta_provider;
import .device;
import .device_agent;
import json;
import os;
namespace continuum;

extern fn ct_setup_service_open(path: const u8[:]) -> i32;
extern fn ct_setup_service_sample(out: u8[:], length: i64&) -> i32;
extern fn ct_setup_service_load(out: u8[:], length: i64&) -> i32;
extern fn ct_setup_service_store(data: const u8[:], durable: i32) -> i32;
extern fn ct_service_close() -> i32;
extern fn ct_service_wait(milliseconds: i64) -> i32;
extern fn ct_service_now_ms() -> i64;
extern fn ct_service_wall_ms() -> i64;
extern fn ct_service_pid() -> i64;

struct ServiceSample {
    ok: bool = false,
    routes_known: bool = false,
    routes: i64 = 0,
    signature: u8[..2048] = "",
    counters_known: bool = false,
    faults: i64 = 0,
    raw: u8[..4096] = "{\"provenance\":\"unavailable\"}",
}
struct ServiceState {
    samples: i64 = 0,
    previous: ServiceSample = ServiceSample {},
    incident: u8[..64] = "",
    incident_attempted: bool = false,
    unhealthy_samples: i64 = 0,
    healthy_samples: i64 = 0,
    window_started_wall_ms: i64 = 0,
    last_call_wall_ms: i64 = 0,
    calls: i64 = 0,
    assessment_status: u8[..64] = "not_requested",
    last_assessment: u8[..2048] = "",
    mutation_attempted: bool = false,
    device: DeviceState = DeviceState {},
    device_observation: DeviceObservation = DeviceObservation {},
}

fn service_sample() -> ServiceSample {
    var buffer: u8[..4096] = [0; 4096]; var n: i64 = 0;
    if ct_setup_service_sample(buffer, n) != 0 || n <= 0 || n > buffer.len { return ServiceSample {}; }
    var doc: json::Node[>..] = []; var decoded: u8[>..] = [];
    let root, err = json::parse(buffer[..n], doc, decoded);
    let known, k = json::as_bool(json::member(root, "routes_known"));
    let routes, r = json::as_i64(json::member(root, "ipv4_default_routes"));
    let signature, s = json::as_string(json::member(root, "route_signature"));
    let counters, c = json::as_bool(json::member(root, "counters_known"));
    let faults, f = json::as_i64(json::member(root, "interface_faults"));
    if !root || !k || !r || !s || !c || !f || routes < 0 || faults < 0 || signature.len > 2048 {
        return ServiceSample {};
    }
    return ServiceSample { ok: true, routes_known: known, routes: routes, signature: signature,
        counters_known: counters, faults: faults, raw: buffer[..n] };
}

// Missing IPv4 evidence is not proof of an Internet outage. Counter decreases
// rebase naturally (reset/wrap); only positive same-path deltas are incidents.
fn service_note(state: ServiceState&, sample: ServiceSample) {
    var reason: u8[..64] = "";
    if !sample.ok || !sample.routes_known { reason = "host_observation_unavailable"; }
    else if sample.routes == 0 { reason = "no_ipv4_default_route"; }
    else if state.previous.ok && state.previous.routes_known &&
            state.previous.signature != sample.signature { reason = "ipv4_route_changed"; }
    else if state.previous.ok && sample.counters_known && state.previous.counters_known &&
            sample.faults > state.previous.faults { reason = "interface_error_or_drop_increase"; }
    if reason.len == 0 && state.device.candidate_id.len > 0 && !state.device_observation.authenticated {
        reason = "selected_device_unavailable";
    }
    state.samples += 1;
    if reason.len > 0 {
        state.healthy_samples = 0; state.unhealthy_samples += 1;
        if reason == "ipv4_route_changed" || state.unhealthy_samples >= 2 {
            if state.incident != reason { state.incident_attempted = false; }
            state.incident = reason;
        }
    } else {
        state.unhealthy_samples = 0; state.healthy_samples += 1;
        if state.healthy_samples >= 2 { state.incident = ""; state.incident_attempted = false; }
    }
    state.previous = sample;
}

fn service_record(cfg: ServiceConfig, state: ServiceState, phase: const u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    out.append("{\"schema_version\":1,\"phase\":"); json::format_string(out, phase);
    out.append(",\"pid\":"); json::format_int(out, ct_service_pid());
    out.append(",\"samples\":"); json::format_int(out, state.samples);
    out.append(",\"sample_interval_ms\":"); json::format_int(out, cfg.sample_interval_ms);
    out.append(",\"observed_monotonic_ms\":"); json::format_int(out, ct_service_now_ms());
    // An attempted effect may be unresolved; do not publish a false no-change claim.
    out.append(",\"network_changed\":"); out.append(if state.mutation_attempted { "null" } else { "false" });
    out.append(",\"mutation_attempted\":"); json::format_bool(out, state.mutation_attempted);
    out.append(",\"task_context\":null,\"meta_permission\":");
    out.append(if cfg.allow_meta { "true" } else { "false" });
    out.append(",\"model_calls_this_hour\":"); json::format_int(out, state.calls);
    out.append(",\"window_started_wall_ms\":"); json::format_int(out, state.window_started_wall_ms);
    out.append(",\"last_call_wall_ms\":"); json::format_int(out, state.last_call_wall_ms);
    out.append(",\"incident\":"); json::format_string(out, state.incident);
    out.append(",\"assessment_status\":"); json::format_string(out, state.assessment_status);
    out.append(",\"last_assessment\":"); json::format_string(out, state.last_assessment);
    out.append(",\"device\":"); out.append(device_view(state.device, state.device_observation));
    out.append(",\"observation\":"); out.append(state.previous.raw); out.append("}\n");
    return out;
}
fn service_publish(cfg: ServiceConfig, state: ServiceState, phase: const u8[:], durable: i32) -> bool {
    let record = service_record(cfg, state, phase);
    return record.len <= 16384 && ct_setup_service_store(record, durable) == 0;
}

// Reserve spend durably BEFORE dispatch. Restarts cannot reset the hourly cap;
// a wall-clock rollback cannot replenish it. Invalid prior state fails closed.
fn service_restore_budget(state: ServiceState&) -> bool {
    var buffer: u8[..16384] = [0; 16384]; var n: i64 = 0;
    if ct_setup_service_load(buffer, n) != 0 || n < 0 || n > buffer.len { return false; }
    if n == 0 { state.window_started_wall_ms = ct_service_wall_ms(); return true; }
    var doc: json::Node[>..] = []; var decoded: u8[>..] = [];
    let root, err = json::parse(buffer[..n], doc, decoded);
    let version, v = json::as_i64(json::member(root, "schema_version"));
    let calls, c = json::as_i64(json::member(root, "model_calls_this_hour"));
    let window, w = json::as_i64(json::member(root, "window_started_wall_ms"));
    let last, l = json::as_i64(json::member(root, "last_call_wall_ms"));
    let assessment, a = json::as_string(json::member(root, "last_assessment"));
    if !root || !v || version != 1 || !c || !w || !l || !a || calls < 0 || calls > 8 ||
            window <= 0 || last < 0 || assessment.len > 2048 { return false; }
    state.calls = calls; state.window_started_wall_ms = window; state.last_call_wall_ms = last;
    state.last_assessment = assessment;
    return true;
}

// Each continuation consumes a separately durable spend reservation. Tool
// results are real protected reads or explicit guardian refusals, not a canned
// success; only bounded model text is retained after the conversation ends.
fn service_assess(model: ModelConfig, cfg: ServiceConfig, state: ServiceState&) -> bool {
    var input: u8[>..] = [];
    input.append("{\"role\":\"service_incident\",\"authority\":");
    json::format_string(input, if state.device.setup_approved { "owner_scoped_device_capabilities" } else { "read_only" });
    input.append(",\"knowledge\":"); json::format_string(input, state.device.knowledge);
    input.append(",\"last_exchange\":"); json::format_string(input, state.device.last_exchange);
    input.append(",\"task_context\":null,\"incident\":");
    json::format_string(input, state.incident);
    input.append(",\"observation\":"); input.append(state.previous.raw);
    input.append(",\"device\":"); input.append(device_view(state.device, state.device_observation));
    input.append(",\"execution_target\":"); json::format_string(input, if state.device.candidate_id.len == 0 { "local" } else { state.device.candidate_id });
    var policy = OwnerPolicy {};
    input.append(",\"owner_policy\":");
    if owner_load(policy) { input.append(owner_record(policy)); } else { input.append("null"); }
    input.append("}");
    let instructions = device_agent_instructions();
    let tools = device_agent_tools(state.device);
    if instructions.len == 0 || tools.len == 0 { state.assessment_status = "agent_resources_missing"; return true; }
    var body: u8[>..] = []; var sent: u8[>..] = [];
    if !meta_request_body(model, model.controller_model, instructions, input, tools, body) ||
            !opening_input(input, sent) { state.assessment_status = "request_over_bound"; return true; }
    var rounds: i64 = 0;
    while rounds < model.max_tool_rounds {
        if ct_service_wait(0) != 0 { state.assessment_status = "cancelled"; return true; }
        let wall = ct_service_wall_ms();
        if wall < state.window_started_wall_ms || state.calls >= cfg.max_calls_per_hour {
            state.assessment_status = "budget_exhausted"; return true;
        }
        state.calls += 1; state.last_call_wall_ms = wall; rounds += 1;
        state.assessment_status = "awaiting_meta";
        if !service_publish(cfg, state, "awaiting_meta", 1) { return false; }
        let response = meta_exchange(model, "service-incident", body);
        if response.outcome.status != Status.Completed {
            state.assessment_status = "failed_no_automatic_retry"; return true;
        }
        if !response.has_tool_call {
            if response.text.len > 0 && response.text.len <= 2048 {
                state.last_assessment = response.text; state.assessment_status = "completed";
            } else { state.assessment_status = "failed_no_automatic_retry"; }
            return true;
        }
        if ct_service_wait(0) != 0 { state.assessment_status = "cancelled"; return true; }
        let result = device_dispatch(setup_directory(), state.device, response);
        state.mutation_attempted = state.mutation_attempted || result.mutation_attempted;
        let receipt = result.receipt;
        var next_body: u8[>..] = []; var replayed: u8[>..] = [];
        if !meta_continuation_body(model, model.controller_model, instructions, sent,
                response.raw_output_json, response.call_id, receipt, tools, next_body) ||
                !meta_replay_input(sent, response.raw_output_json, response.call_id, receipt, replayed) {
            state.assessment_status = "continuation_over_bound"; return true;
        }
        body = []; body.append(next_body); sent = []; sent.append(replayed);
    }
    state.assessment_status = "round_budget_exhausted"; return true;
}

fn run_service(model: ModelConfig, sample_limit: i64) -> Outcome {
    let directory = setup_directory();
    var cfg = ServiceConfig {};
    if directory.len == 0 || !load_service_config(directory, cfg) {
        return Outcome { status: Status.Rejected, message: "service settings invalid; no monitoring or model call" };
    }
    if ct_setup_service_open(str(directory, "/service")) != 0 {
        return Outcome { status: Status.Rejected, message: "service already running or private state unavailable" };
    }
    var state = ServiceState {};
    var ok = service_restore_budget(state);
    if cfg.allow_meta && !meta_credentials_available(model) { ct_tui_key_load(); }
    let available = cfg.allow_meta && meta_credentials_available(model);
    if !ok { ct_service_close(); return Outcome { status: Status.Failed, message: "saved service budget invalid; no provider call" }; }
    while sample_limit == 0 || state.samples < sample_limit {
        // A pending shutdown is checked before admitting another observation.
        if ct_service_wait(0) != 0 { break; }
        // One exclusive lock spans observation and a possible guarded mutation.
        // Foreground setup/dialogue can own the device between samples only.
        state.device = DeviceState {}; state.device_observation = DeviceObservation {};
        let bound = device_open(directory, 1);
        if bound {
            if !device_load(state.device) { ok = false; ct_device_close(); break; }
            state.device_observation = device_inventory(state.device);
        } else { state.device_observation.reason = "device_binding_busy_or_unavailable"; }
        if bound {
            let programmed = programs_tick(directory, state.device);
            state.mutation_attempted = state.mutation_attempted || programmed.mutation_attempted;
            if !programmed.ok { state.assessment_status = "program_failed_inspect_registry"; }
        }
        let sample = service_sample();
        service_note(state, sample);
        let wall = ct_service_wall_ms();
        if wall >= state.window_started_wall_ms + 3600000 {
            state.calls = 0; state.window_started_wall_ms = wall;
        }
        if state.incident.len > 0 && !state.incident_attempted {
            if !cfg.allow_meta { state.assessment_status = "permission_not_granted"; }
            else if !available { state.assessment_status = "credentials_unavailable"; }
            else if wall < state.window_started_wall_ms || state.calls >= cfg.max_calls_per_hour {
                state.assessment_status = "budget_exhausted";
            } else if state.last_call_wall_ms > 0 && wall - state.last_call_wall_ms < cfg.incident_cooldown_ms {
                state.assessment_status = "cooldown";
            } else {
                state.incident_attempted = true;
                if !service_assess(model, cfg, state) { ok = false; ct_device_close(); break; }
            }
        }
        ct_device_close();
        if !service_publish(cfg, state, "monitoring", 0) { ok = false; break; }
        if sample_limit > 0 && state.samples >= sample_limit { break; }
        let waited = ct_service_wait(cfg.sample_interval_ms);
        if waited == -3 { break; }
        if waited != 0 { ok = false; break; }
    }
    if ok { ok = service_publish(cfg, state, "stopped", 1); }
    ct_service_close();
    return Outcome { status: if ok { Status.Completed } else { Status.Failed },
        message: if ok { "resident service stopped; inspect per-tool evidence for effects" } else { "service wait or private persistence failed" } };
}
