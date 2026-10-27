import .contracts;
import .sim;
import .store;
namespace continuum;

// Sim-backed actuator (M05-sim): applies only admitted requests to the
// owned simulated queue, reads back actual sim state for verification, and
// restores on demand or lease expiry. The native path (tc/CAKE over SSH or
// router HTTP) plugs in behind these same signatures later.
struct LeaseState {
    active: bool = false,
    lease_id: u8[..64] = "",
    profile_id: u8[..64] = "",
    prev_profile_id: u8[..64] = "",
    revision: i64 = 0,
    expires_at_ms: i64 = 0,
}

var active_lease: LeaseState = LeaseState {};
var last_action_id: u8[..128] = "";
var last_receipt: ActionReceipt = ActionReceipt {};
var lease_store_path: u8[..256] = "";
var sim_store_path: u8[..256] = "";
var store_enabled: bool = false;

// Point the actuator at durable state. From here on, lease intent hits
// disk before any mutation, and every mutation re-saves the sim world.
fn actuator_use_store(lease_path: const u8[:], sim_path: const u8[:]) {
    lease_store_path = lease_path;
    sim_store_path = sim_path;
    store_enabled = lease_path.len > 0 && sim_path.len > 0;
}

// Test-environment crash: drop every in-memory trace of the lease. Files
// are deliberately untouched -- recovery has to earn its state back.
fn actuator_forget_state() {
    active_lease = LeaseState {};
    last_action_id = "";
    last_receipt = ActionReceipt {};
}

fn store_receipt(action_id: const u8[:], receipt: ActionReceipt) {
    last_action_id = action_id;
    last_receipt = receipt;
}

fn apply_profile(request: ActionRequest, admission: Admission) -> ActionReceipt {
    if !admission.admitted || admission.action_id != request.request_id {
        return ActionReceipt {
            outcome: Outcome { status: Status.Rejected, message: "apply without matching admission" },
        };
    }
    if active_lease.active {
        return ActionReceipt {
            outcome: Outcome { status: Status.Rejected, message: "a lease is already active" },
        };
    }
    let prev = sim_current_profile_id();
    if store_enabled {
        // Intent first: if this write fails, nothing has mutated and the
        // caller hears about it. A crash after this line is recoverable.
        if !lease_save(lease_store_path, request.lease_id, request.profile_id, prev,
                       request.expected_revision, request.issued_at_ms + request.lease_ms) {
            return ActionReceipt {
                outcome: Outcome { status: Status.Failed, message: "lease intent could not be persisted" },
            };
        }
    }
    if !sim_apply(request.profile_id) {
        return ActionReceipt {
            outcome: Outcome { status: Status.Failed, message: "sim rejected the profile" },
        };
    }
    if store_enabled {
        sim_save(sim_store_path);
    }
    active_lease = LeaseState {
        active: true,
        lease_id: request.lease_id,
        profile_id: request.profile_id,
        prev_profile_id: prev,
        revision: request.expected_revision,
        expires_at_ms: request.issued_at_ms + request.lease_ms,
    };
    let readback_ok = sim_current_profile_id() == request.profile_id;
    var receipt = ActionReceipt {
        outcome: Outcome { status: Status.Completed, message: "applied and read back" },
        action_id: request.request_id,
        lease_id: request.lease_id,
        observed_revision: request.expected_revision,
        applied: true,
        restored: false,
        verification_complete: readback_ok,
    };
    if !readback_ok {
        receipt.outcome = Outcome { status: Status.Failed, message: "readback mismatch after apply" };
    }
    store_receipt(request.request_id, receipt);
    return receipt;
}

