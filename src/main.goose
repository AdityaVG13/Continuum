import .contracts;
import .meta_provider;
import .telemetry;
import .guardian;
import .actuator;
import .task_runner;
import .events;
import .transport;
import .controller;
import .policy;
import .daemon;
import .setup;
import .continuity;
import .service;
import .device;
import .device_agent;
import .takeover;
import .measure;
import os;

// The status entrypoint reports each module's implementation state. Calling
// the operations below exercises their types; unconfigured calls fail closed
// before any network or mutation.
fn show_status() {
    let cfg = continuum::ModelConfig {};
    let request = continuum::ActionRequest {};
    let admission = continuum::admit_action(request, continuum::Observation {}, continuum::ActionProfile {}, 0);
    print("Continuum: --loop runs a supervised Meta controller and validated Meta workload through one selected backend. Observations are synthetic; router writes are loopback-lab only. MODEL_API_KEY is required.");
    print("Device lifecycle: --device-select binds an observed owner-selected target; --device-step setup --execute grants standing device permission to Meta; --talk carries owner dialogue; --serve uses the same guarded capabilities. Router reboots need --device-step reboot --execute. Network qualification and autonomous physical tuning remain closed.");
    print("Meta provider: ", continuum::status_name(continuum::request_meta(cfg, continuum::ModelRequest {}).outcome.status));
    print("Meta continuation: ", continuum::status_name(continuum::submit_tool_result(cfg, "", "", "", "", "", "").outcome.status));
    print("Meta controller: ", continuum::status_name(continuum::controller_tick(continuum::ControllerState {}, cfg).status));
    print("Observation tool: ", continuum::status_name(continuum::read_observation("").outcome.status));
    print("Profiles: ", continuum::status_name(continuum::list_profiles("").outcome.status));
    print("Guardian: ", continuum::status_name(admission.outcome.status));
    print("Apply: ", continuum::status_name(continuum::apply_profile(request, admission).outcome.status));
    print("Restore: ", continuum::status_name(continuum::restore_profile(request, admission).outcome.status));
    print("Action result: ", continuum::status_name(continuum::read_action_result("").outcome.status));
    print("Watchdog: ", continuum::status_name(continuum::reconcile_expired_lease("", 0).outcome.status));
    print("Task context: ", continuum::status_name(continuum::read_task_context("").outcome.status));
    let task = continuum::run_meta_task(continuum::TaskContext {}, cfg);
    print("Meta task: ", continuum::status_name(task.outcome.status));
    print("Task validation: ", continuum::status_name(continuum::validate_task_result(continuum::TaskContext {}, task).outcome.status));
    print("Event journal: ", continuum::status_name(continuum::append_event(continuum::Event {}).status));
    print("Task continuity: completed artifacts are atomically committed; --resume revalidates exact current inputs without model calls");
    print("Optional RaptorQ: ", continuum::status_name(continuum::transfer_evidence_object(continuum::ObjectTransfer {}).status));
}

fn loop_config(key_env: const u8[:]) -> continuum::ModelConfig {
    var cfg = continuum::setup_defaults();
    if !continuum::load_setup_settings(cfg) {
        print("MODEL_CONFIG_FAILED saved settings invalid; repair with continuum --tui");
        exit(1);
    }
    var model: u8[>..] = [];
    if env("META_CONTROLLER_MODEL", model) && model.len > 0 && model.len <= 128 { cfg.controller_model = model; }
    var task: u8[>..] = [];
    if env("META_TASK_MODEL", task) && task.len > 0 && task.len <= 128 { cfg.task_model = task; }
    cfg.api_key_env_name = key_env;
    return cfg;
}

