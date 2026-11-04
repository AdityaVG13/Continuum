import .contracts;
import .workload;
import .meta_provider;
import os;
import json;
namespace continuum;

struct TaskContextResult { outcome: Outcome = Outcome {}, context: TaskContext = TaskContext {} }

struct CaseTask {
    armed: bool = false,
    step_id: u8[..64] = "",
    deadline_at_ms: i64 = 0,
    task_summary: u8[..512] = "",
}

var case_task: CaseTask = CaseTask {};
var active_task: TaskContext = TaskContext {};

// The controller and workload share this identity, not a canned task.
fn release_task_context(run_id: const u8[:]) -> TaskContext {
    return TaskContext {
        run_id: run_id, step_id: "release-audit", revision: 1,
        deadline_at_ms: 60000, validation_profile: "release-readiness",
        task_summary: "Audit the supplied release evidence and policy; return an evidence-backed readiness decision.",
        at_safe_boundary: true,
    };
}

fn set_case_task(step_id: const u8[:], deadline_at_ms: i64, summary: const u8[:]) -> bool {
    if step_id.len == 0 || step_id.len > 64 || deadline_at_ms <= 0
            || summary.len == 0 || summary.len > 512 {
        return false;
    }
    case_task.armed = true;
    case_task.step_id = step_id;
    case_task.deadline_at_ms = deadline_at_ms;
    case_task.task_summary = summary;
    return true;
}

fn clear_case_task() {
    case_task.armed = false;
}

fn read_task_context(run_id: const u8[:]) -> TaskContextResult {
    if run_id.len == 0 {
        return TaskContextResult { outcome: Outcome { status: Status.Failed, message: "task context: run_id required" } };
    }
    if active_task.run_id.len > 0 {
        if active_task.run_id != run_id {
            return TaskContextResult { outcome: Outcome { status: Status.Rejected, message: "task belongs to another run" } };
        }
        return TaskContextResult {
            outcome: Outcome { status: Status.Completed, message: "active workload context" },
            context: active_task,
        };
    }
    if case_task.armed {
        return TaskContextResult {
            outcome: Outcome { status: Status.Completed, message: "case task" },
            context: TaskContext {
                run_id: run_id,
                step_id: case_task.step_id,
                revision: 1,
                deadline_at_ms: case_task.deadline_at_ms,
                validation_profile: "case",
                task_summary: case_task.task_summary,
                at_safe_boundary: true,
            },
        };
    }
    return TaskContextResult {
        outcome: Outcome { status: Status.Completed, message: "task context" },
        context: TaskContext {
            run_id: run_id,
            step_id: "audit",
            revision: 1,
            deadline_at_ms: 60000,
            validation_profile: "release-readiness",
            task_summary: "Release readiness audit with blockers REL-17 and SEC-42",
            at_safe_boundary: true,
        },
    };
}

struct TaskInput {
    ok: bool = false,
    payload: u8[..8192] = "",
    manifest: u8[..8192] = "",
    requirements: u8[..8192] = "",
}

