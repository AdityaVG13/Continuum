// Interactive shell for the optimization stack. No Python runtime, timers
// that call Meta, or secrets in Goose: native code owns terminal/vault bytes.
import .discovery;
import .meta_provider;
import .device;
import json;
import os;
namespace continuum;

extern fn ct_tui_open() -> i32;
extern fn ct_tui_close() -> i32;
extern fn ct_tui_key(timeout_ms: i64) -> i32;
extern fn ct_tui_key_load() -> i32;
extern fn ct_tui_key_setup() -> i32;
extern fn ct_tui_job_cancel() -> i32;
extern fn ct_setup_draw(frame: const u8[:], scroll: i64) -> i32;
extern fn ct_setup_input(label: const u8[:], initial: const u8[:], out: u8[:], length: i64&) -> i32;
extern fn ct_setup_secret(label: const u8[:], out: u8[:], length: i64&) -> i32;
extern fn ct_setup_vault_store(ref: const u8[:], value: const u8[:]) -> i32;
extern fn ct_setup_job_start(mode: const u8[:]) -> i32;
extern fn ct_setup_job_poll(out: u8[:], length: i64&) -> i32;

fn setup_defaults() -> ModelConfig {
    return ModelConfig {
        base_url: "https://api.meta.ai/v1", controller_model: "muse-spark-1.3",
        task_model: "muse-spark-1.3", request_timeout_ms: 60000,
        max_output_tokens: 16384, max_tool_rounds: 8, reasoning_effort: "xhigh",
    };
}

fn setup_directory() -> u8[>..] {
    var base: u8[>..] = [];
    // Explicit placement never falls back to another directory on invalid input.
    if env("CONTINUUM_HOME", base) {
        if base.len == 0 || base.len > 512 || base[0] != '/' { return str(""); }
        return str(base);
    }
    base = [];
    if env("XDG_CONFIG_HOME", base) && base.len > 0 && base[0] == '/' { return str(base, "/continuum"); }
    base = [];
    if env("HOME", base) && base.len > 0 && base[0] == '/' { return str(base, "/.config/continuum"); }
    return str("");
}

fn settings_valid(cfg: ModelConfig) -> bool {
    return build_meta_request(cfg, "settings", "settings").ok && cfg.request_timeout_ms <= 120000;
}

// Only non-secret settings have a disk format. Unknown fields fail closed so
// accidentally copied credentials can never be silently persisted by the UI.
fn load_setup_settings(cfg: ModelConfig&) -> bool {
    cfg = setup_defaults();
    let directory = setup_directory();
    if directory.len == 0 { return false; }
    let path = str(directory, "/settings.json");
    if !file_exists(path) { return true; }
    var text: u8[>..] = [];
    if !read_file(path, text) || text.len > 4096 { return false; }
    var doc: json::Node[>..] = [];
    var decoded: u8[>..] = [];
    let root, err = json::parse(text, doc, decoded);
    let known: const u8[:][..6] = ["controller_model", "task_model", "max_output_tokens", "max_tool_rounds", "request_timeout_ms", "reasoning_effort"];
    if !root || !no_unknown(root, known) { return false; }
    let controller, c = json::as_string(json::member(root, "controller_model"));
    let task, t = json::as_string(json::member(root, "task_model"));
    let tokens, o = json::as_i64(json::member(root, "max_output_tokens"));
    let rounds, r = json::as_i64(json::member(root, "max_tool_rounds"));
    let timeout, m = json::as_i64(json::member(root, "request_timeout_ms"));
    if !c || !t || !o || !r || !m || !valid_id(controller, 128) || !valid_id(task, 128) { return false; }
    var candidate = setup_defaults();
    candidate.controller_model = controller; candidate.task_model = task;
    candidate.max_output_tokens = tokens; candidate.max_tool_rounds = rounds; candidate.request_timeout_ms = timeout;
    // Files written before the effort was configurable ran at "low".
    let effort, ef = json::as_string(json::member(root, "reasoning_effort"));
    candidate.reasoning_effort = if !ef { "low" } else if valid_effort(effort) { effort } else { "" };
    if !settings_valid(candidate) { return false; }
    cfg = candidate;
    return true;
}

fn save_setup_settings(cfg: ModelConfig) -> bool {
    if !settings_valid(cfg) { return false; }
    let directory = setup_directory();
    if directory.len == 0 { return false; }
    // The config root can be absent on a first installation.
    var root: u8[>..] = [];
    if !(env("XDG_CONFIG_HOME", root) && root.len > 0 && root[0] == '/') {
        root = [];
        if !env("HOME", root) || root.len == 0 { return false; }
        root.append("/.config");
    }
    if !make_dir(root) || !make_dir(directory) { return false; }
    var text: u8[>..] = [];
    text.append("{\"controller_model\":"); json::format_string(text, cfg.controller_model);
    text.append(",\"task_model\":"); json::format_string(text, cfg.task_model);
    text.append(",\"max_output_tokens\":"); json::format_int(text, cfg.max_output_tokens);
    text.append(",\"max_tool_rounds\":"); json::format_int(text, cfg.max_tool_rounds);
    text.append(",\"request_timeout_ms\":"); json::format_int(text, cfg.request_timeout_ms);
    text.append(",\"reasoning_effort\":"); json::format_string(text, cfg.reasoning_effort);
    text.append("}\n");
    return write_file_atomic(str(directory, "/settings.json"), text);
}

// Meta Model API rate card, copied from the official pages on 2026-11-04:
//   https://dev.meta.ai/docs/pricing-rate-limits  (USD per 1M tokens)
//   https://dev.meta.ai/docs/models               (versions, modes, effort)
// Prices are in thousandths of a dollar per 1M tokens (1250 = $1.25). The
// key's own /models catalog decides what is offered; this table only adds
// price and description. An id missing here is shown without a price.
struct MetaModelCard {
    known: bool = false,
    input_milli: i64 = 0,
    cached_milli: i64 = 0,
    output_milli: i64 = 0,
    trains: bool = false,
    max_effort: bool = false,
    note: u8[..96] = "",
}
fn meta_model_card(id: const u8[:]) -> MetaModelCard {
    if id == "muse-wonder-1.0" {
        return MetaModelCard { known: true, input_milli: 4000, cached_milli: 200, output_milli: 20000, max_effort: true,
            note: "Most capable; long multi-step agent work. Slowest, priciest." };
    }
    if id == "muse-spark-1.3" {
        return MetaModelCard { known: true, input_milli: 1250, cached_milli: 150, output_milli: 4250, max_effort: true,
            note: "Latest Spark; tuned for tool loops. Recommended for this job." };
    }
    if id == "muse-spark-1.2" || id == "muse-spark-1.1" {
        return MetaModelCard { known: true, input_milli: 1250, cached_milli: 150, output_milli: 4250,
            note: if id == "muse-spark-1.2" { "Previous Spark version." } else { "Original Spark version." } };
    }
    if id == "muse-spark-1.3-contributor" || id == "muse-spark-1.2-contributor" {
        return MetaModelCard { known: true, input_milli: 100, cached_milli: 2, output_milli: 200, trains: true,
            note: "Contributor mode: Meta may train on your prompts and replies." };
    }
    return MetaModelCard {};
}
// Only the reasoning text lines take tool calls; image, voice and SAM ids
// from the catalog are never offered as the router agent.
fn meta_agent_model(id: const u8[:]) -> bool {
    return (id.len >= 10 && id[..10] == "muse-spark") || (id.len >= 11 && id[..11] == "muse-wonder");
}
fn setup_usd(micro: i64) -> u8[>..] {
    var out: u8[>..] = [];
    let cents_milli = (micro % 1000000) / 1000;
    out.append(str("$", micro / 1000000, "."));
    if cents_milli < 100 { out.append("0"); }
    if cents_milli < 10 { out.append("0"); }
    out.append(str(cents_milli));
    return out;
}
fn setup_rate(milli: i64) -> u8[>..] {
    var out: u8[>..] = [];
    out.append(str("$", milli / 1000, "."));
    let frac = milli % 1000;
    if frac < 100 { out.append("0"); }
    if frac < 10 { out.append("0"); }
    out.append(str(frac));
    return out;
}
// Reasoning tokens are billed as output and count against the cap, so a
// deeper effort gets a larger cap (dev.meta.ai/docs/reasoning).
fn effort_output_cap(effort: const u8[:]) -> i64 {
    if effort == "minimal" { return 2048; }
    if effort == "low" { return 4096; }
    if effort == "medium" { return 8192; }
    if effort == "max" { return 32768; }
    return 16384;
}
// Upper bound for one Meta step, from the caps this checkout enforces: each
// call sends at most MAX_META_BODY_BYTES (about 32k tokens at ~4 bytes per
// token) and returns at most the output cap. A bound, not a measurement.
fn setup_run_ceiling(card: MetaModelCard, rounds: i64, output_cap: i64) -> i64 {
    return rounds * (32768 * card.input_milli + output_cap * card.output_milli) / 1000;
}
fn setup_pick_model(cfg: ModelConfig&, listed: const u8[:]) -> bool {
    var ids: u8[..128][>..] = []; var other: u8[>..] = [];
    var start: i64 = 0; var i: i64 = 0;
    while i < listed.len {
        if listed[i] == 10 {
            let id = listed[start..i];
            if meta_agent_model(id) && ids.len < 9 { var held: u8[..128] = id; ids.push(held); }
            else if id.len > 0 { if other.len > 0 { other.append(", "); } other.append(id); }
            start = i + 1;
        }
        i += 1;
    }
    if ids.len == 0 { return false; }
    // The setup step needs room to inspect, apply, read back and summarize; a
    // 4-call budget ran out live before any apply. Picking a model is where
    // the owner sees the cost, so the step bound is raised to the cap here
    // and the prices below are computed with it.
    if cfg.max_tool_rounds < 8 { cfg.max_tool_rounds = 8; }
    var chosen: i64 = 0;
    var k: i64 = 0;
    while k < ids.len { if ids[k] == cfg.controller_model { chosen = k; } k += 1; }
    if ids[chosen] != cfg.controller_model {
        k = 0; while k < ids.len { if ids[k] == "muse-spark-1.3" { chosen = k; } k += 1; }
    }
    while true {
        var frame: u8[>..] = [];
        frame.append("CONTINUUM / CHOOSE THE META MODEL\n--------------------------------------------------------------------------\n");
        frame.append("Models this key can use (read from the provider; listing is free).\nPrices: official rate card, USD per 1M tokens, checked 2026-11-04.\n\n");
        var n: i64 = 0;
        while n < ids.len {
            let card = meta_model_card(ids[n]);
            frame.append(str(if n == chosen { "> " } else { "  " }, n + 1, "  ", ids[n], "\n"));
            if card.known {
                frame.append(str("     in ", setup_rate(card.input_milli), "  cached ", setup_rate(card.cached_milli), "  out ", setup_rate(card.output_milli),
                    "   one setup step <= ", setup_usd(setup_run_ceiling(card, cfg.max_tool_rounds, effort_output_cap(cfg.reasoning_effort))), "\n     ", card.note, "\n"));
            } else { frame.append("     Not in Continuum's price table; see dev.meta.ai/docs/pricing-rate-limits\n"); }
            n += 1;
        }
        if other.len > 0 { frame.append("\nNot offered (not tool-calling text models): "); frame.append(other); frame.append("\n"); }
        frame.append(str("\nThe step bound is ", cfg.max_tool_rounds, " calls x (<= 32k input + output cap) at the chosen effort.\nMuse Spark Open is open-weight and is not served on this API.\n"));
        frame.append("\n[1-9] Select    [Enter] Use the marked model\n[Esc] Cancel; nothing is saved\n");
        ct_setup_draw(frame, 0);
        let key = ct_tui_key(-1);
        if key == 27 || key == 3 || key < 0 { return false; }
        if key >= '1' && key < '1' + ids.len { chosen = key - '1'; }
        if key == 13 || key == 10 { break; }
    }
    let card = meta_model_card(ids[chosen]);
    let levels: const u8[:][..6] = ["minimal", "low", "medium", "high", "xhigh", "max"];
    let count: i64 = if card.max_effort { 6 } else { 5 };
    var effort: i64 = 4;
    k = 0; while k < count { if levels[k] == cfg.reasoning_effort { effort = k; } k += 1; }
    if effort >= count { effort = count - 1; }
    while true {
        var frame: u8[>..] = [];
        frame.append("CONTINUUM / REASONING EFFORT\n--------------------------------------------------------------------------\n");
        frame.append(str("Model  ", ids[chosen], "\n\nMore effort = more reasoning tokens: slower and billed as output.\nThe output cap grows with it so reasoning cannot crowd out the answer.\n\n"));
        k = 0;
        while k < count {
            let cap = effort_output_cap(levels[k]);
            frame.append(str(if k == effort { "> " } else { "  " }, k + 1, "  ", levels[k], "   cap ", cap, " tokens/response"));
            if card.known { frame.append(str("   step <= ", setup_usd(setup_run_ceiling(card, cfg.max_tool_rounds, cap)))); }
            frame.append("\n");
            k += 1;
        }
        frame.append("\nMeta's cookbook notes xhigh currently reasons like high on Spark 1.3.\n");
        frame.append("\n[1-6] Select    [Enter] Save model and effort\n[Esc] Cancel; nothing is saved\n");
        ct_setup_draw(frame, 0);
        let key = ct_tui_key(-1);
        if key == 27 || key == 3 || key < 0 { return false; }
        if key >= '1' && key < '1' + count { effort = key - '1'; }
        if key == 13 || key == 10 { break; }
    }
    var candidate = cfg;
    candidate.controller_model = ids[chosen]; candidate.task_model = ids[chosen];
    candidate.reasoning_effort = levels[effort]; candidate.max_output_tokens = effort_output_cap(levels[effort]);
    if !save_setup_settings(candidate) { return false; }
    cfg = candidate;
    return true;
}
fn setup_field(label: const u8[:], initial: const u8[:], value: u8[>..]&) -> bool {
    var buffer: u8[..128] = [0; 128]; var n: i64 = 0;
    if ct_setup_input(label, initial, buffer, n) != 0 || n <= 0 || n > 128 { return false; }
    value.append(buffer[..n]);
    return true;
}
fn setup_number(label: const u8[:], initial: i64, number: i64&) -> bool {
    var value: u8[>..] = [];
    if !setup_field(label, str(initial), value) || value.len > 7 { return false; }
    var n: i64 = 0;
    for b in value { if b < '0' || b > '9' { return false; } n = n * 10 + (b - '0'); }
    number = n; return true;
}
fn setup_owner_list(label: const u8[:], initial: const u8[:], out: u8[>..]&) -> bool {
    var value: u8[>..] = [];
    if !setup_field(label, if initial.len == 0 { "-" } else { initial }, value) { return false; }
    out.append("[");
    if value != "-" {
        var start: i64 = 0; var index: i64 = 0; var count: i64 = 0;
        while index <= value.len {
            if index == value.len || value[index] == ',' {
                var end = index;
                while start < end && value[start] == ' ' { start += 1; }
                while end > start && value[end - 1] == ' ' { end -= 1; }
                if start == end { return false; }
                if count > 0 { out.append(","); } json::format_string(out, value[start..end]);
                count += 1; start = index + 1;
            }
            index += 1;
        }
    }
    out.append("]"); return true;
}
fn edit_owner_settings() -> bool {
    let directory = setup_directory(); var policy = OwnerPolicy {};
    if !device_open(directory, 0) { return false; }
    let loaded = owner_load(policy); ct_device_close();
    if !loaded { return false; }
    let original = owner_record(policy);
    var host: u8[>..] = []; var operations: u8[>..] = []; var clients: u8[>..] = []; var services: u8[>..] = [];
    var operation_names: u8[>..] = []; var client_names: u8[>..] = []; var service_names: u8[>..] = [];
    for op, index in policy.allowed_operations { if index > 0 { operation_names.append(","); } operation_names.append(op); }
    for client, index in policy.protected_clients { if index > 0 { client_names.append(","); } client_names.append(client); }
    for service, index in policy.protected_services { if index > 0 { service_names.append(","); } service_names.append(service); }
    var permit: i64 = if policy.allow_host_programs { 1 } else { 0 };
    if !setup_field("Execution host (local/disabled)", policy.execution_host, host) ||
        !setup_number("Allow isolated local programs (0=no, 1=yes)", permit, permit) || permit > 1 ||
        !setup_owner_list("Allowed device operations (enroll,runtime,apply,restore,verify,reboot; -=none)", operation_names, operations) ||
        !setup_owner_list("Protected users/devices (comma-separated; -=none)", client_names, clients) ||
        !setup_owner_list("Capabilities to preserve (ids from the device capability graph, comma separated; -=none)", service_names, services) ||
        !setup_number("Program slots (1..8)", policy.max_programs, policy.max_programs) ||
        !setup_number("Resolved program retention (days, 0=keep, 1..365)", policy.program_retention_days, policy.program_retention_days) ||
        !setup_number("Program wall time (milliseconds, 100..10000)", policy.program_timeout_ms, policy.program_timeout_ms) { return false; }
    var text: u8[>..] = []; text.append("{\"schema_version\":1,\"allowed_operations\":"); text.append(operations);
    text.append(",\"execution_host\":"); json::format_string(text, host);
    text.append(",\"allow_host_programs\":"); json::format_bool(text, permit == 1);
    text.append(",\"protected_clients\":"); text.append(clients); text.append(",\"protected_services\":"); text.append(services);
    text.append(str(",\"max_programs\":", policy.max_programs, ",\"program_retention_days\":", policy.program_retention_days,
        ",\"program_timeout_ms\":", policy.program_timeout_ms, "}"));
    if !owner_parse(text, policy) { return false; }
    var frame: u8[>..] = [];
    frame.append("CONTINUUM / OWNER PERMISSIONS\n--------------------------------------------------------------------------\nSave these owner permissions?\n\n");
    frame.append(owner_record(policy));
    frame.append("\n\nNamed users/devices block changes until connectivity can be verified.\nLocal code has no direct network, credentials or persistent file access.\nRetention compacts resolved records only; active/uncertain work is retained.\nThese permissions do not add unsupported device capabilities.\n\n[Enter] Save\n[Esc] Cancel without changing permissions");
    ct_setup_draw(frame, 0);
    while true {
        let key = ct_tui_key(-1);
        if key == 27 || key == 3 || key < 0 { return false; }
        if key == 13 || key == 10 { break; }
    }
    // Do not hold a device lock while the owner edits, or overwrite a concurrent grant.
    if !device_open(directory, 1) { return false; }
    var current = OwnerPolicy {};
    let saved = owner_load(current) && owner_record(current) == original && owner_save(policy);
    ct_device_close(); return saved;
}
fn edit_setup_settings(cfg: ModelConfig&) -> bool {
    var candidate = cfg;
    var controller: u8[>..] = []; var task: u8[>..] = [];
    if !setup_field("Controller / discovery model", cfg.controller_model, controller) ||
        !setup_field("Workload model", cfg.task_model, task) { return false; }
    candidate.controller_model = controller; candidate.task_model = task;
    if !setup_number("Output token cap per response (1..128000)", cfg.max_output_tokens, candidate.max_output_tokens) ||
        !setup_number("Maximum controller / discovery calls (1..8)", cfg.max_tool_rounds, candidate.max_tool_rounds) ||
        !setup_number("Request timeout in milliseconds (1000..120000)", cfg.request_timeout_ms, candidate.request_timeout_ms) { return false; }
    if !save_setup_settings(candidate) { return false; }
    cfg = candidate;
    return true;
}

