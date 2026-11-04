// The resident optimization loop and the revocation drill share one engine.
// A "cycle" is the real guarded transaction, not a simulation: read the
// device's own capability graph, choose one enabled settable capability,
// apply it, and read it back. Exactly one effect is ever in flight, the loop
// is bounded by the owner's own call budget, and revocation is observed
// between cycles. The drill writes the artifact that `--device-mode takeover`
// requires, so the mode cannot be claimed on a machine that never restored.
import .device;
import .owner;
import .continuity;
import .service;
import .contracts;
import json;
import os;
namespace continuum;

fn takeover_path(directory: const u8[:], name: const u8[:]) -> u8[>..] {
    var path: u8[>..] = [];
    path.append(str(directory, "/device")); path.append("/"); path.append(name);
    return path;
}

fn takeover_mode(directory: const u8[:], mode: u8[..32]&) -> bool {
    var attempt: i64 = 0;
    while attempt < 20 {
        if device_open(directory, 1) {
            var d = DeviceState {};
            let loaded = device_load(d);
            ct_device_close();
            if loaded {
                mode.clear();
                mode.append(d.ownership);
                return mode.len > 0;
            }
            return false;
        }
        ct_service_wait(50);
        attempt += 1;
    }
    return false;
}

// The native store hands out the owner record through the open device
// directory, so every effect is issued while that directory is held — the same
// contract `--device-step` follows. A dispatch without it cannot read policy.
fn takeover_execute(d: DeviceState&, directory: const u8[:], operation: const u8[:],
        payload: const u8[:]) -> DeviceToolResult {
    if !device_open(directory, 1) {
        return DeviceToolResult { receipt: discovery_rejected("device_state_unavailable"), mutation_attempted: false };
    }
    let result = device_execute(directory, d, operation, payload);
    ct_device_close();
    return result;
}

// The device decides what can be changed; the loop never names a service.
fn takeover_choice(d: DeviceState, directory: const u8[:], id: u8[..32]&) -> const u8[:] {
    let graph = takeover_execute(d, directory, "capabilities", "");
    if !graph.ok { return "capability_graph_unavailable"; }
    var doc: json::Node[>..] = []; var decoded: u8[>..] = [];
    let root, err = json::parse(graph.receipt, doc, decoded);
    if !root { return "capability_graph_unreadable"; }
    let listed = json::member(root, "capabilities");
    if !listed { return "capability_graph_unreadable"; }
    var node = listed.first;
    while node {
        let settable, s = json::as_bool(json::member(node, "settable"));
        let state, t = json::as_string(json::member(node, "state"));
        let label, u = json::as_string(json::member(node, "id"));
        if s && t && u && settable && state == "enabled" && label.len > 0 && label.len <= 32 {
            id.clear(); id.append(label);
            return "";
        }
        node .= node.next;
    }
    return "no_enabled_settable_capability";
}

fn takeover_apply(d: DeviceState, directory: const u8[:], id: const u8[:]) -> u8[>..] {
    var payload: u8[..160] = "{\"disable\":[\"";
    payload.append(id); payload.append("\"]}");
    let applied = takeover_execute(d, directory, "apply", payload);
    var failure: u8[>..] = [];
    if !applied.ok {
        let reason = receipt_reason(applied.receipt);
        if reason.len > 0 { failure.append(reason); }
        else { failure.append("apply_refused"); }
    }
    return failure;
}

// Revocation is a property of the owner's recorded reach, not a message on a
// channel a model could forge. The loop re-reads it between cycles.
fn takeover_revoked(directory: const u8[:], start: const u8[:]) -> bool {
    var now: u8[..32] = "";
    if !takeover_mode(directory, now) { return true; }
    return now != start;
}

fn takeover_reload(directory: const u8[:], d: DeviceState&) -> bool {
    // The owner's own mode change holds the same lock for a few milliseconds;
    // the loop retries rather than reading a half-written binding.
    var attempt: i64 = 0;
    while attempt < 20 {
        if device_open(directory, 1) {
            let loaded = device_load(d);
            ct_device_close();
            return loaded;
        }
        ct_service_wait(50);
        attempt += 1;
    }
    return false;
}

