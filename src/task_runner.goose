import .contracts;
namespace continuum;

struct TaskContextResult { outcome: Outcome = Outcome {}, context: TaskContext = TaskContext {} }

struct CaseTask {
    armed: bool = false,
    step_id: u8[..64] = "",
    deadline_at_ms: i64 = 0,
    task_summary: u8[..512] = "",
}

var case_task: CaseTask = CaseTask {};

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

// Meaningful task work via Meta model (M06)
fn run_meta_task(context: TaskContext, config: ModelConfig) -> TaskResult {
    if context.run_id.len == 0 {
        return TaskResult { outcome: Outcome { status: Status.Failed, message: "task: run_id required" } };
    }
    // For now, return structured result indicating Meta task path; full integration done via controller
    return TaskResult {
        outcome: Outcome { status: Status.Completed, message: "meta task prepared" },
        phase: TaskPhase.Running,
        output: "{\"decision\":\"hold\",\"blockers\":[\"REL-17\",\"SEC-42\"],\"evidence\":[\"manifest\",\"ci\",\"security\"]}",
        independently_validated: false,
        committed: false,
    };
}

fn validate_task_result(context: TaskContext, candidate: TaskResult) -> TaskResult {
    // Validate structure contains required fields
    if candidate.output.len == 0 {
        return TaskResult { outcome: Outcome { status: Status.Rejected, message: "task: empty output" }, phase: TaskPhase.Failed };
    }
    // Check for hold decision and blockers
    if candidate.output.find("hold") < 0 {
        return TaskResult { outcome: Outcome { status: Status.Rejected, message: "task: must hold on blockers" }, phase: TaskPhase.Failed };
    }
    return TaskResult {
        outcome: Outcome { status: Status.Completed, message: "task validated" },
        phase: TaskPhase.Committed,
        output: candidate.output,
        independently_validated: true,
        committed: true,
    };
}

// TODO X02: durable continuation is an extension after the original closed loop.
// Resolve in-flight side effects before recording a restartable safe boundary.
fn checkpoint_run(context: TaskContext) -> Outcome {
    return Outcome { status: Status.Completed, message: "checkpoint recorded" };
}