struct ServiceConfig {
    sample_interval_ms: i64 = 15000,
    incident_cooldown_ms: i64 = 300000,
    max_calls_per_hour: i64 = 4,
    allow_meta: bool = false,
}
fn service_config_valid(cfg: ServiceConfig) -> bool {
    return cfg.sample_interval_ms >= 1000 && cfg.sample_interval_ms <= 3600000 &&
        cfg.incident_cooldown_ms >= 60000 && cfg.incident_cooldown_ms <= 3600000 &&
        cfg.max_calls_per_hour >= 1 && cfg.max_calls_per_hour <= 8;
}
fn load_service_config(directory: const u8[:], cfg: ServiceConfig&) -> bool {
    let path = str(directory, "/service.json");
    if !file_exists(path) { return true; }
    var text: u8[>..] = [];
    if !read_file(path, text) || text.len > 4096 { return false; }
    var doc: json::Node[>..] = []; var decoded: u8[>..] = [];
    let root, err = json::parse(text, doc, decoded);
    let known: const u8[:][..4] = ["sample_interval_ms", "incident_cooldown_ms", "max_calls_per_hour", "allow_meta"];
    if !root || !no_unknown(root, known) { return false; }
    let interval, i = json::as_i64(json::member(root, "sample_interval_ms"));
    let cooldown, c = json::as_i64(json::member(root, "incident_cooldown_ms"));
    let calls, b = json::as_i64(json::member(root, "max_calls_per_hour"));
    let permit, p = json::as_bool(json::member(root, "allow_meta"));
    if !i || !c || !b || !p { return false; }
    let candidate = ServiceConfig { sample_interval_ms: interval, incident_cooldown_ms: cooldown,
        max_calls_per_hour: calls, allow_meta: permit };
    if !service_config_valid(candidate) { return false; }
    cfg = candidate; return true;
}
fn save_service_config(cfg: ServiceConfig) -> bool {
    if !service_config_valid(cfg) { return false; }
    let directory = setup_directory();
    var root: u8[>..] = [];
    if !(env("XDG_CONFIG_HOME", root) && root.len > 0 && root[0] == '/') {
        root = []; if !env("HOME", root) || root.len == 0 { return false; }
        root.append("/.config");
    }
    if directory.len == 0 || !make_dir(root) || !make_dir(directory) { return false; }
    var text: u8[>..] = [];
    text.append("{\"sample_interval_ms\":"); json::format_int(text, cfg.sample_interval_ms);
    text.append(",\"incident_cooldown_ms\":"); json::format_int(text, cfg.incident_cooldown_ms);
    text.append(",\"max_calls_per_hour\":"); json::format_int(text, cfg.max_calls_per_hour);
    text.append(",\"allow_meta\":"); text.append(if cfg.allow_meta { "true" } else { "false" }); text.append("}\n");
    return write_file_atomic(str(directory, "/service.json"), text);
}

extern fn ct_setup_service_start(directory: const u8[:]) -> i64;
fn setup_background_monitor() -> i64 {
    var cfg = ServiceConfig {};
    if !load_service_config(setup_directory(), cfg) { return -1; }
    var permit: i64 = if cfg.allow_meta { 1 } else { 0 };
    if !setup_number("Monitor interval in ms (1000..3600000)", cfg.sample_interval_ms, cfg.sample_interval_ms) ||
        !setup_number("Incident cooldown in ms (60000..3600000)", cfg.incident_cooldown_ms, cfg.incident_cooldown_ms) ||
        !setup_number("Meta calls per hour (1..8)", cfg.max_calls_per_hour, cfg.max_calls_per_hour) ||
        !setup_number("Automatic Meta assessments (0=no, 1=yes)", permit, permit) || permit < 0 || permit > 1 { return -1; }
    cfg.allow_meta = permit == 1;
    if !service_config_valid(cfg) { return -1; }
    var frame: u8[>..] = [];
    frame.append("CONTINUUM / BACKGROUND SERVICE\n--------------------------------------------------------------------------\nStart background monitor?\nHost sampling is read-only. Opt-in Meta incidents share the selected device's\nexisting standing permission for supported reversible operations.\nStarting this monitor grants NO device-write or router-reboot permission.\n\n");
    frame.append(str("Sample interval  ", cfg.sample_interval_ms, " ms\nMeta permission  ", cfg.allow_meta,
        "\nCall ceiling     ", cfg.max_calls_per_hour, "/hour, ", cfg.incident_cooldown_ms, " ms cooldown\n\n"));
    frame.append("Meta uses the configured per-response token/timeout limits.\nNo Meta calls when healthy. Closing this UI leaves the monitor running.\nReboot autostart is not installed. Existing monitors are not reconfigured.\n\n[Enter] Save permission and start\n[Esc] Cancel without starting a service");
    ct_setup_draw(frame, 0);
    while true {
        let key = ct_tui_key(-1);
        if key == 27 || key == 3 || key < 0 { return -1; }
        if key == 13 || key == 10 { break; }
    }
    if !save_service_config(cfg) { return -1; }
    return ct_setup_service_start(setup_directory());
}

fn setup_network_view(text: const u8[:], out: u8[>..]&) {
    var doc: json::Node[>..] = []; var decoded: u8[>..] = [];
    let root, err = json::parse(text, doc, decoded);
    out.append("NETWORK / LIVE HOST EVIDENCE\n\n");
    if !root { out.append("No host observation yet. Press d to collect.\n"); return; }
    out.append("INTERFACE     KIND        IPV4 ADDRESS\n");
    let interfaces = json::member(root, "interfaces");
    if interfaces {
        var c = interfaces.first;
        while c {
            let name, n = json::as_string(json::member(c, "name"));
            let kind, k = json::as_string(json::member(c, "kind"));
            let address, a = json::as_string(json::member(c, "address"));
            out.append(str(name, "     ", kind, "     ", address, "\n"));
            c .= c.next;
        }
    }
    out.append("\nOBSERVED MANAGEMENT CANDIDATES / IDENTITY UNVERIFIED\n");
    let candidates = json::member(root, "candidates");
    if !candidates || !candidates.first { out.append("None observed. Join/connect the router's network, then refresh.\n"); }
    if candidates {
        var c = candidates.first; var index: i64 = 1;
        while c {
            let id, i = json::as_string(json::member(c, "candidate_id"));
            let source, s = json::as_string(json::member(c, "source"));
            out.append(str("  ", index, "  ", id, "  /  ", source, "\n"));
            index += 1; c .= c.next;
        }
    }
    out.append("\nGateway != intended router. No scan or network change.\n");
    out.append("Press a for Meta to investigate; costs bounded provider calls.\n");
}

fn confirm_setup_job(cfg: ModelConfig, job: const u8[:]) -> bool {
    var frame: u8[>..] = [];
    frame.append("CONTINUUM / META REQUEST\n--------------------------------------------------------------------------\nConfirm Meta job\nNo provider usage until you press Enter.\n\n");
    frame.append(str("Model     ", cfg.controller_model, "   effort ", cfg.reasoning_effort, "\n"));
    if job == "test-key" { frame.append("Budget    One connection-test call at minimal effort, up to 1024 output\n          tokens.\n"); }
    else {
        frame.append(str("Budget    Up to ", cfg.max_tool_rounds, " controller calls; ", cfg.max_output_tokens, " output tokens/response.\n"));
        if job == "lab" { frame.append("          Plus one workload call. Simulator only; no physical writes.\n"); }
        else { frame.append("Scope     Observe host paths; GET public pages of observed candidates.\n          No credentials sent to devices; no network changes.\n"); }
    }
    frame.append("\n[Enter] Run requested job\n[Esc] Cancel without a provider call");
    while true {
        ct_setup_draw(frame, 0);
        let key = ct_tui_key(-1);
        if key == 13 || key == 10 { return true; }
        if key == 27 || key == 3 || key < 0 { return false; }
    }
    return false;
}