// Local, authored corpus is explicitly synthetic. Only the actual task
// model response is live. This is not an impaired evidence-fetch benchmark.
fn prepare_task_input(context: TaskContext) -> TaskInput {
    var input = TaskInput {};
    if !valid_id(context.run_id, 64) || !valid_id(context.step_id, 64)
            || context.revision < 0 || context.validation_profile != "release-readiness" {
        return input;
    }
    var manifest: u8[>..] = [];
    var requirements: u8[>..] = [];
    if !read_file("fixtures/corpus/manifest.json", manifest) || manifest.len > 8192
            || !read_file("fixtures/corpus/expected-findings.json", requirements) || requirements.len > 8192 {
        return input;
    }
    var doc: json::Node[>..] = [];
    var decoded: u8[>..] = [];
    let root, err = json::parse(manifest, doc, decoded);
    if !root { return input; }
    let documents = json::member(root, "documents");
    if !documents || !json_array(documents) { return input; }
    var payload: u8[>..] = [];
    payload.append("{\"run_id\":");
    json::format_string(payload, context.run_id);
    payload.append(",\"task_id\":");
    json::format_string(payload, context.step_id);
    payload.append(",\"task_revision\":");
    json::format_int(payload, context.revision);
    payload.append(",\"evidence_provenance\":\"authored_synthetic_corpus\",\"documents\":[");
    var item = documents.first;
    var count: i64 = 0;
    while item {
        let id, has_id = json::as_string(json::member(item, "evidence_id"));
        let path, has_path = json::as_string(json::member(item, "path"));
        if !has_id || !valid_id(id, 64) || !has_path || !valid_id(path, 128) || count >= 16 {
            return input;
        }
        var content: u8[>..] = [];
        if !read_file(str("fixtures/corpus/", path), content) || content.len == 0 || content.len > 4096 {
            return input;
        }
        if count > 0 { payload.append(","); }
        payload.append("{\"evidence_id\":");
        json::format_string(payload, id);
        payload.append(",\"content\":");
        json::format_string(payload, content);
        payload.append("}");
        if payload.len > 8000 { return input; }
        count += 1;
        item .= item.next;
    }
    if count == 0 { return input; }
    payload.append("]}");
    input.payload = payload;
    input.manifest = manifest;
    input.requirements = requirements;
    input.ok = true;
    return input;
}

fn task_failed(status: Status, reason: const u8[:]) -> TaskResult {
    return TaskResult {
        outcome: Outcome { status: status, message: reason }, phase: TaskPhase.Failed,
    };
}

fn validate_prepared_task(context: TaskContext, candidate: TaskResult, input: TaskInput) -> TaskResult {
    if !input.ok || candidate.outcome.status != Status.Completed {
        return task_failed(Status.Rejected, "task input or candidate unavailable");
    }
    let shape = validate_workload_result(candidate.output, context.run_id, context.step_id, context.revision);
    if !shape.ok { return task_failed(Status.Rejected, shape.reason); }
    let facts = validate_audit_findings(candidate.output, input.manifest, input.requirements);
    if !facts.ok { return task_failed(Status.Rejected, facts.reason); }
    var accepted = candidate;
    accepted.outcome = Outcome { status: Status.Completed, message: "audit schema, identity, citations and seeded findings validated" };
    accepted.phase = TaskPhase.Validated;
    accepted.independently_validated = true;
    // Delivery is not a durable commit. Persistence belongs to the run store.
    accepted.committed = false;
    return accepted;
}

fn validate_task_result(context: TaskContext, candidate: TaskResult) -> TaskResult {
    return validate_prepared_task(context, candidate, prepare_task_input(context));
}

fn task_from_model(context: TaskContext, input: TaskInput, reply: ModelResult) -> TaskResult {
    if reply.outcome.status != Status.Completed {
        return task_failed(Status.Failed, reply.outcome.message);
    }
    if reply.has_tool_call || reply.text.len == 0 {
        return task_failed(Status.Rejected, "task must return a result object, not a privileged tool call");
    }
    return validate_prepared_task(context, TaskResult {
        outcome: Outcome { status: Status.Completed }, output: reply.text,
        provenance: reply.provenance, provider_model_id: reply.provider_model_id,
    }, input);
}

fn run_prepared_meta_task(context: TaskContext, config: ModelConfig, input: TaskInput) -> TaskResult {
    if !input.ok { return task_failed(Status.Failed, "task input unavailable or invalid"); }
    let reply = request_meta(config, ModelRequest {
        request_id: str(context.run_id, ":task"), run_id: context.run_id,
        role_id: "task", prompt_revision: "workload.md", context: input.payload,
    });
    return task_from_model(context, input, reply);
}

fn run_meta_task(context: TaskContext, config: ModelConfig) -> TaskResult {
    return run_prepared_meta_task(context, config, prepare_task_input(context));
}