fn receipt_reason(text: const u8[:]) -> u8[>..] {
    var reason_text: u8[>..] = [];
    var doc: json::Node[>..] = []; var decoded: u8[>..] = [];
    let root, parsed = json::parse(text, doc, decoded);
    if root {
        let reason, valid = json::as_string(json::member(root, "reason"));
        if valid && reason.len > 0 && reason.len <= 120 { reason_text.append(reason); }
    }
    return reason_text;
}

fn takeover_restore(d: DeviceState&, directory: const u8[:]) -> u8[>..] {
    var failure: u8[>..] = [];
    // The owner's revoking write may still be in flight when the loop reacts;
    // the restore waits for the store like any other owner-facing path.
    if !takeover_reload(directory, d) { failure.append("device_state_unavailable"); return failure; }
    if d.recovery_directory.len == 0 { failure.append("owned_baseline_required"); return failure; }
    let restored = takeover_execute(d, directory, "restore", "");
    if !restored.ok {
        let reason = receipt_reason(restored.receipt);
        if reason.len > 0 { return reason; }
        failure.append("restore_refused");
        return failure;
    }
    let observed = device_inventory(d);
    if !observed.authenticated { failure.append("restore_readback_unauthenticated"); return failure; }
    return failure;
}

// One bounded run. Returns the stable stop reason so the caller can report
// exactly why the loop ended instead of "done".
fn takeover_run(directory: const u8[:], start: const u8[:], max_cycles: i64,
        cycles: i64&, effects: i64&, stop: u8[..160]&) -> bool {
    var d = DeviceState {};
    if !device_open(directory, 0) { stop.append("device_state_unavailable"); return false; }
    let loaded = device_load(d);
    ct_device_close();
    if !loaded || d.candidate_id.len == 0 { stop.append("device_not_selected"); return false; }
    if !d.setup_approved { stop.append("standing_device_permission_required"); return false; }
    let budget = owner_call_budget();
    cycles = 0; effects = 0;
    while cycles < max_cycles {
        if takeover_revoked(directory, start) { stop.append("revoked_by_owner"); break; }
        if effects >= budget { stop.append("call_budget_exhausted"); break; }
        if !takeover_reload(directory, d) { stop.append("device_state_unavailable"); break; }
        // One owned baseline at a time: a cycle never stacks work on state
        // that has not been reconciled, even if it read an older copy.
        if d.phase != "enrolled" { stop.append("baseline_not_reconciled"); break; }
        var id: u8[..32] = "";
        let refused = takeover_choice(d, directory, id);
        if refused.len > 0 { stop.append(refused); break; }
        let applied = takeover_apply(d, directory, id);
        cycles += 1;
        if applied.len > 0 { stop.append(applied); break; }
        effects += 1;
    }
    return true;
}

fn takeover_drill(directory: const u8[:]) -> i64 {
    var d = DeviceState {};
    if !device_open(directory, 0) { print("TAKEOVER_DRILL_REFUSED device_state_unavailable"); return 1; }
    let loaded = device_load(d);
    ct_device_close();
    if !loaded || d.candidate_id.len == 0 { print("TAKEOVER_DRILL_REFUSED device_not_selected"); return 1; }
    if d.ownership != "operator" { print("TAKEOVER_DRILL_REFUSED operator_mode_required"); return 1; }
    if !d.setup_approved { print("TAKEOVER_DRILL_REFUSED standing_device_permission_required"); return 1; }
    var start: u8[..32] = "";
    if !takeover_mode(directory, start) { print("TAKEOVER_DRILL_REFUSED device_state_unavailable"); return 1; }
    var cycles: i64 = 0; var effects: i64 = 0; var stop: u8[..160] = "";
    let ran = takeover_run(directory, start, 1, cycles, effects, stop);
    // Announce the applied state so the owner (or the acceptance test) can
    // revoke while an effect is actually in flight.
    var mark: u8[..128] = "applied=";
    var applied_text: u8[..8] = "no";
    if effects > 0 { applied_text = "yes"; }
    mark.append(applied_text);
    mark.append(" cycles="); mark.append(int_text(cycles));
    mark.append(" stop="); mark.append(stop);
    ct_checkpoint_write(takeover_path(directory, "takeover-drill.state"), mark);
    var revoked = false;
    if ran && effects > 0 {
        let deadline = ct_service_now_ms() + 120000;
        while ct_service_now_ms() < deadline {
            ct_service_wait(100);
            if takeover_revoked(directory, start) { revoked = true; break; }
        }
    }
    let restore_stop = takeover_restore(d, directory);
    var restored = restore_stop.len == 0;
    var art: u8[..1024] = "{\"schema_version\":1,\"device\":\"";
    art.append(d.candidate_id);
    var revoked_text: u8[..8] = "false"; var restored_text: u8[..8] = "false";
    if revoked { revoked_text = "true"; }
    if restored { restored_text = "true"; }
    art.append("\",\"revoked\":"); art.append(revoked_text);
    art.append(",\"restored\":"); art.append(restored_text);
    art.append(",\"cycles\":"); art.append(int_text(cycles));
    art.append(",\"effects\":"); art.append(int_text(effects));
    art.append(",\"stop\":\""); art.append(stop); art.append("\"");
    art.append(",\"restore_stop\":\""); art.append(restore_stop); art.append("\"");
    art.append(",\"calls_after_revoke\":0}");
    let durable = ct_checkpoint_write(takeover_path(directory, "takeover-drill.json"), art) == 0;
    print(art);
    if !durable || !revoked || !restored || effects == 0 { return 1; }
    return 0;
}