fn setup_select_device() -> bool {
    let network = discover_host();
    var frame: u8[>..] = [];
    frame.append("CONTINUUM / SELECT DEVICE\n--------------------------------------------------------------------------\nChoose the device you own. No enrollment or device write occurs here.\n\n");
    setup_network_view(network, frame);
    frame.append("\n[Enter] Choose from these observed candidates\n[Esc] Cancel without binding a target");
    ct_setup_draw(frame, 0);
    while true {
        let key = ct_tui_key(-1);
        if key == 27 || key == 3 || key < 0 { return false; }
        if key == 13 || key == 10 { break; }
    }
    var doc: json::Node[>..] = []; var decoded: u8[>..] = [];
    let root, err = json::parse(network, doc, decoded);
    let candidates = json::member(root, "candidates");
    if !candidates || !candidates.first { return false; }
    var number: i64 = 1;
    if !setup_number("Choose device number (listed above)", 1, number) || number < 1 { return false; }
    var c = candidates.first; var index: i64 = 1; var candidate: u8[..64] = "";
    while c {
        let id, i = json::as_string(json::member(c, "candidate_id"));
        if index == number && i && id.len <= 64 { candidate = id; }
        index += 1; c .= c.next;
    }
    var stem: u8[>..] = []; var reuse: i64 = 0;
    if candidate.len == 0 || !setup_field("Wi-Fi name stem (used only for new enrollment)", "Continuum", stem) ||
            !setup_number("Use existing saved router credentials (0=new, 1=reuse)", 0, reuse) || reuse < 0 || reuse > 1 { return false; }
    return device_select(setup_directory(), network, candidate, stem, 80, reuse == 1);
}
fn setup_device_view(out: u8[>..]&) {
    var d = DeviceState {};
    out.append("DEVICE / LIFECYCLE\n\n");
    if !device_saved(setup_directory(), d) { out.append("Device binding busy or invalid; not replaced.\n"); return; }
    if d.candidate_id.len == 0 { out.append("Phase        unselected\nNo selected device. [p] to choose an observed candidate.\n"); return; }
    out.append(str("Selected     ", d.candidate_id, ":", d.connection.port, "\nIdentity     ",
        d.productid, " / ", d.mac, " / ", d.firmware, "\n"));
    out.append(str("Phase        ", d.phase, "\nSETUP        ", if d.setup_approved { "[OK] initial setup approved" } else { "[ ] not granted" },
        "\nRUNTIME      ", if d.runtime_verified { "[OK] verified" } else { "[ ] not verified" },
        "\nRECOVERY     ", if d.recovery_verified { "[OK] verified" } else { "[ ] not verified" },
        "\nPERSIST      ", if d.persistence_verified { "[OK] verified" } else { "[ ] not verified" },
        "\nLOAD         ", if d.network_load_verified { "[OK] measured" } else { "[ ] no claimable measurement" },
        "\nREADY        ", if d.setup_approved && d.runtime_verified && d.recovery_verified &&
            d.persistence_verified && d.network_load_verified { "true" } else { "false" },
        "\nReason       ", d.reason, "\n\n"));
    out.append("[i] Protected inspection  [u] Authorize credential access\n[Enter] Next step: bind / enroll / re-enroll after a reset / Meta setup\n[n] Enroll: create the admin credential on a factory unit\n[e] Meta setup / resume  [r] Restore owned baseline\n[t] Talk to Meta  [b] Approve one router reboot\n\nService restarts are allowed within standing device permission.\nRouter reboot, reset and firmware changes are never implied.\nREADY needs every gate plus a claimable --measure run recorded after the last lifecycle change; --device-qualify <evidence> --execute opens it. General controller crash recovery remains unqualified.\n");
}
fn confirm_device_job(job: const u8[:]) -> bool {
    var frame: u8[>..] = [];
    frame.append("CONTINUUM / DEVICE PERMISSION\n--------------------------------------------------------------------------\n");
    var d = DeviceState {};
    if !device_saved(setup_directory(), d) || d.candidate_id.len == 0 { return false; }
    frame.append(str("Selected  ", d.candidate_id, ":", d.connection.port, "\nPhase     ", d.phase,
        "\nIdentity  ", d.productid, " / ", d.mac, "\n"));
    if job == "device-enroll" {
        frame.append("\nRun the factory enrollment for this unit now?\nOn a factory unit there is no admin password to enter: Continuum generates\none, stores it in the OS credential vault, submits the first-run form, and\nproves it by a fresh protected login. On a unit that is already configured\nthat login is refused and nothing on the router changes; the failure screen\noffers a takeover with the password the unit already uses.\nIt also renames Wi-Fi to the chosen stem and rotates the Wi-Fi passphrase.\nThis host may lose its link if it is associated to that radio.\nNO reboot, reset, firmware update or destructive action is approved.\n");
    } else if job == "device-setup" {
        frame.append("\nGrant Meta standing permission for this selected device?\nMeta chooses setup and supported reversible optimization operations.\nNew factory enrollment may rotate credentials, rename Wi-Fi and disconnect\nthis host. Service restarts and verified optional-service changes are allowed.\nThis uses the configured model/call budget. Uncertain effects are reconciled.\nNO router/device reboot, reset, firmware update or destructive action is approved.\nCore routing/security settings are outside the current cleanup capability.\n");
    } else if job == "device-reboot" {
        frame.append("\nApprove ONE router/device reboot NOW for this selected device?\nThis interrupts the network and ongoing work. No schedule is created.\nStanding setup permission and Meta messages cannot approve this operation.\nA failed/uncertain request is verified, never automatically repeated.\n");
    } else if job == "device-restore" {
        frame.append("\nRestore only the selected device's owned sharing-service baseline?\nA different device, changed firmware or intervening owner setting is refused.\n");
    } else if job == "device-verify" {
        frame.append("\nVerify that the baseline survived the reboot?\nContinuum reads the router again and requires a new boot identity and\nevery owned setting still in force. No model call; no owned setting is\nwritten. A pass records the PERSIST gate; a failure names what did not\nsurvive.\n");
    } else if job == "device-qos-status" {
        frame.append("\nRead the WAN queue (read-only preflight)?\nChecks that the router has tc and reads its current root qdisc.\nNothing is written to the router. No model call.\n");
    } else if job == "qos-restore" {
        frame.append("\nRemove the shaping and restore the kernel default queue?\nDeletes only the root qdisc Continuum applied, then reads the default\nback. The LOAD gate re-opens: READY ends until you tune and measure\nagain. No model call.\n");
    } else {
        frame.append("\nAuthorize this signed application to read the selected credential?\nThe OS may request your authorization. No credential is displayed.\n");
    }
    frame.append("\n[Enter] Approve this operation\n[Esc] Cancel without dispatch");
    ct_setup_draw(frame, 0);
    while true {
        let key = ct_tui_key(-1);
        if key == 13 || key == 10 { return true; }
        if key == 27 || key == 3 || key < 0 { return false; }
    }
    return false;
}

// Observed router candidates, default routes first: the wizard binds by
// number instead of sending the owner to the panels. ids holds at most 9.
fn setup_candidates(network: const u8[:], ids: u8[..64][>..]&, kinds: u8[>..]&) {
    var doc: json::Node[>..] = []; var decoded: u8[>..] = [];
    let root, err = json::parse(network, doc, decoded);
    if !root { return; }
    let candidates = json::member(root, "candidates");
    let interfaces = json::member(root, "interfaces");
    var pass: i64 = 0;
    while pass < 2 {
        var c = if candidates { candidates.first } else { candidates };
        while c && ids.len < 9 {
            let source, s = json::as_string(json::member(c, "source"));
            let id, i = json::as_string(json::member(c, "candidate_id"));
            let iface, f = json::as_string(json::member(c, "interface"));
            let first = s && source == "default_route";
            if i && id.len <= 64 && ((pass == 0) == first) {
                var held: u8[..64] = id; ids.push(held);
                var kind: u8[>..] = []; kind.append("link");
                if interfaces && f {
                    var link = interfaces.first;
                    while link {
                        let name, n = json::as_string(json::member(link, "name"));
                        let k, kk = json::as_string(json::member(link, "kind"));
                        if n && kk && name == iface { kind = []; kind.append(if k == "wifi" { "Wi-Fi" } else { k }); }
                        link .= link.next;
                    }
                }
                kinds.append(kind); kinds.append(if first { ", default route" } else { ", on-link neighbor" }); kinds.append("\n");
            }
            c .= c.next;
        }
        pass += 1;
    }
}
fn setup_nth_line(text: const u8[:], index: i64) -> u8[>..] {
    var out: u8[>..] = []; var line: i64 = 0; var i: i64 = 0;
    while i < text.len {
        if text[i] == 10 { line += 1; }
        else if line == index { out.push(text[i]); }
        i += 1;
    }
    return out;
}
// What answers on each candidate's web port, read once per look (a GET of
// '/', no credentials). Advisory: it names the vendor so the owner knows
// whether Continuum has a backend for it; enrollment is the identity proof.
fn setup_identify(network: const u8[:]) -> u8[>..] {
    var ids: u8[..64][>..] = []; var kinds: u8[>..] = [];
    setup_candidates(network, ids, kinds);
    var out: u8[>..] = []; var n: i64 = 0;
    while n < ids.len {
        var label: u8[>..] = [];
        // Only gateways can be the router; probing every LAN neighbor cost a
        // 1 s connect timeout per silent host before the first frame.
        let kind = setup_nth_line(kinds, n);
        let gateway = kind.len >= 13 && kind[kind.len - 13..kind.len] == "default route";
        if n >= 4 || !gateway { label.append("not probed"); }
        else {
            var buffer: u8[..4096] = [0; 4096]; var len: i64 = 0;
            if ct_setup_probe(ids[n], 80, buffer, len) != 0 || len <= 0 || len > buffer.len { label.append("no web answer on port 80"); }
            else {
                var doc: json::Node[>..] = []; var decoded: u8[>..] = [];
                let root, err = json::parse(buffer[..len], doc, decoded);
                let vendor, v = json::as_string(json::member(root, "vendor"));
                let title, t = json::as_string(json::member(root, "title"));
                if !v || vendor.len == 0 { label.append("no web answer on port 80"); }
                else if vendor == "asus" { label.append("ASUS router -- supported"); }
                else if vendor == "unknown" {
                    label.append("web page");
                    if t && title.len > 0 { label.append(" \""); for b in title { if b >= 32 && b < 127 && label.len < 60 { label.push(b); } } label.append("\""); }
                    label.append(" -- vendor not recognised");
                } else { label.append(str(vendor, " router -- no Continuum backend yet")); }
            }
        }
        out.append(label); out.append("\n");
        n += 1;
    }
    return out;
}
// Enter on the Device panel walks the lifecycle. A default-route candidate is
// only evidence of a gateway, not of the intended router, so this helper
// returns it only when it is unambiguous; several candidates stay an explicit
// choice (p) instead of a guess.
fn setup_gateway_candidate(network: const u8[:]) -> u8[>..] {
    var doc: json::Node[>..] = []; var decoded: u8[>..] = [];
    let root, err = json::parse(network, doc, decoded);
    var found: u8[>..] = []; var count: i64 = 0;
    if root {
        let candidates = json::member(root, "candidates");
        if candidates {
            var c = candidates.first;
            while c {
                let source, s = json::as_string(json::member(c, "source"));
                let id, i = json::as_string(json::member(c, "candidate_id"));
                if s && i && source == "default_route" { count += 1; found.append(id); }
                c .= c.next;
            }
        }
    }
    if count == 1 { return found; }
    var none: u8[>..] = [];
    return none;
}
// The router Enter binds: the one supported router in reach. A Mac that is on
// its ISP gateway by cable and has also joined a factory router's setup Wi-Fi
// sees two routers; only the one Continuum can drive is marked, so Enter never
// binds a gateway it has no backend for. Two supported routers are ambiguous
// and the owner picks by number.
fn setup_marked(network: const u8[:], labels: const u8[:]) -> u8[>..] {
    var ids: u8[..64][>..] = []; var kinds: u8[>..] = [];
    setup_candidates(network, ids, kinds);
    var found: u8[>..] = []; var supported: i64 = 0; var n: i64 = 0;
    while n < ids.len {
        let label = setup_nth_line(labels, n);
        if label.len >= 12 && label[label.len - 12..label.len] == "-- supported" {
            supported += 1;
            if supported == 1 { found.append(ids[n]); }
        }
        n += 1;
    }
    if supported != 1 { found = []; }
    return found;
}
fn confirm_bind(candidate: const u8[:], label: const u8[:]) -> bool {
    var frame: u8[>..] = [];
    frame.append("CONTINUUM / BIND THIS ROUTER\n--------------------------------------------------------------------------\n");
    frame.append(str("Candidate  ", candidate, "\nAnswers    ", if label.len > 0 { label } else { "not probed" }, "\n\n"));
    frame.append("Record it as this installation's router?\nNo credential is created and nothing is written to the router.\n\n[Enter] Bind\n[Esc] Cancel\n");
    ct_setup_draw(frame, 0);
    while true {
        let key = ct_tui_key(-1);
        if key == 13 || key == 10 { return true; }
        if key == 27 || key == 3 || key < 0 { return false; }
    }
    return false;
}
// A saved binding that no longer answers is indistinguishable from a working
// one without a protected read, so the operator -- who knows the unit was
// reset -- chooses the recovery explicitly.
fn setup_next_menu(d: DeviceState) -> i64 {
    var frame: u8[>..] = [];
    frame.append("CONTINUUM / NEXT STEP\n--------------------------------------------------------------------------\n");
    frame.append(str("Binding   ", d.candidate_id, ":", d.connection.port, "   phase ", d.phase, "\n\n"));
    frame.append("A factory reset erases the admin credential this binding refers to.\n");
    frame.append("Re-enrolling discards the stale record and runs the ceremony on the\nsame candidate; Meta setup runs on the existing binding as-is.\n\n");
    // The renderer pins the last three lines as the footer, so the actions are
    // exactly the final three lines of this frame.
    frame.append("[1] Re-enroll this router (factory reset recovery)\n[2] Meta setup on the existing binding\n[Esc] Cancel\n");
    ct_setup_draw(frame, 0);
    while true {
        let choice = ct_tui_key(-1);
        if choice == '1' || choice == '2' { return choice; }
        if choice == 27 || choice == 3 || choice < 0 { return 0; }
    }
    return 0;
}
// Byte search for the one refusal that means "this step is already done":
// a unit that is already configured has gone past the factory ceremony.
fn setup_contains(hay: const u8[:], needle: const u8[:]) -> bool {
    if needle.len == 0 || hay.len < needle.len { return false; }
    var i: i64 = 0;
    while i + needle.len <= hay.len {
        var j: i64 = 0;
        while j < needle.len && hay[i + j] == needle[j] { j += 1; }
        if j == needle.len { return true; }
        i += 1;
    }
    return false;
}