fn restore_profile(request: ActionRequest, admission: Admission) -> ActionReceipt {
    if !admission.admitted || admission.action_id != request.request_id {
        return ActionReceipt {
            outcome: Outcome { status: Status.Rejected, message: "restore without matching admission" },
        };
    }
    if !active_lease.active || request.lease_id != active_lease.lease_id {
        return ActionReceipt {
            outcome: Outcome { status: Status.Rejected, message: "no matching active lease" },
        };
    }
    if !sim_apply(active_lease.prev_profile_id) {
        return ActionReceipt {
            outcome: Outcome { status: Status.Failed, message: "sim rejected the restore" },
        };
    }
    let readback_ok = sim_current_profile_id() == active_lease.prev_profile_id;
    active_lease.active = false;
    if store_enabled {
        sim_save(sim_store_path);
        lease_clear(lease_store_path);
    }
    var receipt = ActionReceipt {
        outcome: Outcome { status: Status.Completed, message: "restored and read back" },
        action_id: request.request_id,
        lease_id: request.lease_id,
        observed_revision: request.expected_revision,
        applied: false,
        restored: true,
        verification_complete: readback_ok,
    };
    if !readback_ok {
        receipt.outcome = Outcome { status: Status.Failed, message: "readback mismatch after restore" };
    }
    store_receipt(request.request_id, receipt);
    return receipt;
}

fn read_action_result(action_id: const u8[:]) -> ActionReceipt {
    if action_id == "" || action_id != last_action_id {
        return ActionReceipt {
            outcome: Outcome { status: Status.Failed, message: "unknown action id" },
        };
    }
    return last_receipt;
}

// Independent watchdog: restores owned state past lease expiry even if the
// controller is gone. A live deployment runs this out-of-process; here it
// runs against the same sim state so expiry behavior is testable.
fn reconcile_expired_lease(lease_id: const u8[:], now_ms: i64) -> ActionReceipt {
    if !active_lease.active || lease_id != active_lease.lease_id {
        return ActionReceipt {
            outcome: Outcome { status: Status.Rejected, message: "no matching active lease" },
        };
    }
    if now_ms < active_lease.expires_at_ms {
        return ActionReceipt {
            outcome: Outcome { status: Status.Accepted, message: "lease still valid" },
            action_id: lease_id,
            lease_id: lease_id,
        };
    }
    sim_apply(active_lease.prev_profile_id);
    let readback_ok = sim_current_profile_id() == active_lease.prev_profile_id;
    active_lease.active = false;
    if store_enabled {
        sim_save(sim_store_path);
        lease_clear(lease_store_path);
    }
    return ActionReceipt {
        outcome: Outcome { status: Status.Completed, message: "watchdog restored expired lease" },
        action_id: lease_id,
        lease_id: lease_id,
        observed_revision: active_lease.revision,
        applied: false,
        restored: true,
        verification_complete: readback_ok,
    };
}

// Startup reconciliation: the watchdog's first job after any restart.
// Reads the persisted lease and sim world back, then either rehydrates a
// still-valid lease (controller may resume) or restores an expired one
// (nobody is coming back to do it). No lease on disk: honestly rejected.
fn actuator_recover(now_ms: i64) -> ActionReceipt {
    if !store_enabled {
        return ActionReceipt {
            outcome: Outcome { status: Status.Rejected, message: "no durable store configured" },
        };
    }
    let saved = lease_load(lease_store_path);
    if !saved.found {
        return ActionReceipt {
            outcome: Outcome { status: Status.Rejected, message: "no persisted lease" },
        };
    }
    sim_load(sim_store_path);
    if now_ms < saved.expires_at_ms {
        active_lease = LeaseState {
            active: true,
            lease_id: saved.lease_id,
            profile_id: saved.profile_id,
            prev_profile_id: saved.prev_profile_id,
            revision: saved.revision,
            expires_at_ms: saved.expires_at_ms,
        };
        return ActionReceipt {
            outcome: Outcome { status: Status.Accepted, message: "lease rehydrated after restart" },
            action_id: saved.lease_id,
            lease_id: saved.lease_id,
            observed_revision: saved.revision,
            applied: true,
            verification_complete: sim_current_profile_id() == saved.profile_id,
        };
    }
    sim_apply(saved.prev_profile_id);
    let readback_ok = sim_current_profile_id() == saved.prev_profile_id;
    active_lease.active = false;
    sim_save(sim_store_path);
    lease_clear(lease_store_path);
    return ActionReceipt {
        outcome: Outcome { status: Status.Completed, message: "recovered: expired lease restored" },
        action_id: saved.lease_id,
        lease_id: saved.lease_id,
        observed_revision: saved.revision,
        restored: true,
        verification_complete: readback_ok,
    };
}