// One model loop, one selected actuator. No mechanical router mutation
// runs beside it. Physical targets remain closed until live collection
// and independent crash recovery are available for the device adapter.
fn show_loop(run_id: const u8[:], resumed: bool) {
    if !continuum::valid_id(run_id, 59) {
        print("MODEL_LOOP_FAILED run identity must be 1..59 safe identifier bytes"); exit(2);
    }
    let cfg = loop_config("MODEL_API_KEY");
    let directory = continuum::setup_directory();
    if directory.len == 0 { print("MODEL_LOOP_FAILED private state directory unavailable"); exit(1); }
    let path = str(directory, "/runs/", run_id, ".json");
    let context = continuum::release_task_context(run_id);
    if resumed {
        let task = continuum::resume_task(path, context, cfg);
        let restored = continuum::ParticipantReport {
            outcome: task.outcome, run_id: run_id, task: task,
            checkpoint_path: path, resumed: true,
        };
        print(continuum::session_record(restored));
        if !task.committed { exit(1); }
        return;
    }
    if file_exists(path) {
        print("MODEL_LOOP_FAILED immutable run already exists; use --resume or choose a new identity"); exit(1);
    }
    if !continuum::meta_credentials_available(cfg) {
        print("MODEL_LOOP_FAILED MODEL_API_KEY is not set; no model call or router mutation");
        exit(1);
    }
    // Freeze task identity before either model runs. A changed source/prompt
    // during a paid request cannot be committed under the earlier identity.
    let binding = continuum::task_binding(context, cfg);
    if !binding.ok { print("MODEL_LOOP_FAILED task input binding unavailable"); exit(1); }
    var router_host: u8[>..] = [];
    if env("ROUTER_HOST", router_host) && router_host.len > 0 {
        var port_text: u8[>..] = [];
        var port: i64 = 0;
        if !(env("ROUTER_PORT", port_text) && parse_i64_digits(port_text, port))
                || !continuum::controller_select_router(router_host, port) {
            print("MODEL_LOOP_FAILED loopback lab router target or credentials invalid");
            exit(1);
        }
    } else if !continuum::controller_select_sim() {
        print("MODEL_LOOP_FAILED unresolved router lease");
        exit(1);
    }
    var case_name: u8[>..] = [];
    if !(env("CONTINUUM_CASE", case_name) && case_name.len > 0) {
        case_name = []; case_name.append("queue");
    }
    var live = continuum::run_protected_task(run_id, case_name, cfg, false);
    live.checkpoint_path = path;
    // Runtime success includes resolving the owned intervention. A checkpoint
    // never replays a route change or conceals an outstanding lease.
    if live.outcome.status == continuum::Status.Completed {
        let committed = continuum::checkpoint_run(path, context, cfg, binding, live.task);
        if committed.committed { live.task = committed; }
        else { live.outcome = committed.outcome; }
    }
    print("PARTICIPANT case=", case_name, " model_calls=", live.model_calls,
        " applied=", live.applied, " restored=", live.restored,
        " abstained=", live.abstained, " profile=", live.profile_after);
    print(continuum::session_record(live));
    if live.outcome.status != continuum::Status.Completed || !live.task.committed {
        print("MODEL_LOOP_FAILED ", live.outcome.message); exit(1);
    }
    print("MODEL_LOOP_COMPLETED observation_provenance=synthetic task_validated=", live.task.independently_validated,
        " committed=true run_id=", run_id);
}

fn parse_i64_digits(text: const u8[:], out: i64&) -> bool {
    if text.len == 0 || text.len > 5 {
        return false;
    }
    var n: i64 = 0;
    var i: i64 = 0;
    while i < text.len {
        let b = text[i];
        if b < '0' || b > '9' {
            return false;
        }
        n = n * 10 + (b - '0');
        i += 1;
    }
    out = n;
    return true;
}

fn print_qos(on: bool, rate: i64, rev: i64) {
    print("qos=", if on { "on" } else { "off" }, " rate_mbit=", rate, " revision=", rev);
}

fn router_usage() {
    print("Usage: continuum router status");
    print("       continuum router apply <profile> <rate_mbit>");
    print("       continuum router restore");
    print("ROUTER_HOST, ROUTER_PORT and ROUTER_PASSWORD select the router. status prints the router's qos read. apply leaves an owned profile. restore undoes it.");
}