// Owner inputs for TUNE and MEASURE. Non-secret, asked once and kept beside
// settings.json; unknown fields fail closed like every other settings file.
struct WizardNetwork {
    target: u8[..128] = "",
    load_path: u8[..128] = "",
    upload_kbps: i64 = 0,
    interface_id: u8[..8] = "eth0",
}
fn wizard_network_valid(net: WizardNetwork) -> bool {
    if net.interface_id != "eth0" && net.interface_id != "ppp0" { return false; }
    // The adapter's own profile bounds; 0 means "not chosen yet".
    if net.upload_kbps != 0 && (net.upload_kbps < 256 || net.upload_kbps > 100000) { return false; }
    if net.load_path.len > 0 && net.load_path[0] != '/' { return false; }
    for b in net.target { if b <= 32 || b >= 127 { return false; } }
    for b in net.load_path { if b <= 32 || b >= 127 { return false; } }
    return true;
}
fn load_wizard_network(net: WizardNetwork&) -> bool {
    net = WizardNetwork {};
    let path = str(setup_directory(), "/network.json");
    if !file_exists(path) { return true; }
    var text: u8[>..] = [];
    if !read_file(path, text) || text.len > 4096 { return false; }
    var doc: json::Node[>..] = []; var decoded: u8[>..] = [];
    let root, err = json::parse(text, doc, decoded);
    let known: const u8[:][..4] = ["target", "load_path", "upload_kbps", "interface"];
    if !root || !no_unknown(root, known) { return false; }
    let target, t = json::as_string(json::member(root, "target"));
    let load, l = json::as_string(json::member(root, "load_path"));
    let kbps, k = json::as_i64(json::member(root, "upload_kbps"));
    let iface, i = json::as_string(json::member(root, "interface"));
    if !t || !l || !k || !i || target.len > 128 || load.len > 128 || iface.len > 8 { return false; }
    var candidate = WizardNetwork {};
    candidate.target = target; candidate.load_path = load; candidate.upload_kbps = kbps; candidate.interface_id = iface;
    if !wizard_network_valid(candidate) { return false; }
    net = candidate; return true;
}
fn save_wizard_network(net: WizardNetwork) -> bool {
    let directory = setup_directory();
    if !wizard_network_valid(net) || directory.len == 0 || !make_dir(directory) { return false; }
    var text: u8[>..] = [];
    text.append("{\"target\":"); json::format_string(text, net.target);
    text.append(",\"load_path\":"); json::format_string(text, net.load_path);
    text.append(",\"upload_kbps\":"); json::format_int(text, net.upload_kbps);
    text.append(",\"interface\":"); json::format_string(text, net.interface_id);
    text.append("}\n");
    return write_file_atomic(str(directory, "/network.json"), text);
}
fn setup_tune_inputs(net: WizardNetwork&) -> bool {
    var candidate = net; var kbps: i64 = net.upload_kbps; var iface: u8[>..] = [];
    if !setup_number("Upload bandwidth to shape to, kbit/s (256..100000; a little under your line's upload)", kbps, kbps) ||
        !setup_field("WAN interface (eth0, or ppp0 for PPPoE)", net.interface_id, iface) || iface.len > 8 || kbps < 256 { return false; }
    candidate.upload_kbps = kbps; candidate.interface_id = iface;
    if !save_wizard_network(candidate) { return false; }
    net = candidate; return true;
}
fn setup_measure_inputs(net: WizardNetwork&) -> bool {
    var candidate = net; var target: u8[>..] = []; var load: u8[>..] = [];
    var initial: u8[..128] = "/bulk";
    if net.load_path.len > 0 { initial = net.load_path; }
    if !setup_field("Measurement target host:port/path (a server reached across the WAN)", net.target, target) ||
        !setup_field("Upload path on that server (must accept POST, e.g. /bulk)", initial, load) ||
        target.len > 128 || load.len > 128 { return false; }
    candidate.target = target; candidate.load_path = load;
    if !save_wizard_network(candidate) { return false; }
    net = candidate; return true;
}
fn setup_qos_profile(net: WizardNetwork) -> u8[>..] {
    var out: u8[>..] = [];
    out.append(str("{\"bandwidth_kbps\":", net.upload_kbps, ",\"interface\":"));
    json::format_string(out, net.interface_id);
    out.append(",\"mode\":\"cake\",\"overhead_bytes\":0}");
    return out;
}
fn setup_confirm(frame: const u8[:]) -> bool {
    ct_setup_draw(frame, 0);
    while true {
        let key = ct_tui_key(-1);
        if key == 13 || key == 10 { return true; }
        if key == 27 || key == 3 || key < 0 { return false; }
        if key == 256 { ct_setup_draw(frame, 0); }
    }
    return false;
}
fn confirm_qos_apply(d: DeviceState, net: WizardNetwork) -> bool {
    var frame: u8[>..] = [];
    frame.append("CONTINUUM / APPLY SHAPING\n--------------------------------------------------------------------------\n");
    frame.append(str("Router    ", d.candidate_id, "   phase ", d.phase, "\n\n"));
    frame.append(str("Write ONE root qdisc on the WAN egress (", net.interface_id, "):\n\n  cake bandwidth ", net.upload_kbps,
        "kbit overhead 0\n\n"));
    frame.append("Then read it back from the router (tc qdisc show). A rate the router\ndoes not hold is rolled back and refused. No other setting changes.\nReversible: [u] on the final screen restores the kernel default queue.\nThe LOAD gate re-opens: the next step measures this queue.\nNo model call.\n");
    frame.append("\n[Enter] Apply and read back\n[Esc] Cancel without writing");
    return setup_confirm(frame);
}
fn confirm_measure(net: WizardNetwork) -> bool {
    var frame: u8[>..] = [];
    frame.append("CONTINUUM / MEASURE\n--------------------------------------------------------------------------\n");
    frame.append("Run one upload measurement now?\n\n");
    frame.append(str("Target   ", net.target, "   (latency probes, idle then loaded)\nLoad     POST ", net.load_path,
        " on the same server, sustained through the loaded window\n"));
    frame.append("Samples  20 idle and 20 loaded. Failed probes or a refused upload make\n         the run unclaimable, and an unclaimable run cannot qualify.\n\n");
    frame.append("Only an upload crosses the router's shaped egress queue, so the target\nmust be reached through the WAN, not on this LAN. Nothing on the router\nis written. The receipt is saved under device/measure-<time>.json.\n");
    frame.append("\n[Enter] Measure\n[Esc] Cancel without measuring");
    return setup_confirm(frame);
}
fn confirm_qualify(evidence: const u8[:]) -> bool {
    var frame: u8[>..] = [];
    frame.append("CONTINUUM / QUALIFY\n--------------------------------------------------------------------------\n");
    frame.append("Record this measurement as the LOAD gate?\n\n");
    frame.append(str("Evidence  ", evidence, "\n\n"));
    frame.append("It counts only if it is claimable, meets the sample floor and was taken\nafter the last lifecycle change (the queue you just applied). This writes\nlocal state only; nothing on the router changes.\n");
    frame.append("\n[Enter] Qualify\n[Esc] Cancel");
    return setup_confirm(frame);
}
// The last whole output line containing needle.
fn setup_line_with(text: const u8[:], needle: const u8[:]) -> u8[>..] {
    var found: u8[>..] = [];
    var start: i64 = 0;
    while start < text.len {
        var stop: i64 = start;
        while stop < text.len && text[stop] != 10 { stop += 1; }
        if setup_contains(text[start..stop], needle) { found = []; found.append(text[start..stop]); }
        start = stop + 1;
    }
    return found;
}
// The refusal a failed job reports, in its own words: the last JSON reason
// (or unclaimable verdict), or the text after a FOO_REFUSED / FOO_FAILED tag.
fn setup_failure_reason(text: const u8[:]) -> u8[>..] {
    var found: u8[>..] = [];
    var start: i64 = 0;
    while start < text.len {
        var stop: i64 = start;
        while stop < text.len && text[stop] != 10 { stop += 1; }
        var hit: u8[>..] = [];
        if stop > start && text[start] == '{' {
            var doc: json::Node[>..] = []; var decoded: u8[>..] = [];
            let root, err = json::parse(text[start..stop], doc, decoded);
            let reason, r = json::as_string(json::member(root, "reason"));
            let verdict, v = json::as_string(json::member(root, "verdict"));
            if r && reason.len > 0 { hit.append(reason); }
            else if v && verdict != "claimable" { hit.append(verdict); }
        } else if stop > start && (setup_contains(text[start..stop], "_REFUSED ") || setup_contains(text[start..stop], "_FAILED ")) {
            var k: i64 = start;
            while k < stop && text[k] != ' ' { k += 1; }
            hit.append(text[k + 1..stop]);
        }
        if hit.len > 0 { found = copy(hit); }
        start = stop + 1;
    }
    return found;
}
// The setup wizard is the bring-up path: one step at a time, each step stating
// exactly what it will do. The step is derived from durable device state, so a
// crash or restart resumes at the first unfinished step.
fn setup_wizard_step(d: DeviceState, cfg: ModelConfig, bound: bool, key_ok: bool, tuned: bool, settled: bool) -> i64 {
    if !bound || d.candidate_id.len == 0 { return 1; }
    // Enrollment is offered until the unit has been seen to be past it: a
    // factory unit gets set up, and a router that is already configured makes
    // the ceremony refuse safely -- which settles this step either way.
    // A durable phase past enrollment settles it too, so a relaunch after a
    // successful enroll resumes at the key instead of offering enroll again.
    let pending = d.phase == "selected" || d.phase == "enrolling" || d.phase == "unselected";
    if !d.runtime_verified && !settled && pending { return 2; }
    // Only commissioning needs Meta, and only with a key the provider has
    // accepted: a bad key fails here, in words, not as an opaque agent error.
    let commissioned = d.phase == "baseline_applied" || d.phase == "reboot_pending" ||
        d.phase == "network_qualification_required";
    if !commissioned { return if meta_credentials_available(cfg) && key_ok { 4 } else { 3 }; }
    if d.phase == "baseline_applied" { return 5; }
    // reboot_pending is durable: a restart after the reboot request resumes
    // at the persistence check instead of commissioning again.
    if d.phase == "reboot_pending" || !d.persistence_verified { return 6; }
    if !d.network_load_verified { return if tuned { 8 } else { 7 }; }
    return 0;
}
// Wrap a carried sentence so a long refusal never runs into the terminal edge
// (the renderer pads lines but does not break words).
fn setup_wrap(out: u8[>..]&, text: const u8[:], width: i64) {
    var start: i64 = 0;
    while start < text.len {
        var stop: i64 = start;
        var space: i64 = -1;
        while stop < text.len && text[stop] != 10 && stop - start < width {
            if text[stop] == ' ' { space = stop; }
            stop += 1;
        }
        var end: i64 = stop;
        if stop < text.len && text[stop] != 10 && space > start { end = space; }
        if end <= start { end = start + 1; }
        out.append("  ");
        var k: i64 = start;
        while k < end { out.push(text[k]); k += 1; }
        out.append("\n");
        var next: i64 = end;
        while next < text.len && (text[next] == ' ' || text[next] == 10) { next += 1; }
        start = next;
    }
}
fn setup_wizard_advice(out: u8[>..]&, step: i64, reason: const u8[:]) {
    if setup_contains(reason, "probably reset") {
        out.append("  Connect to the router (cable, or its Wi-Fi: a reset ASUS shows\n");
        out.append("  ASUS_XX), then press Enter to set it up again from step 2.\n");
        out.append("  Nothing is written to the router until you confirm there.\n");
    } else if setup_contains(reason, "already set up") {
        out.append("  Take it over as it is: press p and type the admin password this\n");
        out.append("  router already uses. Continuum verifies it, stores it in the OS\n");
        out.append("  vault, and continues -- nothing on the router is changed.\n\n");
        out.append("  Or make it factory again: hold RESET about 10 seconds, until its\n");
        out.append("  LEDs blink, then press Enter here to run the ceremony.\n");
    } else if setup_contains(reason, "secured bands") {
        out.append("  This unit is already configured. Press Enter to go on with the\n");
        out.append("  credential Continuum already holds for it.\n");
    } else if step == 3 {
        out.append("  The provider did not accept this key. Press k to enter another\n");
        out.append("  key, or Enter to test this one again (one call each).\n");
    } else if setup_contains(reason, "reboot_not_observed") {
        out.append("  The router did not restart. Power-cycle it (unplug it for ten\n");
        out.append("  seconds), wait until it answers, then press Enter to verify again.\n");
    } else if setup_contains(reason, "has not answered") {
        out.append("  Check the router's power and cable. When it answers again, press\n");
        out.append("  Enter to verify persistence.\n");
    } else if setup_contains(reason, "qdisc_cake_unavailable") {
        out.append("  This firmware's tc has no CAKE queue, so Continuum cannot shape\n");
        out.append("  here. Nothing was written; steps 1-6 stand. Press Esc to stop.\n");
    } else if setup_contains(reason, "qdisc_tool_unavailable") {
        out.append("  This firmware has no tc, so it cannot host the shaping queue.\n");
        out.append("  Nothing was written. Press Esc to stop here.\n");
    } else if setup_contains(reason, "already_managed") {
        out.append("  Vendor QoS owns the WAN queue. Turn off Adaptive QoS and the\n");
        out.append("  bandwidth limiter in the router's web UI, then press Enter.\n");
    } else if setup_contains(reason, "readback") {
        out.append("  The router did not hold that queue and it was rolled back. Press c\n");
        out.append("  to choose a lower bandwidth, then Enter.\n");
    } else if step == 8 {
        out.append("  Press c to fix the target or upload path, or Enter to measure\n");
        out.append("  again. The far end must accept POST and be reached via the WAN.\n");
    } else if setup_contains(reason, "unreachable") || setup_contains(reason, "transport") {
        out.append("  Check the link to the router (cable or Wi-Fi), then press Enter\n");
        out.append("  to try this step again.\n");
    } else {
        out.append("  Press Enter to retry this step. If it fails the same way, press\n");
        out.append("  i and share the raw output.\n");
    }
}
fn setup_wizard_body(out: u8[>..]&, cfg: ModelConfig, network: const u8[:], key_ok: bool, tuned: bool, settled: bool,
        qos_checked: bool, evidence: const u8[:], watching: bool, watch_down: bool, details: const u8[:],
        notice: const u8[:], busy: bool, failed: bool, why: const u8[:], show_raw: bool, labels: const u8[:]) -> i64 {
    var d = DeviceState {};
    let bound = device_saved(setup_directory(), d) && d.candidate_id.len > 0;
    let step = setup_wizard_step(d, cfg, bound, key_ok, tuned, settled);
    let has_key = meta_credentials_available(cfg);
    var net = WizardNetwork {};
    load_wizard_network(net);
    var resident = ResidentStatus {};
    let running = setup_resident_status(resident) && resident.valid && resident.phase == "monitoring";
    out.append("CONTINUUM / SETUP\n");
    out.append("--------------------------------------------------------------------------\n");
    var banner: u8[>..] = [];
    if step == 1 { banner.append("BIND THE ROUTER"); }
    else if step == 2 { banner.append("ENROLL THE ROUTER"); }
    else if step == 3 { banner.append("META KEY"); }
    else if step == 4 { banner.append("SET THE ROUTER UP"); }
    else if step == 5 { banner.append("REBOOT"); }
    else if step == 6 { banner.append(if watching { "WAITING FOR THE ROUTER" } else { "VERIFY PERSISTENCE" }); }
    else if step == 7 { banner.append("TUNE"); }
    else if step == 8 { banner.append("MEASURE"); }
    else { banner.append("SETUP COMPLETE"); }
    out.append(str("STEP ", if step == 0 { 8 } else { step }, " OF 8   "));
    out.append(banner);
    out.append("\n\n");
    var cand_ids: u8[..64][>..] = []; var cand_kinds: u8[>..] = [];
    var single: u8[>..] = [];
    if step == 1 { setup_candidates(network, cand_ids, cand_kinds); single = setup_marked(network, labels); }
    if step == 1 && single.len == 0 {
        if cand_ids.len == 0 { out.append("Looking for your router...\n\n"); }
        else {
            out.append("Looking for your router. In reach, but not one Continuum can drive:\n");
            var m: i64 = 0;
            while m < cand_ids.len {
                let kind = setup_nth_line(cand_kinds, m);
                if kind.len >= 13 && kind[kind.len - 13..kind.len] == "default route" {
                    out.append(str("  ", m + 1, "  ", cand_ids[m], "   ", setup_nth_line(labels, m), "\n"));
                }
                m += 1;
            }
            out.append("\n");
        }
        out.append("Connect this Mac to the router any way you like:\n");
        out.append("  - plug a cable into one of its LAN ports, or\n");
        out.append("  - pick its Wi-Fi in the menu bar. A reset ASUS shows ASUS_XX\n");
        out.append("    (open, no password).\n");
        out.append("Continuum notices by itself; there is nothing to type here.\n");
        out.append("\nNothing has been written anywhere.\n");
    } else if step == 1 {
        out.append("Routers this Mac can reach:\n\n");
        // Gateways and the marked router only; other hosts on the LAN keep
        // their numbers (so a pick still works) but are not routers to list.
        var n: i64 = 0; var hidden: i64 = 0;
        while n < cand_ids.len {
            let kind = setup_nth_line(cand_kinds, n);
            let gateway = kind.len >= 13 && kind[kind.len - 13..kind.len] == "default route";
            if gateway || single == cand_ids[n] {
                out.append(str(if single == cand_ids[n] { "> " } else { "  " }, n + 1, "  ", cand_ids[n], "   (",
                    kind, ")\n     ", setup_nth_line(labels, n), "\n"));
            } else { hidden += 1; }
            n += 1;
        }
        if hidden > 0 { out.append(str("  (+", hidden, " other devices on the network)\n")); }
        out.append("\nEnter takes over the marked router. This step records the target\nonly; nothing is written to the router yet.\n");
    } else if step == 2 {
        out.append("Creates this router's admin credential, renames its Wi-Fi and\nrotates the passphrase. This host may drop off Wi-Fi and rejoin.\n\nFactory-only: a unit that is already configured refuses safely and\nnothing on it changes. On that failure you can take the unit over\nwith the admin password it already uses.\n");
    } else if step == 3 {
        if has_key { out.append("A key is configured but not verified. Continuum reads the models\nthis key can use (free), you pick one and its reasoning effort with\nprices from Meta's rate card, then one connection-test call proves\nthe provider accepts the key on that model.\n"); }
        else { out.append("Meta needs a key to set the router up. It is hidden while you\ntype, kept in this session unless you choose the Keychain, and\nnever printed or written to settings. Then you pick the model and\neffort from the ones the key can use, and one connection-test call\nproves the provider accepts it.\n"); }
        out.append(str("\nModel   ", cfg.controller_model, "   effort ", cfg.reasoning_effort, "\n"));
    } else if step == 4 {
        out.append("Meta inspects the router and applies its owned baseline: vendor\nservices stripped, fully reversible. No reboot, no reset and no\nfirmware change. The step counts only when the router's own receipt\nshows the baseline applied with runtime and recovery verified.\n");
    } else if step == 5 {
        out.append("One reboot proves the baseline persists. The network drops for\na few minutes. This approves exactly one reboot, nothing else.\n");
    } else if step == 6 && watching {
        out.append("Reboot requested. Continuum waits for the router to stop answering\nand answer again (a protected read every few seconds; nothing is\nwritten). The request's own exit code is not trusted either way.\n");
        out.append(str("\n  Went down   ", if watch_down { "yes" } else { "not yet" }, "\n"));
    } else if step == 6 {
        out.append("Continuum reads the router again and proves the owned baseline\nsurvived the restart: a new boot identity and every owned setting\nstill in force. Deterministic; no model call.\n");
    } else if step == 7 && !qos_checked {
        out.append("Shaping is one CAKE root qdisc on the WAN egress. First a read-only\npreflight checks that the router has tc and reads its current root\nqueue. The preflight writes nothing.\n");
    } else if step == 7 {
        out.append("Next: write ONE root qdisc and read it back from the router.\n");
        if net.upload_kbps > 0 { out.append(str("Saved profile: cake ", net.upload_kbps, " kbit/s on ", net.interface_id, " ([c] changes it).\n")); }
        else { out.append("The first apply asks once for your upload bandwidth and WAN\ninterface.\n"); }
    } else if step == 8 && evidence.len == 0 {
        out.append("One upload measurement across the WAN: idle probes, then the same\nprobes while uploading. Only an upload crosses the shaped queue.\nNothing on the router is written.\n");
        if net.target.len > 0 { out.append(str("\n  Target  ", net.target, "\n  Upload  POST ", net.load_path, "   ([c] changes them)\n")); }
        else { out.append("\nThe first run asks once for a far-end server you control.\n"); }
    } else if step == 8 {
        out.append("The measurement below is claimable. Qualifying records it as the\nLOAD gate; only a run taken after the last change can count.\n");
    } else {
        out.append("Every gate is earned; the panels hold the evidence.\n");
        if running {
            out.append(str("\nMonitor  monitoring, pid ", resident.pid, ", ", resident.samples, " samples every ",
                resident.interval_ms, " ms\n"));
        } else if resident.valid { out.append(str("\nMonitor  ", resident.phase, " -- not running\n")); }
        else { out.append("\nMonitor  not running\n"); }
    }
    out.append(str("\nRouter  ", if bound { d.candidate_id } else { "none bound" }, "   Phase  ", d.phase,
        "   Key  ", if !has_key { "missing" } else if key_ok { "verified" } else { "unverified" }, "\n"));
    if failed {
        // A refusal is a fact the owner has to act on, not a JSON wall.
        let reason = if why.len > 0 { why } else { d.reason };
        out.append("\nWHY IT STOPPED\n");
        setup_wrap(out, if reason.len > 0 { reason } else { "the step was refused; no detail was recorded" }, 72);
        out.append("\nWHAT TO DO\n");
        setup_wizard_advice(out, step, reason);
        if show_raw && details.len > 0 {
            out.append("\nRAW OUTPUT (i hides this)\n");
            var raw_tail: u8[>..] = [];
            var ri: i64 = if details.len > 900 { details.len - 900 } else { 0 };
            if ri > 0 { var k: i64 = ri; while k < details.len && k < ri + 200 && details[k - 1] != 10 { k += 1; } if k < ri + 200 { ri = k; } }
            while ri < details.len { raw_tail.push(details[ri]); ri += 1; }
            out.append(raw_tail);
        }
    } else if details.len > 0 {
        out.append("\n");
        var tail: u8[>..] = [];
        // Newest output last; never start mid-line.
        var i: i64 = if details.len > 1400 { details.len - 1400 } else { 0 };
        if i > 0 { var k: i64 = i; while k < details.len && k < i + 200 && details[k - 1] != 10 { k += 1; } if k < i + 200 { i = k; } }
        while i < details.len { tail.push(details[i]); i += 1; }
        out.append(tail);
    }
    if busy && !watching {
        if notice.len > 0 { out.append("\n"); out.append(notice); out.append("\n"); }
        out.append("\nRunning. q cancels; an uncertain step is never replayed.\n");
    }
    else if notice.len > 0 { out.append("\n"); out.append(notice); out.append("\n"); }
    // The renderer pins the last three lines, so the actions are exactly these.
    out.append("\n");
    if watching { out.append("[q] Stop waiting and quit\n"); }
    else if busy { out.append("[q] Cancel this step and quit\n"); }
    else if failed {
        // Takeover stays offered for any failure on the enroll step: the only
        // credential this could overwrite is one that just failed to answer.
        if step == 2 { out.append("[Enter] Retry    [p] Take over    [i] Raw output\n"); }
        else if step == 3 { out.append("[Enter] Test again    [k] New key    [i] Raw output\n"); }
        else if (step == 7 && qos_checked) || step == 8 { out.append("[Enter] Retry    [c] Change inputs    [i] Raw output\n"); }
        else { out.append("[Enter] Retry this step    [i] Raw output\n"); }
    }
    else if step == 1 && single.len == 0 { out.append(if cand_ids.len > 0 { "Waiting for the router    [1-9] Use a listed one anyway\n" } else { "Waiting for the router; it appears here on its own.\n" }); }
    else if step == 1 { out.append(if cand_ids.len > 1 { "[Enter] Take over the marked router    [1-9] Another\n" } else { "[Enter] Take over this router\n" }); }
    else if step == 2 { out.append("[Enter] Enroll this router\n"); }
    else if step == 3 { out.append(if has_key { "[Enter] Choose the model, then verify    [k] New key\n" } else { "[Enter] Enter the Meta key\n" }); }
    else if step == 4 { out.append("[Enter] Let Meta set it up\n"); }
    else if step == 5 { out.append("[Enter] Reboot now (one time)\n"); }
    else if step == 6 { out.append("[Enter] Verify persistence\n"); }
    else if step == 7 { out.append(if qos_checked { "[Enter] Apply shaping    [c] Change bandwidth\n" } else { "[Enter] Read the WAN queue (read-only)\n" }); }
    else if step == 8 { out.append(if evidence.len > 0 { "[Enter] Qualify with this measurement\n" } else { "[Enter] Run the upload measurement    [c] Change target\n" }); }
    else { out.append(if running { "[Enter] Refresh    [u] Undo the shaping\n" } else { "[Enter] Start the resident monitor    [u] Undo the shaping\n" }); }
    out.append(if watching { "Waiting for the router; keys are locked.\n" } else if busy { "Keys are locked while a step runs.\n" } else { "[Esc] Quit    [a] Advanced panels\n" });
    let names: const u8[:][..8] = ["BIND", "ENROLL", "KEY", "SETUP", "REBOOT", "VERIFY", "TUNE", "MEASURE"];
    var i2: i64 = 0;
    while i2 < 8 {
        if i2 > 0 { out.append("  "); }
        if step == i2 + 1 { out.append("["); out.append(names[i2]); out.append("]"); }
        else { out.append(names[i2]); }
        i2 += 1;
    }
    out.append("\n");
    return step;
}
fn setup_section_name(section: i64) -> const u8[:] {
    if section == 1 { return "NETWORK"; }
    if section == 2 { return "DEVICE"; }
    if section == 3 { return "PROGRAMS"; }
    if section == 4 { return "RESIDENT"; }
    if section == 5 { return "HELP"; }
    if section == 6 { return "RESULT"; }
    return "OVERVIEW";
}
fn setup_watch_summary(network: const u8[:], out: u8[>..]&, seen_wall: i64) {
    var doc: json::Node[>..] = []; var decoded: u8[>..] = [];
    let root, err = json::parse(network, doc, decoded);
    if !root { out.append("WATCHING no observation yet - [d] Discover"); return; }
    let interfaces = json::member(root, "interfaces");
    var name: u8[..64] = "no interfaces"; var address: u8[..64] = "";
    if interfaces && interfaces.first {
        let entry = interfaces.first;
        let n, ok_n = json::as_string(json::member(entry, "name"));
        let a, ok_a = json::as_string(json::member(entry, "address"));
        if ok_n && ok_a { name = n; address = a; }
    }
    out.append(str("WATCHING ", name, " ", address));
    if seen_wall > 0 {
        let now = time_ns() / 1000000;
        if now >= seen_wall {
            let age = now - seen_wall;
            if age < 60000 { out.append(" just now"); }
            else if age < 3600000 { out.append(str(" ", age / 60000, "m ago")); }
            else { out.append(str(" ", age / 3600000, "h ago")); }
        }
    }
}
fn setup_device_line(out: u8[>..]&) {
    var d = DeviceState {};
    if !device_saved(setup_directory(), d) { out.append("SELECTED binding busy"); return; }
    if d.candidate_id.len == 0 { out.append("SELECTED none"); return; }
    out.append(str("SELECTED ", d.candidate_id, " ", d.phase,
        if d.setup_approved { " approved" } else { " pending" }));
}
fn setup_permission_summary(out: u8[>..]&) {
    var policy = OwnerPolicy {};
    if !device_open(setup_directory(), 0) { out.append("PERMISSION binding busy"); return; }
    let ok = owner_load(policy); ct_device_close();
    if !ok { out.append("PERMISSION invalid - [f] Repair"); return; }
    out.append("PERMISSION ");
    if policy.allowed_operations.len == 0 { out.append("none"); }
    for op, index in policy.allowed_operations { if index > 0 { out.append(","); } out.append(op); }
    if policy.allow_host_programs { out.append(" | code on"); }
}
struct ResidentStatus {
    present: bool = false,
    valid: bool = false,
    phase: u8[..64] = "",
    pid: i64 = 0,
    samples: i64 = 0,
    interval_ms: i64 = 0,
    calls: i64 = 0,
    permit: bool = false,
    incident: u8[..64] = "",
    assessment: u8[..64] = "",
}
// One parse of service/status.json behind both the strip summary and the
// Resident section; the two views must never disagree about the file.
fn setup_resident_status(status: ResidentStatus&) -> bool {
    status = ResidentStatus {};
    let path = str(setup_directory(), "/service/status.json");
    if !file_exists(path) { return false; }
    status.present = true;
    var text: u8[>..] = [];
    if !read_file(path, text) || text.len > 16384 { return true; }
    var doc: json::Node[>..] = []; var decoded: u8[>..] = [];
    let root, err = json::parse(text, doc, decoded);
    if !root { return true; }
    let phase, p = json::as_string(json::member(root, "phase"));
    let pid, i = json::as_i64(json::member(root, "pid"));
    let samples, s = json::as_i64(json::member(root, "samples"));
    let interval, v = json::as_i64(json::member(root, "sample_interval_ms"));
    let calls, c = json::as_i64(json::member(root, "model_calls_this_hour"));
    let permit, m = json::as_bool(json::member(root, "meta_permission"));
    let incident, n = json::as_string(json::member(root, "incident"));
    let assessment, a = json::as_string(json::member(root, "assessment_status"));
    if !p || !i || !s || !v || !c || !m || !n || !a { return true; }
    status.valid = true; status.phase = phase; status.pid = pid; status.samples = samples;
    status.interval_ms = interval; status.calls = calls; status.permit = permit;
    status.incident = incident; status.assessment = assessment;
    return true;
}
fn setup_resident_summary(out: u8[>..]&) {
    var status = ResidentStatus {};
    if !setup_resident_status(status) { out.append("RESIDENT not running"); return; }
    if !status.valid { out.append("RESIDENT status invalid"); return; }
    out.append(str("RESIDENT ", status.phase, " pid ", status.pid));
}
fn setup_resident_view(out: u8[>..]&) {
    out.append("RESIDENT\n\n");
    var status = ResidentStatus {};
    if !setup_resident_status(status) {
        out.append("Not running. No Meta calls are being made on your behalf.\n[s] Start monitor (asks interval/cooldown/cap, then confirms).\nStarting grants NO device-write or router-reboot permission.\n"); return;
    }
    if !status.valid { out.append("Status record invalid; not replaced. Inspect service/status.json.\n"); return; }
    var cfg = ServiceConfig {};
    load_service_config(setup_directory(), cfg);
    out.append(str("STATE    ", status.phase, " pid ", status.pid, "\nSAMPLES  ", status.samples, " every ", status.interval_ms, " ms\n",
        "INCIDENT ", if status.incident.len == 0 { "none" } else { status.incident }, "\n",
        "META     incidents ", if status.permit { "on" } else { "off" }, " - calls this hour ", status.calls, " / cap ", cfg.max_calls_per_hour, "\n",
        "ASSESS   ", status.assessment, "\n\n[s] Start / reconfigure (refuses while already running)\n[t] Talk to Meta\n"));
}
fn setup_overview_body(frame: u8[>..]&, cfg: ModelConfig, verified: bool, network: const u8[:], details: const u8[:]) {
    var d = DeviceState {};
    let has_device = device_saved(setup_directory(), d) && d.candidate_id.len > 0;
    frame.append("NEEDS ATTENTION\n");
    var attention: i64 = 0;
    if network.len == 0 { frame.append("  !  No host observation yet. [d] Discover this host's network.\n"); attention += 1; }
    if !has_device { frame.append("  !  No device selected. Meta cannot act until you choose one. [p]\n"); attention += 1; }
    if !meta_credentials_available(cfg) { frame.append("  !  Meta key not configured. [m] (investigation/talk unlock after)\n"); attention += 1; }
    if attention == 0 { frame.append("  .  Nothing. Healthy recurring work uses no model calls.\n"); }
    frame.append("\nNEXT ACTION\n");
    if network.len == 0 { frame.append("  - Discover the environment here - no router details required. [d]\n"); }
    else if !has_device { frame.append("  - Select the device you own from observed candidates. [p]\n"); }
    else { frame.append("  - Review the device gates, then start monitoring if ready. [3 / s]\n"); }
    frame.append("  - Set what Meta may do - defaults deny new authority. [f]\n\n");
    if network.len == 0 && !has_device {
        frame.append("FIRST RUN  STEP 1 OF 3 - DISCOVER\n");
        frame.append("Continuum watches this host first. You can discover, select a device\nand set permissions before entering any Meta key.\n\n");
    } else if !has_device {
        frame.append("FIRST RUN  STEP 2 OF 3 - SELECT\n");
        frame.append("Host observed. Choose the device you own next; selection grants\nno write permission. [p]\n\n");
    } else {
        var resident = ResidentStatus {};
        if !setup_resident_status(resident) {
            frame.append("FIRST RUN  STEP 3 OF 3 - PERMISSIONS + MONITOR\n");
            frame.append("Set what Meta may do [f], then start the resident monitor [s].\nStarting grants no device-write or reboot permission.\n\n");
        }
    }
    frame.append("CONNECTION\n");
    frame.append(str("  Controller  ", cfg.controller_model, "\n  Workload    ", cfg.task_model,
        "\n  Budget      ", cfg.max_tool_rounds, " calls/session; ", cfg.max_output_tokens,
        " output tokens/response\n  Timeout     ", cfg.request_timeout_ms, " ms/request\n\n"));
    if details.len > 0 { frame.append("-----\n"); frame.append(details); frame.append("\n"); }
    else { frame.append("No idle model calls. Reboot is denied by default; the lab stays separate.\n"); }
}
fn setup_help_body(frame: u8[>..]&) {
    frame.append("HELP\n\n");
    frame.append("1-5 / h   Overview, Network, Device, Programs, Resident, Home\n");
    frame.append("d / p     Discover host network / select the device you own\n");
    frame.append("m / c / v   Meta key (private) / models+budget / test connection (bounded, confirms first)\n");
    frame.append("f           Owner permissions: operations, protected users/services, local code, slots, retention\n");
    frame.append("i/u/n/e/r/b  Inspect / authorize / enroll factory unit / Meta setup / restore / one reboot\n");
    frame.append("t / a / l   Talk to Meta / investigate paths / simulator lab (bounded calls, confirm first)\n");
    frame.append("s           Start resident monitor (grants no write/reboot permission)\n");
    frame.append("Enter/x/E/R  On Programs: read / disable / enable / reconcile by id\n");
    frame.append("j/k arrows scroll, J/K or PgUp/PgDn page      q / Ctrl-C quit or cancel the running job\n\n");
    frame.append("Model text is never evidence or authority. Secrets never enter the model context.\n");
}
fn setup_program_action(operation: const u8[:], out: u8[>..]&) -> bool {
    var id: u8[>..] = [];
    if !setup_field("Program id", "", id) { out.append("Cancelled; no program change.\n"); return false; }
    let directory = setup_directory();
    if !device_open(directory, 1) { out.append("Device binding busy; no state replaced.\n"); return false; }
    var d = DeviceState {};
    if !device_load(d) { ct_device_close(); out.append("Invalid device binding; no program change.\n"); return false; }
    let result = program_tool(directory, d, operation, id);
    ct_device_close();
    out.append(str("PROGRAM / ", operation, " / ", id, "\n\n"));
    out.append(result.receipt); out.append("\n");
    return result.ok;
}
fn setup_footer(frame: u8[>..]&, section: i64, busy: bool) {
    if busy {
        frame.append("[1-5] sections  [j/k] scroll  [?] help  [q] quit\n[q] Cancel job and quit - keys locked while busy\n");
        return;
    }
    frame.append("[1-5] sections  [j/k] scroll  [?] help  [q] quit\n");
    if section == 2 {
        frame.append("[p] Select [i] Inspect [u] Authorize [e] Setup [r] Restore [b] Reboot\n[Enter] Next  [m] Meta key  [c] Models  [f] Permissions  [t] Talk  [s] Monitor\n");
    } else if section == 3 {
        frame.append("[Enter] Read  [x] Disable  [E] Enable  [R] Reconcile (by id)  [1-5] Sections\n[m] Meta key  [c] Models/budget  [f] Permissions  [t] Talk\n");
    } else if section == 4 {
        frame.append("[s] Start monitor  [t] Talk   [1-5] Sections\n[m] Meta key  [c] Models/budget  [f] Permissions\n");
    } else if section == 1 {
        frame.append("[d] Refresh  [p] Select device  [a] Investigate via Meta (bounded calls)\n[m] Meta key  [c] Models/budget  [f] Permissions  [t] Talk\n");
    } else {
        frame.append("[m] Meta key  [c] Models/budget  [v] Test  [d] Discover  [p] Select\n[f] Permissions  [t] Talk  [a] Investigate  [l] Lab  [s] Monitor\n");
    }
}

