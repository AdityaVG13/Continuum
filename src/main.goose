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
    print("Continuum v3: specification and implementation ledger; the live controller loop and live model call are pending.");
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
    if argv.len == 1 || (argv.len == 2 && argv[1] == "--status") {
        show_status();
        return;
    }
    print("Usage: continuum --status | --sim | --daemon");
    print("No live, apply, demo, inference or benchmark command exists yet.");
    exit(2);
}
