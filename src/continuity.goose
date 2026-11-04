// Completed-work continuity, not offline inference or arbitrary process snapshots.
// Reuse requires exact current input/prompt/schema/model bytes and a fresh pass
// through the independent validator. No route or intervention is replayed.
import .task_runner;
import json;
import os;
namespace continuum;

extern fn ct_checkpoint_read(path: const u8[:], out: u8[:], length: i64&) -> i32;
extern fn ct_checkpoint_write(path: const u8[:], data: const u8[:]) -> i32;

struct TaskBinding {
    ok: bool = false,
    bytes: u8[..32768] = "",
}

fn task_binding(context: TaskContext, cfg: ModelConfig) -> TaskBinding {
    let input = prepare_task_input(context);
    var prompt: u8[>..] = []; var schema: u8[>..] = [];
    if !input.ok || !read_file("docs/prompts/workload.md", prompt) || prompt.len > 8192
            || !read_file("schemas/workload-result.schema.json", schema) || schema.len > 8192 {
        return TaskBinding {};
    }
    var bytes: u8[>..] = [];
    // Version this identity when validator semantics change. Exact bytes avoid
    // metadata-only invalidation and do not pretend to be a cryptographic hash.
    bytes.append("{\"validator\":\"release-readiness-1\",\"input\":");
    json::format_string(bytes, input.payload);
    bytes.append(",\"manifest\":"); json::format_string(bytes, input.manifest);
    bytes.append(",\"requirements\":"); json::format_string(bytes, input.requirements);
    bytes.append(",\"prompt\":"); json::format_string(bytes, prompt);
    bytes.append(",\"schema\":"); json::format_string(bytes, schema);
    bytes.append(",\"base_url\":"); json::format_string(bytes, cfg.base_url);
    bytes.append(",\"task_model\":"); json::format_string(bytes, cfg.task_model);
    bytes.append("}");
    if bytes.len > 32768 { return TaskBinding {}; }
    return TaskBinding { ok: true, bytes: bytes };
}

fn task_provenance_name(value: Provenance) -> const u8[:] {
    match value {
        Live => { return "live"; },
        Recorded => { return "recorded"; },
        Synthetic => { return "synthetic"; },
        _ => { return "unset"; },
    }
}

fn resume_task(path: const u8[:], context: TaskContext, cfg: ModelConfig) -> TaskResult {
    let current = task_binding(context, cfg);
    if !current.ok { return task_failed(Status.Rejected, "current task inputs unavailable"); }
    var buffer: u8[..65536] = [0; 65536]; var n: i64 = 0;
    if ct_checkpoint_read(path, buffer, n) != 0 || n <= 0 || n > buffer.len {
        return task_failed(Status.Rejected, "private, bounded checkpoint unavailable");
    }
    var doc: json::Node[>..] = []; var decoded: u8[>..] = [];
    let root, err = json::parse(buffer[..n], doc, decoded);
    let known: const u8[:][..5] = ["format", "binding", "output", "provenance", "provider_model_id"];
    if !root || !no_unknown(root, known) { return task_failed(Status.Rejected, "checkpoint shape invalid"); }
    let version, v = json::as_i64(json::member(root, "format"));
    let binding, b = json::as_string(json::member(root, "binding"));
    let output, o = json::as_string(json::member(root, "output"));
    let source, s = json::as_string(json::member(root, "provenance"));
    let model, m = json::as_string(json::member(root, "provider_model_id"));
    if !v || version != 1 || !b || binding != current.bytes || !o || output.len > 8192
            || !s || !m || model.len > 128 {
        return task_failed(Status.Rejected, "checkpoint does not match current task inputs/model");
    }
    var provenance = Provenance.Unset;
    if source == "live" { provenance = Provenance.Live; }
    else if source == "recorded" { provenance = Provenance.Recorded; }
    else if source == "synthetic" { provenance = Provenance.Synthetic; }
    else { return task_failed(Status.Rejected, "checkpoint provenance missing"); }
    var accepted = validate_task_result(context, TaskResult {
        outcome: Outcome { status: Status.Completed }, output: output,
        provenance: provenance, provider_model_id: model,
    });
    if !accepted.independently_validated { return accepted; }
    accepted.phase = TaskPhase.Committed;
    accepted.committed = true;
    accepted.outcome.message = "resumed an independently revalidated artifact; no new inference";
    return accepted;
}

// Call only after the supervised session has resolved its owned intervention.
// The pre-request binding must still match, including mutations during a call.
fn checkpoint_run(path: const u8[:], context: TaskContext, cfg: ModelConfig,
        original: TaskBinding, candidate: TaskResult) -> TaskResult {
    let current = task_binding(context, cfg);
    if !original.ok || !current.ok || current.bytes != original.bytes {
        return task_failed(Status.Rejected, "task inputs changed during the session; refusing commit");
    }
    let accepted = validate_task_result(context, candidate);
    if !accepted.independently_validated || accepted.provenance == Provenance.Unset { return accepted; }
    var text: u8[>..] = [];
    text.append("{\"format\":1,\"binding\":"); json::format_string(text, original.bytes);
    text.append(",\"output\":"); json::format_string(text, accepted.output);
    text.append(",\"provenance\":"); json::format_string(text, task_provenance_name(accepted.provenance));
    text.append(",\"provider_model_id\":"); json::format_string(text, accepted.provider_model_id);
    text.append("}\n");
    if text.len > 65536 || ct_checkpoint_write(path, text) != 0 {
        return task_failed(Status.Failed, "durable commit failed; no checkpoint acknowledgement");
    }
    // This readback is part of commit acknowledgement, not a saved boolean.
    return resume_task(path, context, cfg);
}
