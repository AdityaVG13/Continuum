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
extern fn ct_setup_job_start(mode: const u8[:]) -> i32;
extern fn ct_setup_job_poll(out: u8[:], length: i64&) -> i32;

fn setup_defaults() -> ModelConfig {
    return ModelConfig {
        base_url: "https://api.meta.ai/v1", controller_model: "muse-wonder-1.0",
        task_model: "muse-wonder-1.0", request_timeout_ms: 30000,
        max_output_tokens: 2048, max_tool_rounds: 4,
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
    let known: const u8[:][..5] = ["controller_model", "task_model", "max_output_tokens", "max_tool_rounds", "request_timeout_ms"];
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
    text.append("}\n");
    return write_file_atomic(str(directory, "/settings.json"), text);
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
    frame.append(str("Model     ", cfg.controller_model, "\n"));
    if job == "test-key" { frame.append("Budget    One connection-test call, up to 256 output tokens.\n"); }
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
        "\nREADY        false (network-load tuning unqualified)\nReason       ", d.reason, "\n\n"));
    out.append("[i] Protected inspection  [u] Authorize credential access\n[e] Meta setup / resume  [r] Restore owned baseline\n[t] Talk to Meta  [b] Approve one router reboot\n\nService restarts are allowed within standing device permission.\nRouter reboot, reset and firmware changes are never implied.\nRouted-load tuning and general controller crash recovery remain unqualified.\n");
}
fn confirm_device_job(job: const u8[:]) -> bool {
    var frame: u8[>..] = [];
    frame.append("CONTINUUM / DEVICE PERMISSION\n--------------------------------------------------------------------------\n");
    var d = DeviceState {};
    if !device_saved(setup_directory(), d) || d.candidate_id.len == 0 { return false; }
    frame.append(str("Selected  ", d.candidate_id, ":", d.connection.port, "\nPhase     ", d.phase,
        "\nIdentity  ", d.productid, " / ", d.mac, "\n"));
    if job == "device-setup" {
        frame.append("\nGrant Meta standing permission for this selected device?\nMeta chooses setup and supported reversible optimization operations.\nNew factory enrollment may rotate credentials, rename Wi-Fi and disconnect\nthis host. Service restarts and verified optional-service changes are allowed.\nThis uses the configured model/call budget. Uncertain effects are reconciled.\nNO router/device reboot, reset, firmware update or destructive action is approved.\nCore routing/security settings are outside the current cleanup capability.\n");
    } else if job == "device-reboot" {
        frame.append("\nApprove ONE router/device reboot NOW for this selected device?\nThis interrupts the network and ongoing work. No schedule is created.\nStanding setup permission and Meta messages cannot approve this operation.\nA failed/uncertain request is verified, never automatically repeated.\n");
    } else if job == "device-restore" {
        frame.append("\nRestore only the selected device's owned sharing-service baseline?\nA different device, changed firmware or intervening owner setting is refused.\n");
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
    frame.append("i/u/e/r/b   Inspect / authorize / Meta setup / restore / one reboot (device screen)\n");
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
        frame.append("[p] Select [i] Inspect [u] Authorize [e] Setup [r] Restore [b] Reboot\n[m] Meta key  [c] Models/budget  [f] Permissions  [t] Talk  [s] Monitor\n");
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
    var network: u8[>..] = [];
    var observed_wall_ms: i64 = 0;
    var details: u8[>..] = [];
    var screen: i64 = 0; var scroll: i64 = 0;
    var busy = false; var dirty = true; var verified = false;
    var job: u8[>..] = [];
    while true {
        if dirty {
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
        let key = ct_tui_key(if busy { 100 } else { -1 });
        if key == 'q' || key == 3 || key < 0 { ct_tui_job_cancel(); break; }
        // A job owns the current snapshot. Do not replace settings/credentials
        // underneath it; q cancels its whole child process group.
        if !busy {
            // Numbered sections are the primary navigation; legacy letters stay.
            if key >= '1' && key <= '5' {
                screen = key - '1'; details = []; notice = []; scroll = 0; dirty = true;
            } else if key == '?' { screen = 5; details = []; notice = []; scroll = 0; dirty = true; }
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
                notice.append(if selected { "Device selected; no enrollment or write dispatched." }
                    else { "Selection cancelled, invalid or binding already in use; target unchanged." });
                details = []; screen = 2; scroll = 0; dirty = true;
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
            } else if key == 'i' || key == 'u' || key == 'e' || key == 'r' || key == 'b' {
                var selected = DeviceState {}; notice = [];
                if !device_saved(setup_directory(), selected) || selected.candidate_id.len == 0 {
                    notice.append("Select a device first; no operation dispatched.");
                } else {
                    job = []; job.append(if key == 'i' { "device-inspect" } else if key == 'u' { "device-authorize" }
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
        if busy {
            var output: u8[..32768] = [0; 32768]; var n: i64 = 0;
            let result = ct_setup_job_poll(output, n);
            if result != 1 {
                busy = false; dirty = true; notice = [];
                notice.append(if result == 0 { "Requested job completed." } else { "Job failed; inspect details. No automatic retry." });
                if n > 0 && n <= output.len {
                    if job == "discover" && result == 0 { screen = 1; network = []; network.append(output[..n]); observed_wall_ms = time_ns() / 1000000; }
                    else if job.len >= 7 && job[..7] == "device-" {
                        screen = 6;
                        details = []; setup_device_view(details);
                        var selected = DeviceState {};
                        if job == "device-setup" || result != 0 {
                            details.append("\nOPERATION RECEIPT\n"); details.append(output[..n]);
                        }
                    } else {
                        screen = 6;
                        details = [];
                        var doc: json::Node[>..] = []; var decoded: u8[>..] = [];
                        let root, err = json::parse(output[..n], doc, decoded);
                        let summary, has_summary = json::as_string(json::member(root, "summary"));
                        if has_summary {
                            details.append(if job.len > 5 && job[..5] == "talk:" { "META / OWNER CONVERSATION\n\n" }
                                else { "META / READ-ONLY ASSESSMENT\n\n" }); details.append(summary);
                            details.append("\n\nModel text is not evidence or a new grant of authority.\n");
                            let reason, r = json::as_string(json::member(root, "reason"));
                            if r && reason.len > 0 { details.append(str("\n", reason, "\n")); }
                        } else { details.append(output[..n]); }
                        if job == "test-key" { verified = result == 0; }
                    }
                }
            }
        }
        // Resize is an event, not a periodic repaint or animation.
        if key == 256 { dirty = true; }
    }
    ct_tui_close();
    return true;
}
