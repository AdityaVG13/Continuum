import .contracts;
namespace continuum;

// Deterministic admission (M04): the policy (or Meta) chooses, this code
// disposes. Fail-closed: every check below must pass or nothing mutates.
// Restoration of an owned active lease is exempt from the observation-age
// and route-epoch gates (spec 09: no fresh network evidence required); it
// still needs ownership, scope, revision, lease-bound and duplicate checks
// here plus the actuator's lease-identity match. It is never blocked merely
// because the observation is old or the apply budget is spent (that budget
// governs new profile changes, per BUILD_PLAN C08).
const MAX_OBSERVATION_AGE_MS: i64 = 5000;
const MAX_APPLIES_PER_MINUTE: i64 = 8;

var seen_ids: u8[..64][..64] = [];
var window_start_ms: i64 = -1;
var window_admits: i64 = 0;

fn reject(reason: const u8[:]) -> Admission {
    return Admission {
        outcome: Outcome { status: Status.Rejected, message: reason },
        admitted: false,
    };
}

fn seen_before(id: const u8[:]) -> bool {
    for s in seen_ids {
        if s == id {
            return true;
        }
    }
    return false;
}

fn admit_action(request: ActionRequest, observation: Observation,
                profile: ActionProfile, now_ms: i64) -> Admission {
    if !profile.owned {
        return reject("profile is not owned by this controller");
    }
    if request.scope_id != profile.scope_id || request.path_id != profile.path_id {
        return reject("request scope/path does not match profile");
    }
    if !observation.metrics_known || observation.observation_id == "" {
        return reject("no usable evidence behind this request");
    }
    if request.route_epoch != observation.route_epoch
            && request.kind != ActionKind.RestoreProfile {
        return reject("route epoch changed since the observation");
    }
    if request.kind != ActionKind.RestoreProfile {
        // New profile changes need fresh evidence. Restoration of an owned
        // active lease is exempt from the observation-age gate (spec 09):
        // it is checked on ownership, revision and restorable state below
        // and at the actuator's lease match.
        let age = now_ms - observation.observed_at_ms;
        if age < 0 || age > MAX_OBSERVATION_AGE_MS {
            return reject("evidence is stale or future-dated");
        }
    }
    if request.lease_ms <= 0 || request.lease_ms > profile.maximum_lease_ms {
        return reject("lease outside the profile's permitted bound");
    }
    if request.expected_revision != profile.revision {
        return reject("profile revision conflict");
    }
    if request.request_id == "" || seen_before(request.request_id) {
        return reject("duplicate or empty request id");
    }
    if seen_ids.len >= 64 {
        // Bounded history: new profile changes fail closed once the table
        // is full ("restart rotation"). Restoration of an owned lease must
        // stay available (spec 09); at-most-once there rests on the
        // actuator's active-lease match, not on this table, so a restore
        // is admitted without consuming a history slot.
        if request.kind != ActionKind.RestoreProfile {
            return reject("admission history full; restart rotation");
        }
        return Admission {
            outcome: Outcome { status: Status.Completed, message: "admitted" },
            action_id: request.request_id,
            admitted: true,
            authority_token: request.request_id,
        };
    }
    if request.kind == ActionKind.ApplyProfile {
        if window_start_ms < 0 || now_ms - window_start_ms >= 60000 {
            window_start_ms = now_ms;
            window_admits = 0;
        }
        if window_admits >= MAX_APPLIES_PER_MINUTE {
            return reject("apply rate exceeded for this window");
        }
        window_admits += 1;
    }
    seen_ids.push(request.request_id);
    return Admission {
        outcome: Outcome { status: Status.Completed, message: "admitted" },
        action_id: request.request_id,
        admitted: true,
        authority_token: request.request_id,
    };
}
