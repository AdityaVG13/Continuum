// Continuum v3. Internal records; wire shapes live in schemas/ and are
// enforced by src/tooljson.goose, src/workload.goose and src/meta_shape.goose.
// Blank identifiers and zero timestamps are unset values, never valid evidence.
namespace continuum;

enum Status { NotImplemented, Accepted, Rejected, Pending, Completed, Failed }
enum Provenance { Unset, Synthetic, Recorded, Live }
enum ToolName { ReadObservation, ReadTaskContext, ListProfiles, ApplyProfile, ReadActionResult, RestoreProfile }
enum ControllerPhase { Unconfigured, Observing, AwaitingMeta, Admitting, Applying, Verifying, Restoring, Paused, Failed }
enum ActionKind { ApplyProfile, RestoreProfile }
enum TaskPhase { Unconfigured, Pending, Running, AwaitingValidation, Committed, Failed }
// How a router can be reached. Sim is the test-environment backend; WebApi is
// a stock admin HTTP API; Ssh is a shell (tc/OpenWrt class); Serial is the
// bench recovery path. A profile is useless until `discovered` is true.
enum AccessKind { Unset, Sim, WebApi, Ssh, Serial }
// One daemon tick's verdict. Escalate is the model-on-exception seam: the
// deterministic loop never guesses past it.
enum Decision { Noop, Apply, Restore, Escalate }
// How a Meta transport failure maps: retry the call, stop and escalate to
// the operator, note a transport timeout, or reject a body that is not
// JSON at all. Nothing here authorizes action: every class escalates, the
// loop never acts on an error.
enum MetaErrorClass { Retryable, Fatal, Timeout, Malformed }

struct Outcome {
    status: Status = Status.NotImplemented,
    message: u8[..256] = "Not implemented: see docs/IMPLEMENTATION_MAP.md",
}

struct Observation {
    observation_id: u8[..64] = "",
    provenance: Provenance = Provenance.Unset,
    path_id: u8[..64] = "",
    route_epoch: i64 = 0,
    observed_at_ms: i64 = 0,
    window_ms: i64 = 0,
    attempts: i64 = 0,
    successes: i64 = 0,
    baseline_rtt_ms: f64 = 0.0,
    loaded_rtt_ms: f64 = 0.0,
    gateway_rtt_ms: f64 = 0.0,
    application_echo_ms: f64 = 0.0,
    provider_service_ms: f64 = 0.0,
    utilization: f64 = 0.0,
    loss_fraction: f64 = 0.0,
    metrics_known: bool = false,
}

struct TaskContext {
    run_id: u8[..64] = "",
    step_id: u8[..64] = "",
    revision: i64 = 0,
    deadline_at_ms: i64 = 0,
    validation_profile: u8[..64] = "",
    task_summary: u8[..512] = "",
    at_safe_boundary: bool = false,
    local_execution_allowed: bool = false,
}

struct ActionProfile {
    profile_id: u8[..64] = "",
    scope_id: u8[..64] = "",
    path_id: u8[..64] = "",
    owned: bool = false,
    configured_rate_kbit: i64 = 0,
    maximum_lease_ms: i64 = 0,
    revision: i64 = 0,
}

struct ModelConfig {
    base_url: u8[..256] = "",
    controller_model: u8[..128] = "",
    task_model: u8[..128] = "",
    api_key_env_name: u8[..64] = "MODEL_API_KEY",
    request_timeout_ms: i64 = 0,
    max_output_tokens: i64 = 0,
    max_tool_rounds: i64 = 0,
}

struct ModelRequest {
    request_id: u8[..64] = "",
    run_id: u8[..64] = "",
    role_id: u8[..64] = "",
    prompt_revision: u8[..128] = "",
    context: u8[..8192] = "",
}

struct ModelResult {
    outcome: Outcome = Outcome {},
    response_id: u8[..128] = "",
    request_id: u8[..64] = "",
    provider_model_id: u8[..128] = "",
    provenance: Provenance = Provenance.Unset,
    has_tool_call: bool = false,
    call_id: u8[..128] = "",
    tool: ToolName = ToolName.ReadObservation,
    arguments_json: u8[..8192] = "",
    text: u8[..8192] = "",
    // Byte-exact provider output items, replayed intact on continuation
    // (stateless history). Bounded: oversize responses fail closed upstream.
    raw_output_json: u8[..8192] = "",
}