// Operator tuner. Fails closed before any socket if the target or the
// password is missing. The password itself stays in the native layer.
fn show_router() {
    let argv = args();
    if argv.len < 3 {
        router_usage();
        exit(2);
    }
    let cmd = argv[2];
    var rate: i64 = 0;
    if cmd == "status" || cmd == "restore" {
        if argv.len != 3 {
            router_usage();
            exit(2);
        }
    } else if cmd == "apply" {
        if argv.len != 5 || !parse_i64_digits(argv[4], rate) || rate < 1 || rate > 1000 {
            router_usage();
            exit(2);
        }
    } else {
        router_usage();
        exit(2);
    }
    var host: u8[>..] = [];
    if !(env("ROUTER_HOST", host) && host.len > 0) {
        print("ROUTER_FAILED router host missing");
        exit(1);
    }
    var port_text: u8[>..] = [];
    var port: i64 = 0;
    if !(env("ROUTER_PORT", port_text) && parse_i64_digits(port_text, port) && port > 0 && port <= 65535) {
        print("ROUTER_FAILED router port invalid");
        exit(1);
    }
    var pw: u8[>..] = [];
    if !(env("ROUTER_PASSWORD", pw) && pw.len > 0) {
        print("ROUTER_FAILED router credential refused");
        exit(1);
    }
    if cmd == "status" {
        let view = continuum::router_status(host, port);
        if !view.ok {
            print("ROUTER_FAILED ", view.outcome.message);
            exit(1);
        }
        print_qos(view.qos_on, view.rate_mbit, view.revision);
        return;
    }
    if cmd == "apply" {
        let view = continuum::router_apply(host, port, argv[3], rate);
        if !view.ok {
            print("ROUTER_FAILED ", view.outcome.message);
            exit(1);
        }
        print("applied profile=", argv[3], " rate_mbit=", view.rate_mbit, " revision_before=", view.revision_before, " revision_after=", view.revision);
        print_qos(view.qos_on, view.rate_mbit, view.revision);
        return;
    }
    let view = continuum::router_restore(host, port);
    if !view.ok {
        print("ROUTER_FAILED ", view.outcome.message);
        exit(1);
    }
    print("restored revision_before=", view.revision_before, " revision_after=", view.revision);
    print_qos(view.qos_on, view.rate_mbit, view.revision);
}