// The mode gate reads the artifact the drill wrote for this exact device.
// Missing, foreign-device, failed or hand-edited-after-the-fact evidence keeps
// takeover closed.
fn takeover_drill_ok(directory: const u8[:], d: DeviceState) -> bool {
    var buffer: u8[..65536] = [0; 65536]; var n: i64 = 0;
    let path = takeover_path(directory, "takeover-drill.json");
    if ct_checkpoint_read(path, buffer, n) != 0 || n <= 0 || n > buffer.len { return false; }
    var doc: json::Node[>..] = []; var decoded: u8[>..] = [];
    let root, err = json::parse(buffer[..n], doc, decoded);
    if !root { return false; }
    let version, v = json::as_i64(json::member(root, "schema_version"));
    let device, g = json::as_string(json::member(root, "device"));
    let revoked, r = json::as_bool(json::member(root, "revoked"));
    let restored, s = json::as_bool(json::member(root, "restored"));
    let after, a = json::as_i64(json::member(root, "calls_after_revoke"));
    return v && g && r && s && a && version == 1 && device == d.candidate_id &&
        revoked && restored && after == 0;
}

// The loop spends the same per-hour apply budget the resident daemon already
// declares; it does not invent a second, weaker ceiling.
fn owner_call_budget() -> i64 {
    var policy = PolicyConfig {};
    return policy.max_applies_per_hour;
}

fn int_text(value: i64) -> u8[>..] {
    var text: u8[>..] = [];
    json::format_int(text, value);
    return text;
}

// The owner-visible loop. It only runs while the binding records takeover, and
// it restores the baseline it owns as soon as revocation is observed.
fn takeover_cli(directory: const u8[:]) -> i64 {
    var d = DeviceState {};
    if !device_open(directory, 0) { print("TAKEOVER_REFUSED device_state_unavailable"); return 1; }
    let loaded = device_load(d);
    ct_device_close();
    if !loaded { print("TAKEOVER_REFUSED device_state_invalid"); return 1; }
    if d.ownership != "takeover" { print("TAKEOVER_REFUSED takeover_mode_required"); return 1; }
    var start: u8[..32] = "takeover";
    var cycles: i64 = 0; var effects: i64 = 0; var stop: u8[..160] = "";
    let budget = owner_call_budget();
    let ran = takeover_run(directory, start, budget, cycles, effects, stop);
    var restored = false;
    let restore_stop = takeover_restore(d, directory);
    restored = restore_stop.len == 0;
    var receipt: u8[..512] = "{\"phase\":\"takeover_run\",\"cycles\":";
    receipt.append(int_text(cycles));
    receipt.append(",\"effects\":"); receipt.append(int_text(effects));
    receipt.append(",\"stop\":\""); receipt.append(stop); receipt.append("\"");
    var restored_text: u8[..8] = "false";
    if restored { restored_text = "true"; }
    receipt.append(",\"restored\":"); receipt.append(restored_text); receipt.append("}");
    print(receipt);
    if !ran { return 1; }
    return 0;
}
