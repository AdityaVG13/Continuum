import .contracts;
import .sim;
namespace continuum;

struct ProfileListResult { outcome: Outcome = Outcome {}, profiles: ActionProfile[..8] = [] }

// Server-owned allowlist: only listed, owned profiles can ever be admitted.
// The sim catalogue answers for the lab-sim scope; every other scope gets
// an empty list, never an error masquerading as profiles.
fn list_profiles(scope_id: const u8[:]) -> ProfileListResult {
    if scope_id != "lab-sim" {
        return ProfileListResult {
            outcome: Outcome { status: Status.Completed, message: "no profiles for scope" },
        };
    }
    var out = ProfileListResult {
        outcome: Outcome { status: Status.Completed, message: "sim catalogue" },
    };
    for i in 0..sim_profile_count() {
        out.profiles.push(sim_profile(i));
    }
    return out;
}

// TODO M02: collect telemetry and task state; send the controller prompt to Meta;
// decode exactly one bounded tool call; dispatch through the guardian; return its
// actual tool result; ask Meta to verify or restore. Keep live provenance explicit.
// There is no hard-coded replacement controller behind this signature.
fn controller_tick(state: ControllerState, config: ModelConfig) -> Outcome {
    return Outcome { message: "TODO M02: Meta controller orchestration" };
}