fn main() {
    let argv = args();
    if argv.len == 1 {
        if !continuum::run_setup_tui() { show_status(); }
        return;
    }
    if argv.len == 2 && argv[1] == "--tui" {
        if !continuum::run_setup_tui() {
            print("CONTINUUM_TUI_FAILED interactive terminal required (TERM=dumb and NO_TUI disable it)");
            exit(2);
        }
        return;
    }
    if (argv.len >= 4 && argv.len <= 6) && argv[1] == "--device-select" {
        var port: i64 = 80;
        if argv.len >= 5 && !parse_i64_digits(argv[4], port) { exit(2); }
        if argv.len == 6 && argv[5] != "--existing-credentials" { exit(2); }
        let observed = continuum::discover_host();
        if !continuum::device_select(continuum::setup_directory(), observed, argv[2], argv[3], port, argv.len == 6) {
            print("DEVICE_REFUSED observed candidate, supported host path and unused private binding required"); exit(1);
        }
        var selected = continuum::DeviceState {};
        if !continuum::device_saved(continuum::setup_directory(), selected) { exit(1); }
        print(continuum::device_record(selected)); return;
    }
    if (argv.len == 3 || argv.len == 4) && argv[1] == "--device-step" {
        if argv.len == 4 && argv[3] != "--execute" { exit(2); }
        if argv[2] == "setup" {
            let report = continuum::run_device_agent(loop_config("MODEL_API_KEY"), continuum::setup_directory(),
                "Investigate and commission the selected device under my standing device permission. Choose and verify the work; do not reboot it.", argv.len == 4);
            print(continuum::device_agent_record(report));
            if !report.ok { exit(1); }
            return;
        }
        let rc = continuum::device_step(continuum::setup_directory(), argv[2], argv.len == 4);
        if rc != 0 { exit(rc); }
        return;
    }
    if argv.len == 4 && argv[1] == "--device-qos" && argv[3] == "--execute" {
        exit(continuum::device_qos_step(continuum::setup_directory(), argv[2], false));
    }
    if argv.len == 3 && argv[1] == "--device-qos-restore" && argv[2] == "--execute" {
        exit(continuum::device_qos_step(continuum::setup_directory(), "", true));
    }
    if argv.len == 3 && argv[1] == "--talk" {
        let report = continuum::run_device_agent(loop_config("MODEL_API_KEY"), continuum::setup_directory(), argv[2], false);
        print(continuum::device_agent_record(report));
        if !report.ok { exit(1); }
        return;
    }
    if argv.len == 2 && argv[1] == "--owner-policy" {
        exit(continuum::owner_cli(continuum::setup_directory(), "", false));
    }
    if argv.len == 3 && argv[1] == "--owner-policy-set" {
        exit(continuum::owner_cli(continuum::setup_directory(), argv[2], true));
    }
    if argv.len == 3 && argv[1] == "--program-install" {
        exit(continuum::program_cli(continuum::setup_directory(), "install_program", argv[2]));
    }
    if argv.len == 2 && argv[1] == "--program-prune" {
        exit(continuum::program_cli(continuum::setup_directory(), "prune_programs", ""));
    }
    if argv.len == 2 && argv[1] == "--programs" {
        exit(continuum::program_cli(continuum::setup_directory(), "list_programs", ""));
    }
    if argv.len == 3 && (argv[1] == "--program-run" || argv[1] == "--program-disable" || argv[1] == "--program-enable" ||
            argv[1] == "--program-read" || argv[1] == "--program-reconcile") {
        exit(continuum::program_cli(continuum::setup_directory(),
            if argv[1] == "--program-run" { "run_program" } else if argv[1] == "--program-disable" { "disable_program" }
            else if argv[1] == "--program-read" { "read_program" } else if argv[1] == "--program-reconcile" { "reconcile_program" }
            else { "enable_program" }, argv[2]));
    }
    if argv.len == 2 && argv[1] == "--takeover-drill" {
        exit(continuum::takeover_drill(continuum::setup_directory()));
    }
    if argv.len == 2 && argv[1] == "--takeover-run" {
        exit(continuum::takeover_cli(continuum::setup_directory()));
    }
    if argv.len == 4 && argv[1] == "--measure" {
        exit(continuum::measure_cli(continuum::setup_directory(), argv[2], argv[3], false));
    }
    if argv.len == 5 && argv[1] == "--measure" && argv[4] == "--upload" {
        // Egress shaping only sees what the client sends, so the bufferbloat
        // check that can move under CAKE is an upload load.
        exit(continuum::measure_cli(continuum::setup_directory(), argv[2], argv[3], true));
    }
    if argv.len == 3 && argv[1] == "--device-mode" {
        let refused = continuum::device_set_mode(continuum::setup_directory(), argv[2]);
        if refused.len > 0 { print("DEVICE_REFUSED ", refused); exit(1); }
        print("DEVICE_MODE ", argv[2]); return;
    }
    if argv.len == 2 && argv[1] == "--device-status" {
        var selected = continuum::DeviceState {};
        if !continuum::device_saved(continuum::setup_directory(), selected) { print("DEVICE_REFUSED invalid or busy binding"); exit(1); }
        print(continuum::device_record(selected)); return;
    }
    if argv.len == 2 && argv[1] == "--discover" {
        let observed = continuum::discover_host();
        print(observed);
        if observed.find("\"interfaces\"") < 0 { exit(1); }
        return;
    }
    if argv.len == 2 && argv[1] == "--discover-model" {
        let report = continuum::run_discovery(loop_config("MODEL_API_KEY"));
        print(continuum::discovery_record(report));
        if !report.ok { exit(1); }
        return;
    }
    if argv.len == 2 && argv[1] == "--test-meta" {
        var cfg = loop_config("MODEL_API_KEY");
        if !continuum::meta_credentials_available(cfg) {
            print("META_TEST_FAILED MODEL_API_KEY unavailable; no provider call");
            exit(1);
        }
        cfg.max_output_tokens = 256;
        var body: u8[>..] = [];
        if !continuum::meta_request_body(cfg, cfg.controller_model,
                "Connection test only. Reply with: Continuum Meta connection verified.",
                "Verify the connection. Do not request tools or perform any action.", "[]", body) { exit(1); }
        let result = continuum::meta_exchange(cfg, "connection-test", body);
        if result.outcome.status != continuum::Status.Completed {
            print("META_TEST_FAILED ", result.outcome.message);
            exit(1);
        }
        print("META_CONNECTION_VERIFIED model=", result.provider_model_id, " calls=1");
        return;
    }
    if argv.len == 2 && argv[1] == "--sim" {
        let outcome = continuum::run_sim_loop();
        if outcome.status != continuum::Status.Completed {
            exit(1);
        }
        return;
    }
    if (argv.len == 2 || argv.len == 3) && argv[1] == "--serve" {
        var limit: i64 = 0;
        if argv.len == 3 && (!parse_i64_digits(argv[2], limit) || limit < 1) {
            print("SERVICE_FAILED sample limit must be 1..99999; omit for continuous operation"); exit(2);
        }
        let outcome = continuum::run_service(loop_config("MODEL_API_KEY"), limit);
        if outcome.status != continuum::Status.Completed {
            print("SERVICE_FAILED ", outcome.message); exit(1);
        }
        return;
    }
    if argv.len == 2 && argv[1] == "--daemon" {
        let result = continuum::run_daemon(12);
        if result.outcome.status != continuum::Status.Completed || result.escalations != 0 {
            exit(1);
        }
        return;
    }
    if (argv.len == 2 || argv.len == 3) && argv[1] == "--loop" {
        if argv.len == 3 { show_loop(argv[2], false); }
        else { let run_id = str("run-", time_ns()); show_loop(run_id, false); }
        return;
    }
    if argv.len == 3 && argv[1] == "--resume" {
        show_loop(argv[2], true);
        return;
    }
    if argv.len >= 2 && argv[1] == "router" {
        show_router();
        return;
    }
    if argv.len == 1 || (argv.len == 2 && argv[1] == "--status") {
        show_status();
        return;
    }
    print("Usage: continuum [--tui] | --status | --sim | --daemon | --loop");
    print("       continuum --serve [sample-count] (live monitoring; opt-in Meta uses owner-scoped device capabilities)");
    print("       continuum --discover | --discover-model | --test-meta");
    print("       continuum --device-select <candidate-id> <ssid-stem> [port [--existing-credentials]]");
    print("       continuum --device-status | --device-step inspect | authorize | setup [--execute] | restore --execute | reboot --execute");
    print("       continuum --device-mode observer | advisor | operator | takeover (takeover needs a passed drill)");
    print("       continuum --takeover-drill (runs the loop, proves revocation, writes the artifact)");
    print("       continuum --measure host:port/path /loadpath (idle vs loaded RTT, goodput, sample-counted evidence)");
    print("       continuum --device-step qos-status (read-only: qdisc tool and current root)");
    print("       continuum --device-qos <profile.json> --execute | --device-qos-restore --execute (owner-applied qdisc)");
    print("       continuum --talk <message> (selected-device conversation; never grants reboot permission)");
    print("       continuum --owner-policy | --owner-policy-set <json> (owner only; never a Meta tool)");
    print("       continuum --program-install <json> | --program-prune");
    print("       continuum --programs | --program-read <id> | --program-run <id>");
    print("       continuum --program-disable <id> | --program-enable <id> | --program-reconcile <id>");
    print("       continuum --device-step revoke --execute (no Meta call; disables standing device authority)");
    print("       continuum router status | apply <profile> <rate_mbit> | restore");
    print("--loop runs one supervised controller/workload session. Observations are synthetic; physical writes remain closed. --discover reads this host without Meta. --discover-model spends bounded read-only Meta calls.");
    exit(2);
}