fn run_setup_tui() -> bool {
    if ct_tui_open() != 0 { return false; }
    var cfg = setup_defaults();
    let settings_ok = load_setup_settings(cfg);
    let key_source = ct_tui_key_load();
    var notice: u8[>..] = [];
    if !settings_ok { notice.append("Saved settings invalid; defaults in use. Press c to repair."); }
    else if key_source == 2 { notice.append("Key loaded from Keychain; provider not tested."); }
    else { notice.append("Discover the environment here; no router details required."); }
    // Read this host once at startup (local interfaces/routes only, no scan and
    // no provider call) so the Device panel can act on what is actually here
    // instead of sending the operator to the CLI.
    var network: u8[>..] = discover_host();
    var labels: u8[>..] = setup_identify(network);
    var observed_wall_ms: i64 = time_ns() / 1000000;
    var details: u8[>..] = [];
    var startup_device = DeviceState {};
    let startup_bound = device_saved(setup_directory(), startup_device) && startup_device.candidate_id.len > 0;
    let startup_ready = startup_device.setup_approved && startup_device.runtime_verified &&
        startup_device.recovery_verified && startup_device.persistence_verified && startup_device.network_load_verified;
    var screen: i64 = if startup_bound && startup_ready { 0 } else { 2 }; var scroll: i64 = 0;
    // The wizard is the landing view until the installation is ready: one
    // Enter per step, each step stating exactly what it will do.
    var wizard = !(startup_bound && startup_ready);
    if wizard { notice = []; }
    var tuned = false; var wizard_job: i64 = 0;
    // A failed step is explained in words on the same screen; raw output is
    // opt-in (i), never the default. fail_reason carries the job's own refusal.
    var step_failed = false; var show_raw = false; var fail_reason: u8[>..] = [];
    // TUNE runs a read-only preflight before its write; MEASURE produces the
    // evidence path that QUALIFY consumes.
    var qos_checked = false; var evidence: u8[>..] = [];
    // After a reboot request the router's return is the success signal, not
    // the request's exit code: a real unit drops the link mid-request.
    var watching = false; var watch_down = false; var watch_start: i64 = 0; var watch_next: i64 = 0;
    var ready_view = false;
    // Step 1 with no router Continuum can drive keeps looking on its own, so
    // plugging in a cable or picking the router's Wi-Fi in the menu bar is
    // all the owner does.
    var seeking = false; var seek_next: i64 = 0;
    var esc_armed = false;
    // Enrollment settles when the ceremony succeeds or when the unit refuses
    // because it is already configured; either way the step is done.
    var settled = false;
    var busy = false; var dirty = true; var verified = false;
    var job: u8[>..] = [];
    // Step 3 reads the key's own model catalog, then the owner picks a model
    // and effort before the one billed connection test.
    var models: u8[>..] = []; var pick_pending = false;
    while true {
        if pick_pending && !busy {
            pick_pending = false; notice = [];
            if !setup_pick_model(cfg, models) { notice.append("No model saved. Press Enter to choose again."); }
            else {
                verified = false;
                job = []; job.append("test-key");
                if !confirm_setup_job(cfg, job) { notice.append("Key not tested; Meta setup stays locked until it is."); }
                else if ct_setup_job_start(job) == 0 {
                    busy = true; details = []; wizard_job = 3;
                    notice.append(str("Testing the key on ", cfg.controller_model, " with one connection-test call."));
                } else { notice.append("Could not start the key test."); }
            }
            dirty = true;
        }
        if dirty {
            var wframe: u8[>..] = [];
            if wizard {
                let drawn = setup_wizard_body(wframe, cfg, network, verified, tuned, settled, qos_checked, evidence,
                    watching, watch_down, details, notice, busy, step_failed, fail_reason, show_raw, labels);
                // READY shows the live monitor; it repaints once a second.
                ready_view = drawn == 0 && !busy;
                seeking = drawn == 1 && !busy && !step_failed && setup_marked(network, labels).len == 0;
                ct_setup_draw(wframe, 0); dirty = false;
            } else {
            var frame: u8[>..] = [];
            frame.append(str("CONTINUUM - ", setup_section_name(screen), if busy { "  BUSY" } else { "" },
                "    META ", if meta_credentials_available(cfg) { if verified { "VERIFIED" } else { "KEY STAGED / UNVERIFIED" } } else { "NOT CONFIGURED" }, "\n"));
            var nav: u8[>..] = [];
            nav.append(if screen == 0 { "[1] Overview" } else { " 1  Overview" });
            nav.append(if screen == 1 { "  [2] Network" } else { "   2 Network" });
            nav.append(if screen == 2 { "  [3] Device" } else { "   3 Device" });
            nav.append(if screen == 3 { "  [4] Programs" } else { "   4 Programs" });
            nav.append(if screen == 4 { "  [5] Resident" } else { "   5 Resident" });
            if scroll > 0 { nav.append(str("  SCROLL +", scroll)); }
            frame.append(nav); frame.append("\n");
            var strip: u8[>..] = [];
            setup_watch_summary(network, strip, observed_wall_ms); strip.append(" | ");
            setup_device_line(strip); frame.append(strip); frame.append("\n");
            var strip2: u8[>..] = [];
            setup_permission_summary(strip2); strip2.append(" | ");
            setup_resident_summary(strip2); frame.append(strip2); frame.append("\n");
            if notice.len > 0 { frame.append(notice); frame.append("\n"); }
            if screen == 1 {
                setup_network_view(network, frame);
                if details.len > 0 { frame.append("\n-----\n"); frame.append(details); frame.append("\n"); }
            }
            else if screen == 2 {
                if details.len > 0 { frame.append(details); frame.append("\n"); }
                else { setup_device_view(frame); }
            }
            else if screen == 3 {
                if details.len > 0 { frame.append(details); frame.append("\n"); }
                else { programs_view(setup_directory(), frame); }
            }
            else if screen == 4 {
                if details.len > 0 { frame.append(details); frame.append("\n"); }
                else { setup_resident_view(frame); }
            }
            else if screen == 5 { setup_help_body(frame); }
            else if screen == 6 {
                if details.len > 0 { frame.append(details); frame.append("\n"); }
                else { frame.append("No result yet.\n"); }
            }
            else { setup_overview_body(frame, cfg, verified, network, details); }
            frame.append("\n");
            setup_footer(frame, screen, busy);
            ct_setup_draw(frame, scroll); dirty = false;
            }
        }
        let key = ct_tui_key(if busy || watching { 100 } else if wizard && (ready_view || seeking) { 1000 } else { -1 });
        if key == 'q' || key == 3 || key < 0 { ct_tui_job_cancel(); break; }
        // A job owns the current snapshot. Do not replace settings/credentials
        // underneath it; q cancels its whole child process group.
        if !busy {
            // Wizard keys: Enter advances exactly one step; Esc ends the program
            // and a opens the panels. Every step keeps its own confirm frame.
            if key != 27 && key != 0 && key != 256 && esc_armed { esc_armed = false; notice = []; dirty = true; }
            if wizard && watching {
                // Waiting for a rebooting router: only quitting is offered.
                if key == 27 { break; }
            } else if wizard && (key == 13 || key == 10 || key == 'k' || key == 'c' || key == 'u' || (key >= '1' && key <= '9')) {
                var wd = DeviceState {};
                let wbound = device_saved(setup_directory(), wd) && wd.candidate_id.len > 0;
                let wstep = setup_wizard_step(wd, cfg, wbound, verified, tuned, settled);
                let enter = key == 13 || key == 10;
                // A letter acts only on the screen that offers it.
                let offered = enter || (key == 'k' && wstep == 3) || (key == 'u' && wstep == 0) ||
                    (wstep == 1 && key >= '1' && key <= '9') ||
                    (key == 'c' && ((wstep == 7 && qos_checked) || (wstep == 8 && evidence.len == 0)));
                // A step that found the saved admin password refused (a factory
                // reset since enrollment) offers Enter to start over at step 2.
                let was_reset = step_failed && setup_contains(fail_reason, "probably reset");
                if offered {
                notice = [];
                step_failed = false; show_raw = false; fail_reason = [];
                if was_reset && enter && wstep != 1 && wstep != 2 {
                    network = discover_host(); labels = setup_identify(network); observed_wall_ms = time_ns() / 1000000;
                    var stem: u8[..27] = "Continuum";
                    if wd.connection.ssid_stem.len > 0 { stem = wd.connection.ssid_stem; }
                    // The router may now be reached over another link (cable
                    // instead of Wi-Fi), so prefer the one supported router in reach.
                    var pick: u8[>..] = [];
                    let marked = setup_marked(network, labels);
                    if marked.len > 0 { pick.append(marked); } else { pick.append(wd.candidate_id); }
                    if device_select(setup_directory(), network, pick, stem, wd.connection.port, false, true) {
                        settled = false; tuned = false; qos_checked = false; evidence = [];
                        notice.append("Starting over at step 2 for the reset router. Nothing has been written to it yet.");
                    } else {
                        step_failed = true;
                        fail_reason.append("the router no longer accepts Continuum's admin password; it was probably reset to factory settings, and it is not in reach right now");
                    }
                } else if wstep == 1 {
                    var ids: u8[..64][>..] = []; var kinds: u8[>..] = [];
                    setup_candidates(network, ids, kinds);
                    let marked = setup_marked(network, labels);
                    var pick: u8[>..] = []; var label: u8[>..] = [];
                    if key >= '1' && key <= '9' {
                        let n = key - '1';
                        if n < ids.len { pick.append(ids[n]); label = setup_nth_line(labels, n); }
                        else { notice.append("No router has that number."); }
                    } else if marked.len > 0 {
                        pick.append(marked);
                    } else {
                        network = discover_host(); labels = setup_identify(network); observed_wall_ms = time_ns() / 1000000;
                    }
                    // A numbered pick of a router Continuum cannot identify is
                    // the owner overriding the marking, so that one confirms.
                    if pick.len > 0 {
                        if key >= '1' && key <= '9' && pick != marked && !confirm_bind(pick, label) { notice.append("Binding cancelled; target unchanged."); }
                        else if !device_select(setup_directory(), network, pick, "Continuum", 80, false) {
                            notice.append("Binding refused or the router is no longer observed. Press Enter to look again.");
                        }
                    }
                } else if wstep == 2 {
                    job = []; job.append("device-enroll");
                    var stem: u8[..27] = "Continuum";
                    if wd.connection.ssid_stem.len > 0 { stem = wd.connection.ssid_stem; }
                    if !confirm_device_job(job) { notice.append("Nothing dispatched."); }
                    else {
                        // Re-bind the same candidate against the credential
                        // Continuum already holds for this address instead of
                        // minting a new empty slot. If that credential no longer
                        // answers (a real reset), enrollment runs anyway and
                        // stages into the same slot.
                        let prepared = device_select(setup_directory(), network, wd.candidate_id, stem, wd.connection.port, true);
                        if !prepared { notice.append("The router is no longer observed; press a, then d/p."); }
                        else if ct_setup_job_start(job) == 0 {
                            busy = true; details = []; wizard_job = 2;
                            notice.append("Enrolling: 2-5 minutes. The router restarts its Wi-Fi under the new\nname and this Mac rejoins it by itself; Wi-Fi drops meanwhile.");
                        } else { notice.append("Could not start enrollment."); }
                    }
                } else if wstep == 3 {
                    var have_key = meta_credentials_available(cfg);
                    if key == 'k' || !have_key {
                        let key_result = ct_tui_key_setup(); verified = false; models = [];
                        have_key = key_result == 1 || key_result == 2;
                        if !have_key { notice.append("Key entry cancelled or rejected; nothing was tested."); }
                    }
                    if have_key && models.len > 0 { pick_pending = true; }
                    else if have_key {
                        job = []; job.append("models");
                        if ct_setup_job_start(job) == 0 {
                            busy = true; details = []; wizard_job = 14;
                            notice.append("Reading the models this key can use (a free catalog read).");
                        } else { notice.append("Could not start the model listing."); }
                    }
                } else if wstep == 4 || wstep == 5 || wstep == 6 || (wstep == 7 && !qos_checked) || (wstep == 0 && key == 'u') {
                    // One deterministic device job per step; only step 4 is Meta.
                    job = [];
                    job.append(if wstep == 4 { "device-setup" } else if wstep == 5 { "device-reboot" }
                        else if wstep == 6 { "device-verify" } else if wstep == 7 { "device-qos-status" } else { "qos-restore" });
                    let code = if wstep == 4 { 4 } else if wstep == 5 { 5 } else if wstep == 6 { 6 } else if wstep == 7 { 11 } else { 13 };
                    if wstep == 4 && !meta_credentials_available(cfg) { notice.append("The Meta key is missing; press k on step 3."); }
                    else if !confirm_device_job(job) { notice.append("Nothing dispatched."); }
                    else if ct_setup_job_start(job) == 0 {
                        busy = true; details = []; wizard_job = code;
                        notice.append(if wstep == 4 { "Meta is working. q cancels." } else if wstep == 5 { "Approving exactly one reboot." }
                            else { "Working on the router; no model call." });
                    } else { notice.append("Could not start the step."); }
                } else if wstep == 7 {
                    var net = WizardNetwork {};
                    let loaded = load_wizard_network(net);
                    if (!loaded || key == 'c' || net.upload_kbps == 0) && !setup_tune_inputs(net) {
                        notice.append("Shaping inputs cancelled or out of range; nothing written.");
                    } else if !confirm_qos_apply(wd, net) { notice.append("Nothing written."); }
                    else {
                        job = []; job.append("qos:"); job.append(setup_qos_profile(net));
                        if ct_setup_job_start(job) == 0 {
                            busy = true; details = []; wizard_job = 7;
                            notice.append("Applying the queue and reading it back.");
                        } else { notice.append("Could not start the apply."); }
                    }
                } else if wstep == 8 && evidence.len == 0 {
                    var net = WizardNetwork {};
                    let loaded = load_wizard_network(net);
                    if (!loaded || key == 'c' || net.target.len == 0 || net.load_path.len == 0) && !setup_measure_inputs(net) {
                        notice.append("Measurement target cancelled or invalid; nothing measured.");
                    } else if net.target.len == 0 || net.load_path.len == 0 { notice.append("A target and an upload path are both required.");
                    } else if !confirm_measure(net) { notice.append("Nothing measured."); }
                    else {
                        job = []; job.append("measure:"); job.append(net.target); job.append("\n"); job.append(net.load_path);
                        if ct_setup_job_start(job) == 0 {
                            busy = true; details = []; wizard_job = 8;
                            notice.append("Measuring: an idle window, then the upload window.");
                        } else { notice.append("Could not start the measurement."); }
                    }
                } else if wstep == 8 {
                    job = []; job.append("qualify:"); job.append(evidence);
                    if !confirm_qualify(evidence) { notice.append("Not qualified; the measurement is kept."); }
                    else if ct_setup_job_start(job) == 0 { busy = true; details = []; wizard_job = 12; }
                    else { notice.append("Could not start qualification."); }
                } else {
                    var resident = ResidentStatus {};
                    if setup_resident_status(resident) && resident.valid && resident.phase == "monitoring" {
                        notice.append("The resident monitor is running; this screen refreshes every second.");
                    } else {
                        let pid = setup_background_monitor();
                        if pid > 0 { notice.append(str("Monitor started (pid ", pid, "); it keeps running after this screen closes.")); }
                        else { notice.append("Monitor not started: cancelled, already running, or unverified. No router changes."); }
                    }
                }
                dirty = true;
                }
            } else if wizard && key == 27 {
                // Esc ends the program on a second press: one stray Esc on a
                // failure screen must not throw away the reason shown there.
                // The panels are a debugging surface, not where leaving lands.
                if esc_armed { break; }
                esc_armed = true; dirty = true;
                notice = []; notice.append("Press Esc again to quit. Progress is saved; `continuum` resumes here.");
            } else if wizard && key == 'p' && step_failed {
                // Takeover of an already-configured unit: the owner supplies the
                // admin password the router already uses. It is read hidden,
                // stored where the adapter looks it up, and proven by a
                // protected read -- no write, no rename, no reboot. Offering
                // this only after a failed step means the slot it overwrites
                // holds a credential that just failed to answer.
                var adopt = DeviceState {};
                if device_saved(setup_directory(), adopt) && adopt.connection.admin_ref.len > 0 &&
                    !adopt.runtime_verified && !settled {
                    var secret: u8[..256] = [0; 256]; var sn: i64 = 0;
                    if ct_setup_secret("Router admin password", secret, sn) != 0 || sn <= 0 || sn > 256 {
                        notice.append("Password entry cancelled; nothing changed.");
                    } else if ct_setup_vault_store(adopt.connection.admin_ref, secret[..sn]) != 0 {
                        notice.append("Could not store the password in the OS vault; nothing changed.");
                    } else {
                        job = []; job.append("device-inspect");
                        if ct_setup_job_start(job) == 0 {
                            busy = true; details = []; wizard_job = 9;
                            notice.append("Checking that password against the router...");
                        } else { notice.append("Could not start the check."); }
                    }
                    var z: i64 = 0; while z < sn { secret[z] = 0; z += 1; }
                    dirty = true;
                }
            } else if wizard && key == 'a' {
                wizard = false; notice = []; details = []; step_failed = false; show_raw = false; dirty = true;
            } else if wizard && key == 'i' && step_failed {
                show_raw = !show_raw; dirty = true;
            }
            // Nothing else acts while the wizard is on screen: a key that the
            // wizard does not offer must never start a monitor, restore or
            // reboot behind an instruction the owner was reading.
            else if wizard { }
            // Numbered sections are the primary navigation; legacy letters stay.
            else if key >= '1' && key <= '5' {
                screen = key - '1'; details = []; notice = []; scroll = 0; dirty = true; wizard = false;
            } else if key == '?' { screen = 5; details = []; notice = []; scroll = 0; dirty = true; wizard = false; }
            else if key == 'm' {
                let result = ct_tui_key_setup(); verified = false;
                notice = [];
                notice.append(if result == 1 { "Key saved in Keychain; provider not tested." }
                    else if result == 2 { "Key set for this session only; provider not tested." }
                    else if result == -4 { "Key entry cancelled; previous key unchanged." }
                    else { "Key rejected or secure storage failed; previous key unchanged." });
                dirty = true;
            } else if key == 'c' {
                notice = [];
                if edit_setup_settings(cfg) { verified = false; notice.append("Model settings saved; provider not tested for these models."); }
                else { notice.append("Settings cancelled, invalid, or unwritable; previous settings unchanged."); }
                dirty = true;
            } else if key == 'f' {
                notice = [];
                notice.append(if edit_owner_settings() { "Owner permissions saved; no model or device operation dispatched." }
                    else { "Permissions cancelled, invalid, busy or changed concurrently; previous permissions unchanged." });
                dirty = true;
            } else if key == 'g' { screen = 3; details = []; notice = []; scroll = 0; dirty = true; }
            else if key == 'o' { screen = 2; details = []; notice = []; scroll = 0; dirty = true; }
            else if key == 'p' {
                let selected = setup_select_device(); notice = [];
                if selected { settled = false; tuned = false; qos_checked = false; evidence = []; }
                notice.append(if selected { "Device selected; no enrollment or write dispatched." }
                    else { "Selection cancelled, invalid or binding already in use; target unchanged." });
                details = []; screen = 2; scroll = 0; dirty = true;
            } else if key == 27 {
                // Back to the wizard, with a fresh host snapshot: a discovery or
                // binding done in the panels must be visible to the steps.
                wizard = true; screen = 2; details = []; notice = []; scroll = 0;
                network = discover_host(); observed_wall_ms = time_ns() / 1000000; dirty = true;
            } else if key == 't' {
                notice = []; scroll = 0;
                if !meta_credentials_available(cfg) { notice.append("Set MODEL_API_KEY with m first; no provider call made."); }
                else {
                    var message: u8[..1024] = [0; 1024]; var n: i64 = 0;
                    if ct_setup_input("Message to Meta (no passwords)", "", message, n) != 0 || n <= 0 || n > 1024 {
                        notice.append("Message cancelled or over bound; no provider call.");
                    } else {
                        job = []; job.append("talk:"); job.append(message[..n]);
                        if ct_setup_job_start(job) == 0 {
                            busy = true; screen = 0; details = [];
                            details.append("Meta is handling your message with the saved device permissions.\n");
                            notice.append("Conversation uses the configured call budget; no new authority granted.");
                        } else { notice.append("Could not start conversation; no dispatch."); }
                    }
                }
                dirty = true;
            } else if screen == 3 && (key == 13 || key == 10 || key == 'x' || key == 'E' || key == 'R') {
                details = [];
                notice = [];
                let operation = if key == 13 || key == 10 { "read_program" } else if key == 'x' { "disable_program" }
                    else if key == 'E' { "enable_program" } else { "reconcile_program" };
                if setup_program_action(operation, details) { notice.append("Program action completed; inspect the receipt."); }
                else { notice.append("Program action refused or cancelled; registry unchanged unless receipt says otherwise."); }
                screen = 3; scroll = 0; dirty = true;
            } else if screen == 2 && (key == 13 || key == 10) {
                // Enter advances the lifecycle: bind -> enroll -> setup, and the
                // reset recovery. Each step keeps its own confirm frame.
                notice = [];
                var current = DeviceState {};
                let unbound = !device_saved(setup_directory(), current) || current.candidate_id.len == 0;
                if unbound {
                    let gateway = setup_gateway_candidate(network);
                    if network.len == 0 { notice.append("No local observation yet; press d to discover this host."); }
                    else if gateway.len == 0 { notice.append("No single default-route candidate; press p to choose the router."); }
                    else if !confirm_bind(gateway, "") { notice.append("Binding cancelled; target unchanged."); }
                    else if device_select(setup_directory(), network, gateway, "Continuum", 80, false) {
                        notice.append("Bound. Press Enter again to enroll this router.");
                    } else { notice.append("Binding refused or the candidate is no longer observed; press d, then p."); }
                } else if current.phase == "selected" {
                    job = []; job.append("device-enroll");
                    if !confirm_device_job(job) { notice.append("Enrollment cancelled; no dispatch."); }
                    else if ct_setup_job_start(job) == 0 {
                        busy = true; details = []; details.append("Enrolling the selected unit. q cancels.\n");
                        notice.append("The ceremony creates the admin credential; no reboot or reset approved.");
                    } else { notice.append("Could not start enrollment; no dispatch."); }
                } else if current.phase == "enrolled" {
                    let choice = setup_next_menu(current);
                    if choice == '1' {
                        job = []; job.append("device-enroll");
                        var stem: u8[..27] = "Continuum";
                        if current.connection.ssid_stem.len > 0 { stem = current.connection.ssid_stem; }
                        if !confirm_device_job(job) { notice.append("Re-enrollment cancelled; binding unchanged."); }
                        else if device_select(setup_directory(), network, current.candidate_id, stem,
                                current.connection.port, true) {
                            if ct_setup_job_start(job) == 0 {
                                busy = true; details = []; details.append("Re-enrolling after a factory reset. q cancels.\n");
                                notice.append("The stale binding was discarded; the ceremony runs on the same candidate.");
                            } else { notice.append("Could not start enrollment; no dispatch."); }
                        } else { notice.append("Candidate no longer observed; press d, then p."); }
                    } else if choice == '2' {
                        job = []; job.append("device-setup");
                        if !meta_credentials_available(cfg) { notice.append("Set MODEL_API_KEY with m first; no device or model dispatch."); }
                        else if !confirm_device_job(job) { notice.append("Device operation cancelled; no dispatch."); }
                        else if ct_setup_job_start(job) == 0 {
                            busy = true; details = []; details.append("Meta is choosing work on the selected device. q cancels.\n");
                            notice.append("Router reboot is NOT approved by this step.");
                        } else { notice.append("Could not start device operation; no dispatch."); }
                    } else { notice.append("Next step cancelled; nothing dispatched."); }
                } else {
                    notice.append("Enter advances binding, enrollment and setup; use e, b or r in this phase.");
                }
                screen = 2; scroll = 0; dirty = true;
            } else if key == 'i' || key == 'u' || key == 'n' || key == 'e' || key == 'r' || key == 'b' {
                var selected = DeviceState {}; notice = [];
                if !device_saved(setup_directory(), selected) || selected.candidate_id.len == 0 {
                    notice.append("Select a device first; no operation dispatched.");
                } else {
                    job = []; job.append(if key == 'i' { "device-inspect" } else if key == 'u' { "device-authorize" }
                        else if key == 'n' { "device-enroll" }
                        else if key == 'e' { "device-setup" } else if key == 'b' { "device-reboot" } else { "device-restore" });
                    if key == 'e' && !meta_credentials_available(cfg) { notice.append("Set MODEL_API_KEY with m first; no device or model dispatch."); }
                    else if key != 'i' && !confirm_device_job(job) { notice.append("Device operation cancelled; no dispatch."); }
                    else if ct_setup_job_start(job) == 0 {
                        busy = true; details = []; details.append("Selected device operation running. q cancels; uncertain effects are not replayed.\n");
                        notice.append(if key == 'e' { "Meta is choosing work on the selected device. Router reboot is NOT approved." }
                            else if key == 'b' { "Dispatching the separately approved router reboot only." }
                            else { "Operating on the saved device only; no Meta call or router reboot." });
                    } else { notice.append("Could not start device operation; no dispatch."); }
                }
                screen = 2; scroll = 0; dirty = true;
            } else if key == 's' {
                let pid = setup_background_monitor(); notice = [];
                if pid > 0 { notice.append(str("Monitor started (pid ", pid, "); continues after this UI closes.")); }
                else { notice.append("Monitor start cancelled, already running, or unverified; inspect service/status.json. No router changes."); }
                dirty = true;
            } else if key == 'h' { screen = 0; notice = []; scroll = 0; dirty = true; }
            else if key == 261 || key == 'k' { if scroll > 0 { scroll -= 1; } dirty = true; }
            else if key == 262 || key == 'j' { scroll += 1; dirty = true; }
            else if key == 258 || key == 'K' { if scroll > 9 { scroll -= 10; } else { scroll = 0; } dirty = true; }
            else if key == 259 || key == 'J' { scroll += 10; dirty = true; }
            else if key == 'd' || key == 'a' || key == 'v' || key == 'l' {
                job = []; job.append(if key == 'd' { "discover" } else if key == 'a' { "agent" } else if key == 'v' { "test-key" } else { "lab" });
                notice = []; scroll = 0;
                if key != 'd' && !meta_credentials_available(cfg) { notice.append("Set MODEL_API_KEY with m first; no provider call made."); }
                else if key != 'd' && !confirm_setup_job(cfg, job) { notice.append("Meta request cancelled; no provider call made."); }
                else if ct_setup_job_start(job) == 0 {
                    busy = true;
                    screen = if key == 'd' { 1 } else { 0 };
                    details = []; details.append("Working. q cancels this job and exits.\nNo automatic retries or background model calls.\n");
                    notice.append(if key == 'd' { "Reading local interfaces/routes; no active scan or Meta call." } else { "Running requested bounded job. q cancels; no changes to a physical router." });
                } else { notice.append("Could not start job; no work dispatched."); }
                dirty = true;
            }
        }
        // A rebooting router is probed on a schedule, one protected read at a time.
        if watching && !busy && time_ns() / 1000000 >= watch_next {
            job = []; job.append("device-inspect");
            if ct_setup_job_start(job) == 0 { busy = true; wizard_job = 10; }
            else { watch_next = time_ns() / 1000000 + 2000; }
        }
        if busy {
            var output: u8[..32768] = [0; 32768]; var n: i64 = 0;
            let result = ct_setup_job_poll(output, n);
            if result != 1 {
                busy = false; dirty = true;
                // The role belongs to the job that just finished, not to whatever
                // runs next: capture it and clear it for the following dispatch.
                let finished = wizard_job; wizard_job = 0;
                var text: u8[>..] = [];
                if n > 0 && n <= output.len { text.append(output[..n]); }
                if wizard && finished > 0 {
                    // Stay in the wizard: every outcome is read from the job's
                    // receipt or the durable device record, never assumed.
                    let ok = result == 0;
                    let now = time_ns() / 1000000;
                    var after = DeviceState {};
                    device_saved(setup_directory(), after);
                    screen = 2; show_raw = false; fail_reason = [];
                    if finished != 10 { notice = []; details = []; }
                    step_failed = !ok;
                    if finished == 2 {
                        if ok || setup_contains(text, "secured bands") { settled = true; }
                    } else if finished == 9 {
                        if ok { settled = true; notice.append("Password accepted; the router is now bound under it."); }
                    } else if finished == 14 {
                        let line = setup_line_with(text, "META_MODELS ");
                        if ok && line.len > 12 {
                            models = [];
                            for b in line[12..] { if b == ' ' { models.push(10); } else if b > 32 { models.push(b); } }
                            models.push(10);
                            pick_pending = true;
                        } else {
                            step_failed = true;
                            fail_reason.append(if setup_contains(text, "status=401") || setup_contains(text, "status=403") {
                                "the provider refused this key while listing its models (no tokens were used)" }
                                else { "could not read this key's model list from the provider" });
                        }
                    } else if finished == 3 {
                        verified = ok;
                        if ok { details.append("KEY        accepted by the provider (one connection-test call)\n"); }
                    } else if finished == 4 {
                        let applied = after.phase == "baseline_applied" && after.runtime_verified && after.recovery_verified;
                        if ok && !applied {
                            step_failed = true;
                            fail_reason.append("Meta finished without a verified owned baseline on the router; nothing counts until the router's receipt shows one");
                        } else if ok {
                            var doc: json::Node[>..] = []; var decoded: u8[>..] = [];
                            let line = setup_line_with(text, "\"summary\"");
                            let root, err = json::parse(line, doc, decoded);
                            let summary, s = json::as_string(json::member(root, "summary"));
                            // The receipt first: it is what counts, and it must stay on
                            // screen. Meta's own report follows, cut at a line end.
                            details.append("RECEIPT    baseline applied; runtime and recovery verified by the router\n");
                            if s {
                                var cut: i64 = summary.len;
                                if cut > 1100 { cut = 1100; while cut > 0 && summary[cut - 1] != 10 { cut -= 1; } }
                                details.append("\nMETA SAID\n"); details.append(summary[..cut]); details.append("\n");
                            }
                        }
                    } else if finished == 5 {
                        if after.phase == "reboot_pending" {
                            // Requested: from here the router's return decides.
                            step_failed = false; watching = true; watch_down = false;
                            watch_start = now; watch_next = now + 2000;
                            notice.append("Reboot requested. Waiting for the router to stop answering and come back.");
                            if !ok { details.append("The request lost its answer, as a router going down mid-request does.\n"); }
                        }
                    } else if finished == 10 {
                        step_failed = false;
                        if ok && (watch_down || now - watch_start >= 300000) {
                            watching = false; notice = [];
                            notice.append(if watch_down { "The router stopped answering and is back. Press Enter to verify persistence." }
                                else { "The router never stopped answering in 5 minutes; verification checks the boot identity anyway." });
                        } else if !ok && now - watch_start >= 600000 {
                            watching = false; step_failed = true; notice = [];
                            fail_reason.append("the router has not answered for 10 minutes after the reboot request");
                        } else {
                            if !ok { watch_down = true; }
                            watch_next = now + 2000;
                            dirty = !ok || watch_down;
                        }
                    } else if finished == 6 {
                        if ok && after.persistence_verified {
                            details.append("PERSIST    verified by the router: new boot identity, owned baseline in force\n");
                        } else { step_failed = true; }
                    } else if finished == 11 {
                        if ok {
                            var doc: json::Node[>..] = []; var decoded: u8[>..] = [];
                            let line = setup_line_with(text, "\"qos_status\"");
                            let root, err = json::parse(line, doc, decoded);
                            let qdisc, q = json::as_string(json::member(root, "qdisc"));
                            let iface, i = json::as_string(json::member(root, "qos_interface"));
                            if q && i {
                                qos_checked = true;
                                details.append(str("PREFLIGHT  tc present; ", iface, " root queue now: ", qdisc, "\n"));
                            } else { step_failed = true; fail_reason.append("qos_preflight_receipt_unreadable"); }
                        }
                    } else if finished == 7 {
                        if ok {
                            var doc: json::Node[>..] = []; var decoded: u8[>..] = [];
                            let line = setup_line_with(text, "\"qos_applied\"");
                            let root, err = json::parse(line, doc, decoded);
                            let verified_qos, v = json::as_bool(json::member(root, "qos_verified"));
                            let rate, r = json::as_string(json::member(root, "rate_readback"));
                            let mode, m = json::as_string(json::member(root, "qos_mode"));
                            let kbps, k = json::as_i64(json::member(root, "bandwidth_kbps"));
                            let iface, i = json::as_string(json::member(root, "qos_interface"));
                            let shown, a = json::as_string(json::member(root, "after_qdisc"));
                            if v && verified_qos && r && rate == "verified" && m && k && i && a {
                                tuned = true;
                                details.append(str("QDISC      ", mode, " ", kbps, " kbit/s on ", iface, "\nREADBACK   verified on the router: ", shown, "\n"));
                            } else { step_failed = true; fail_reason.append("qos_readback_unverified"); }
                        }
                    } else if finished == 8 {
                        let marker = setup_line_with(text, "MEASURE_EVIDENCE ");
                        var doc: json::Node[>..] = []; var decoded: u8[>..] = [];
                        let line = setup_line_with(text, "\"verdict\"");
                        let root, err = json::parse(line, doc, decoded);
                        let verdict, vd = json::as_string(json::member(root, "verdict"));
                        let body = json::member(root, "evidence");
                        let idle, il = json::as_i64(json::member(body, "idle_samples"));
                        let loaded, ld = json::as_i64(json::member(body, "loaded_samples"));
                        let moved, mv = json::as_i64(json::member(body, "load_bytes"));
                        if ok && marker.len > 17 && vd && verdict == "claimable" && il && ld && mv {
                            details.append(str("MEASURED   claimable: ", idle, " idle and ", loaded, " loaded samples, ", moved,
                                " bytes uploaded\nEVIDENCE   ", marker[17..], "\n"));
                            evidence = []; evidence.append(marker[17..]);
                        } else { step_failed = true; }
                    } else if finished == 12 {
                        evidence = [];
                        if ok { notice.append("LOAD gate recorded from this checkout's measurement."); }
                    } else if finished == 13 {
                        if ok {
                            tuned = false; qos_checked = false; evidence = [];
                            notice.append("Shaping removed; the kernel default queue is back. TUNE and MEASURE re-open.");
                        }
                    }
                    if step_failed {
                        if fail_reason.len == 0 { fail_reason = setup_failure_reason(text); }
                        if setup_contains(text, "protected_authentication_refused") {
                            fail_reason = [];
                            fail_reason.append("the router no longer accepts Continuum's admin password; it was probably reset to factory settings");
                        }
                        details = []; details.append("STEP FAILED\n\n"); details.append(text);
                    }
                } else {
                    notice = [];
                    notice.append(if result == 0 { "Requested job completed." } else { "Job failed; inspect details. No automatic retry." });
                    if text.len > 0 {
                        if job == "discover" && result == 0 { screen = 1; network = []; network.append(text); observed_wall_ms = time_ns() / 1000000; }
                        else if job.len >= 7 && job[..7] == "device-" {
                            screen = 6;
                            details = []; setup_device_view(details);
                            if job == "device-setup" || job == "device-enroll" || result != 0 {
                                details.append("\nOPERATION RECEIPT\n"); details.append(text);
                            }
                        } else {
                            screen = 6;
                            details = [];
                            var doc: json::Node[>..] = []; var decoded: u8[>..] = [];
                            let root, err = json::parse(text, doc, decoded);
                            let summary, has_summary = json::as_string(json::member(root, "summary"));
                            if has_summary {
                                details.append(if job.len > 5 && job[..5] == "talk:" { "META / OWNER CONVERSATION\n\n" }
                                    else { "META / READ-ONLY ASSESSMENT\n\n" }); details.append(summary);
                                details.append("\n\nModel text is not evidence or a new grant of authority.\n");
                                let reason, r = json::as_string(json::member(root, "reason"));
                                if r && reason.len > 0 { details.append(str("\n", reason, "\n")); }
                            } else { details.append(text); }
                            if job == "test-key" { verified = result == 0; }
                        }
                    }
                }
            }
        }
        // Resize is an event, not a periodic repaint or animation.
        if key == 256 || (key == 0 && wizard && ready_view && !busy) { dirty = true; }
        if key == 0 && wizard && seeking && !busy && time_ns() / 1000000 >= seek_next {
            network = discover_host(); labels = setup_identify(network); observed_wall_ms = time_ns() / 1000000;
            seek_next = observed_wall_ms + 2000; dirty = true;
        }
    }
    ct_tui_close();
    return true;
}
