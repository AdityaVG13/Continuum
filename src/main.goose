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
import os;

// The status entrypoint reports each module's implementation state. Calling
// the operations below exercises their types; unconfigured calls fail closed
// before any network or mutation.
fn show_status() {
    let cfg = continuum::ModelConfig {};
    let request = continuum::ActionRequest {};
    let admission = continuum::admit_action(request, continuum::Observation {}, continuum::ActionProfile {}, 0);
    print("Continuum v3: --loop runs the six-tool sim proof; with ROUTER_HOST it applies through the router and checks the revision readback. The live model call stays fail-closed until a key is set.");
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
    print("Optional checkpoint: ", continuum::status_name(continuum::checkpoint_run(continuum::TaskContext {}).status));
    print("Optional RaptorQ: ", continuum::status_name(continuum::transfer_evidence_object(continuum::ObjectTransfer {}).status));
}

fn loop_config(key_env: const u8[:]) -> continuum::ModelConfig {
    var model_b: u8[>..] = [];
    var v: u8[>..] = [];
    if env("META_CONTROLLER_MODEL", v) && v.len > 0 && v.len <= 128 {
        model_b.append(v);
    } else {
        model_b.append("muse-wonder-1.0");
    }
    var cfg = continuum::ModelConfig {
        base_url: "https://api.meta.ai/v1",
        request_timeout_ms: 30000,
        max_output_tokens: 2048,
        max_tool_rounds: 4,
    };
    cfg.controller_model = model_b;
    cfg.task_model = model_b;
    cfg.api_key_env_name = key_env;
    return cfg;
}

// Mechanical six-tool proof, labelled simulated, then the participant loop.
// No key: the adapter fails closed before any socket. A key spends the
// model's own tool rounds. This command does not invent a tool call.
fn show_loop() {
    let report = continuum::run_simulated_loop("sim-loop");
    print("SIMULATED");
    print("model_calls=", report.model_calls);
    print("profile=", report.profile_after);
    if report.outcome.status != continuum::Status.Completed || !report.simulated
            || report.model_calls != 0 || !report.saw_sqm
            || report.profile_after != "baseline-fifo" {
        print("SIM_LOOP_RED ", report.outcome.message);
        exit(1);
    }
    print("SIM_LOOP_ALL_GREEN");
    var router_host: u8[>..] = [];
    if env("ROUTER_HOST", router_host) && router_host.len > 0 {
        var port_text: u8[>..] = [];
        if !(env("ROUTER_PORT", port_text) && port_text.len > 0) {
            print("LOOP_ROUTER_FAILED router port missing");
            exit(1);
        }
        var port: i64 = 0;
        var port_ok = port_text.len <= 5;
        var pi: i64 = 0;
        while port_ok && pi < port_text.len {
            let b = port_text[pi];
            if b < '0' || b > '9' {
                port_ok = false;
            } else {
                port = port * 10 + (b - '0');
            }
            pi += 1;
        }
        if !port_ok || port <= 0 || port > 65535 {
            print("LOOP_ROUTER_FAILED router port invalid");
            exit(1);
        }
        var pw: u8[>..] = [];
        if !(env("ROUTER_PASSWORD", pw) && pw.len > 0) {
            print("LOOP_ROUTER_FAILED router credential refused");
            exit(1);
        }
        let rr = continuum::run_router_loop(router_host, port);
        print("LOOP_ROUTER revision_before=", rr.revision_before, " revision_after=", rr.revision_after);
        if !rr.verified || !rr.restored_drift || rr.revision_after != rr.revision_before + 1 {
            print("LOOP_ROUTER_FAILED ", rr.outcome.message);
            exit(1);
        }
        print("LOOP_ROUTER_ALL_GREEN");
    }

    var key_probe: u8[>..] = [];
    let have_key = env("MODEL_API_KEY", key_probe) && key_probe.len > 0;
    if !have_key {
        let absent = continuum::request_meta(loop_config("CONTINUUM_DEFINITELY_ABSENT_KEY"), continuum::ModelRequest {
            request_id: "sim-loop-nokey",
            run_id: "sim-loop",
            role_id: "controller",
            prompt_revision: "controller.md",
            context: "no-key probe: this request must never leave the machine",
        });
        if absent.outcome.status != continuum::Status.Failed
                || absent.provenance != continuum::Provenance.Unset
                || absent.has_tool_call
                || absent.outcome.message != "meta submit failed" {
            print("SIM_LOOP_LIVE_RED ", absent.outcome.message);
            exit(1);
        }
        print("SIM_LOOP_LIVE_SKIPPED_NO_KEY");
        return;
    }
    var case_name: u8[>..] = [];
    if !(env("CONTINUUM_CASE", case_name) && (case_name == "queue" || case_name == "provider")) {
        case_name = [];
        case_name.append("queue");
    }
    let live = continuum::run_participant_live("sim-loop-live", case_name, loop_config("MODEL_API_KEY"));
    print("PARTICIPANT case=", case_name, " model_calls=", live.model_calls,
        " applied=", live.applied, " abstained=", live.abstained, " profile=", live.profile_after);
    if live.outcome.status != continuum::Status.Completed || live.model_calls < 1 {
        print("SIM_LOOP_LIVE_RED ", live.outcome.message);
        exit(1);
    }
    print("SIM_LOOP_LIVE_ROUND_TRIP");
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
    if argv.len == 2 && argv[1] == "--sim" {
        let outcome = continuum::run_sim_loop();
        if outcome.status != continuum::Status.Completed {
            exit(1);
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
    if argv.len == 2 && argv[1] == "--loop" {
        show_loop();
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
    print("Usage: continuum --status | --sim | --daemon | --loop");
    print("       continuum router status | apply <profile> <rate_mbit> | restore");
    print("--loop runs the mechanical six-tool proof, then the participant loop if MODEL_API_KEY is set. CONTINUUM_CASE is queue or provider. The model chooses; the command does not.");
    exit(2);
}