struct ActionRequest {
    request_id: u8[..64] = "",
    originating_response_id: u8[..128] = "",
    originating_call_id: u8[..128] = "",
    run_id: u8[..64] = "",
    kind: ActionKind = ActionKind.ApplyProfile,
    profile_id: u8[..64] = "",
    scope_id: u8[..64] = "",
    path_id: u8[..64] = "",
    observation_id: u8[..64] = "",
    task_revision: i64 = 0,
    config_revision: i64 = 0,
    expected_revision: i64 = 0,
    route_epoch: i64 = 0,
    issued_at_ms: i64 = 0,
    expires_at_ms: i64 = 0,
    lease_ms: i64 = 0,
    lease_id: u8[..64] = "",
    rationale: u8[..1024] = "",
}

struct Admission {
    outcome: Outcome = Outcome {},
    action_id: u8[..128] = "",
    admitted: bool = false,
    authority_token: u8[..128] = "",
}

struct ActionReceipt {
    outcome: Outcome = Outcome {},
    action_id: u8[..128] = "",
    lease_id: u8[..64] = "",
    observed_revision: i64 = 0,
    applied: bool = false,
    restored: bool = false,
    verification_complete: bool = false,
}

struct ControllerState {
    phase: ControllerPhase = ControllerPhase.Unconfigured,
    run_id: u8[..64] = "",
    pending_call_id: u8[..64] = "",
    active_lease_id: u8[..64] = "",
    completed_tool_rounds: i64 = 0,
}

struct TaskResult {
    outcome: Outcome = Outcome {},
    phase: TaskPhase = TaskPhase.Unconfigured,
    output: u8[..8192] = "",
    independently_validated: bool = false,
    committed: bool = false,
}

struct Event {
    sequence: i64 = 0,
    event_type: u8[..128] = "",
    run_id: u8[..64] = "",
    timestamp_ms: i64 = 0,
    provenance: Provenance = Provenance.Unset,
    payload_json: u8[..8192] = "",
}

struct ObjectTransfer {
    object_id: u8[..64] = "",
    expected_sha256: u8[..64] = "",
    byte_length: i64 = 0,
    deadline_at_ms: i64 = 0,
    maximum_wire_bytes: i64 = 0,
    maximum_repair_bytes: i64 = 0,
}

// What one router can do, learned once by discovery (later: a model-driven
// pass) and then read by cheap code forever. No credentials live here: the
// password stays in the OS keychain; this record only names the env var or
// keychain slot that holds it. `can_*` flags are the capability ceiling the
// guardian checks before any request is admitted.
struct RouterProfile {
    router_id: u8[..64] = "",
    vendor: u8[..64] = "",
    model: u8[..64] = "",
    firmware: u8[..64] = "",
    access_kind: AccessKind = AccessKind.Unset,
    endpoint: u8[..256] = "",
    credential_ref: u8[..64] = "",
    scope_id: u8[..64] = "",
    path_id: u8[..64] = "",
    can_qos: bool = false,
    can_priority_device: bool = false,
    can_reboot: bool = false,
    can_dns: bool = false,
    can_channel: bool = false,
    can_client_list: bool = false,
    config_revision: i64 = 0,
    discovered: bool = false,
}

// The daemon's policy table: every threshold that used to be a magic number
// in the loop, in one record the operator (or later the model) can tune.
struct PolicyConfig {
    bloat_threshold_ms: f64 = 100.0,
    tick_ms: i64 = 1000,
    hold_ms: i64 = 4000,
    cooldown_ms: i64 = 5000,
    lease_ms: i64 = 10000,
    max_applies_per_hour: i64 = 8,
}

fn status_name(value: Status) -> const u8[:] {
    match value {
        NotImplemented => "not_implemented", Accepted => "accepted",
        Rejected => "rejected", Pending => "pending", Completed => "completed", Failed => "failed",
    }
}
