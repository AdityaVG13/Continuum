// One owner-selected device across setup, commissioning and the resident.
// Goose owns transitions; native storage locks the binding and fsyncs intent
// before effects. A saved phase is not current identity or network readiness.
import .commission;
import .owner;
import .discovery;
import .takeover;
import json;
import os;
namespace continuum;

extern fn ct_setup_device_open(path: const u8[:], exclusive: i32) -> i32;
extern fn ct_setup_device_load(out: u8[:], length: i64&) -> i32;
extern fn ct_setup_device_store(data: const u8[:]) -> i32;
extern fn ct_device_close() -> i32;

struct DeviceState {
    candidate_id: u8[..64] = "",
    connection: LeapConfig = LeapConfig {},
    phase: u8[..64] = "unselected",
    ownership: u8[..16] = "observer",
    productid: u8[..64] = "",
    mac: u8[..64] = "",
    firmware: u8[..128] = "",
    setup_approved: bool = false,
    runtime_verified: bool = false,
    recovery_verified: bool = false,
    persistence_verified: bool = false,
    network_load_verified: bool = false,
    baseline_at: i64 = 0,
    recovery_directory: u8[..512] = "",
    knowledge: u8[..2048] = "",
    last_exchange: u8[..3072] = "",
    reason: u8[..256] = "",
}
struct DeviceObservation {
    authenticated: bool = false,
    reason: u8[..256] = "not_selected",
    receipt: u8[..8192] = "{}",
}

fn device_record(d: DeviceState) -> u8[>..] {
    var out: u8[>..] = [];
    out.append("{\"schema_version\":3,\"candidate_id\":"); json::format_string(out, d.candidate_id);
    out.append(",\"connection\":{\"host\":"); json::format_string(out, d.connection.host);
    out.append(",\"port\":"); json::format_int(out, d.connection.port);
    out.append(",\"interface_id\":"); json::format_string(out, d.connection.interface_id);
    out.append(",\"ssid_stem\":"); json::format_string(out, d.connection.ssid_stem);
    out.append(",\"admin_user\":"); json::format_string(out, d.connection.admin_user);
    out.append(",\"admin_ref\":"); json::format_string(out, d.connection.admin_ref);
    out.append(",\"psk_ref\":"); json::format_string(out, d.connection.psk_ref);
    out.append(",\"control_rides_wifi\":"); json::format_bool(out, d.connection.control_rides_wifi);
    out.append("},\"identity\":{\"productid\":"); json::format_string(out, d.productid);
    out.append(",\"mac\":"); json::format_string(out, d.mac);
    out.append(",\"firmware\":"); json::format_string(out, d.firmware);
    out.append("},\"phase\":"); json::format_string(out, d.phase);
    out.append(",\"ownership\":"); json::format_string(out, d.ownership);
    out.append(",\"setup_approved\":"); json::format_bool(out, d.setup_approved);
    out.append(",\"runtime_verified\":"); json::format_bool(out, d.runtime_verified);
    out.append(",\"recovery_verified\":"); json::format_bool(out, d.recovery_verified);
    out.append(",\"persistence_verified\":"); json::format_bool(out, d.persistence_verified);
    out.append(",\"network_load_verified\":"); json::format_bool(out, d.network_load_verified);
    // Ready is derived, never an independent claim: every gate plus a measured
    // loaded run must hold at once, and a record whose ready bit disagrees with
    // its gates fails to load instead of granting reach.
    out.append(",\"ready\":"); json::format_bool(out, d.setup_approved && d.runtime_verified &&
        d.recovery_verified && d.persistence_verified && d.network_load_verified);
    out.append(",\"baseline_at\":"); json::format_int(out, d.baseline_at);
    out.append(",\"recovery_directory\":");
    json::format_string(out, d.recovery_directory);
    out.append(",\"knowledge\":"); json::format_string(out, d.knowledge);
    out.append(",\"last_exchange\":"); json::format_string(out, d.last_exchange);
    out.append(",\"reason\":"); json::format_string(out, d.reason); out.append("}");
    return out;
}

fn device_load(d: DeviceState&) -> bool {
    var buffer: u8[..16384] = [0; 16384]; var n: i64 = 0;
    if ct_setup_device_load(buffer, n) != 0 || n < 0 || n > buffer.len { return false; }
    if n == 0 { d = DeviceState {}; return true; }
    var doc: json::Node[>..] = []; var decoded: u8[>..] = [];
    let root, err = json::parse(buffer[..n], doc, decoded);
    let known: const u8[:][..17] = ["schema_version", "candidate_id", "connection", "identity", "phase",
        "ownership", "setup_approved", "runtime_verified", "recovery_verified", "persistence_verified",
        "network_load_verified", "ready", "baseline_at", "recovery_directory", "reason", "knowledge", "last_exchange"];
    let conn = json::member(root, "connection"); let identity = json::member(root, "identity");
    let connection_keys: const u8[:][..8] = ["host", "port", "interface_id", "ssid_stem", "admin_user", "admin_ref", "psk_ref", "control_rides_wifi"];
    let identity_keys: const u8[:][..3] = ["productid", "mac", "firmware"];
    if !root || !no_unknown(root, known) || !conn || !no_unknown(conn, connection_keys) ||
            !identity || !no_unknown(identity, identity_keys) { return false; }
    let version, v = json::as_i64(json::member(root, "schema_version"));
    let candidate, c = json::as_string(json::member(root, "candidate_id"));
    let host, h = json::as_string(json::member(conn, "host"));
    let port, p = json::as_i64(json::member(conn, "port"));
    let iface, i = json::as_string(json::member(conn, "interface_id"));
    let stem, s = json::as_string(json::member(conn, "ssid_stem"));
    let user, u = json::as_string(json::member(conn, "admin_user"));
    let admin, a = json::as_string(json::member(conn, "admin_ref"));
    let psk, k = json::as_string(json::member(conn, "psk_ref"));
    let wifi, w = json::as_bool(json::member(conn, "control_rides_wifi"));
    let product, pr = json::as_string(json::member(identity, "productid"));
    let mac, ma = json::as_string(json::member(identity, "mac"));
    let firmware, fi = json::as_string(json::member(identity, "firmware"));
    let phase, ph = json::as_string(json::member(root, "phase"));
    // Ownership mode is owner-selected state. v1 records predate it and load as
    // observer; a v2 record must name a mode, so a hand-edited file cannot
    // silently acquire reach it never had.
    var ownership: u8[..16] = "observer";
    if json::member(root, "ownership") {
        let mode, mo = json::as_string(json::member(root, "ownership"));
        if !mo || !valid_id(mode, 16) ||
                (mode != "observer" && mode != "advisor" && mode != "operator" && mode != "takeover") { return false; }
        ownership = mode;
    } else if version != 1 {
        return false;
    }
    let approved, ap = json::as_bool(json::member(root, "setup_approved"));
    let runtime, rt = json::as_bool(json::member(root, "runtime_verified"));
    let recovery, re = json::as_bool(json::member(root, "recovery_verified"));
    let persistence, pe = json::as_bool(json::member(root, "persistence_verified"));
    let load, lo = json::as_bool(json::member(root, "network_load_verified"));
    let ready, rd = json::as_bool(json::member(root, "ready"));
    // A qualification is only meaningful relative to the baseline it measured;
    // v3 records carry that instant, older records cannot claim one.
    var baseline_ns: i64 = 0;
    if json::member(root, "baseline_at") {
        let value, value_ok = json::as_i64(json::member(root, "baseline_at"));
        if !value_ok { return false; }
        if value < 0 { return false; }
        baseline_ns = value;
    } else if version != 1 && version != 2 { return false; }
    let directory, di = json::as_string(json::member(root, "recovery_directory"));
    let reason, rs = json::as_string(json::member(root, "reason"));
    // A record may not claim readiness its gates do not support: v3 derives it,
    // and a v1/v2 record may never carry either bit.
    var derived_ready = false;
    if approved {
        if runtime {
            if recovery {
                if persistence {
                    if load { derived_ready = true; }
                }
            }
        }
    }
    if version >= 3 && ready != derived_ready { return false; }
    if !v || (version != 1 && version != 2 && version != 3) || !c || !h || !p || !i || !s || !u || !a || !k || !w || !pr || !ma || !fi ||
            !ph || !ap || !rt || !re || !pe || !lo || !rd || !di || !rs || (version != 3 && (load || ready)) ||
            !valid_id(candidate, 64) || !valid_id(host, 64) || router_prefix(host).len == 0 ||
            !valid_id(iface, 64) || candidate != str(iface, ":", host) || !valid_id(stem, 27) ||
            !valid_id(user, 32) || !valid_id(admin, 128) || !valid_id(psk, 128) || port < 1 || port > 65535 ||
            product.len > 64 || mac.len > 64 || firmware.len > 128 || directory.len > 512 || reason.len > 256 {
        return false;
    }
    if phase != "selected" && phase != "enrolling" && phase != "enrolled" && phase != "commissioning" &&
            phase != "baseline_applied" && phase != "reboot_pending" && phase != "network_qualification_required" { return false; }
    d = DeviceState { candidate_id: candidate, phase: phase, ownership: ownership, productid: product, mac: mac, firmware: firmware,
        setup_approved: approved, runtime_verified: runtime, recovery_verified: recovery,
        persistence_verified: persistence, network_load_verified: load, baseline_at: baseline_ns,
        recovery_directory: directory, reason: reason };
    d.connection = LeapConfig { host: host, port: port, interface_id: iface, ssid_stem: stem,
        admin_user: user, admin_ref: admin, psk_ref: psk, control_rides_wifi: wifi, rejoin: wifi };
    // Existing bindings acquire empty context, never new authority.
    if json::member(root, "knowledge") {
        let note, valid = json::as_string(json::member(root, "knowledge"));
        if !valid || note.len > 2048 { return false; }
        d.knowledge = note;
    }
    if json::member(root, "last_exchange") {
        let exchange, valid = json::as_string(json::member(root, "last_exchange"));
        if !valid || exchange.len > 3072 { return false; }
        d.last_exchange = exchange;
    }
    return true;
}
fn device_save(d: DeviceState) -> bool {
    let record = device_record(d);
    return record.len <= 16384 && ct_setup_device_store(record) == 0;
}
fn device_open(directory: const u8[:], exclusive: i32) -> bool {
    return directory.len > 0 && ct_setup_device_open(str(directory, "/device"), exclusive) == 0;
}
fn device_saved(directory: const u8[:], d: DeviceState&) -> bool {
    if !device_open(directory, 0) { return false; }
    let ok = device_load(d); ct_device_close(); return ok;
}

// Takeover is the product's headline mode, so it stays unselectable until this
// exact device has passed the revocation drill. The artifact is re-read on
// every attempt rather than cached in the state file, so a stale or hand-edited
// record cannot make the mode claim reach the product never proved.
fn ownership_selectable(directory: const u8[:], d: DeviceState, mode: const u8[:]) -> bool {
    if mode == "observer" || mode == "advisor" || mode == "operator" { return true; }
    return mode == "takeover" && takeover_drill_ok(directory, d);
}

fn device_set_mode(directory: const u8[:], mode: const u8[:]) -> const u8[:] {
    if mode != "observer" && mode != "advisor" && mode != "operator" && mode != "takeover" {
        return "unknown_ownership_mode";
    }
    if !device_open(directory, 1) { return "device_state_unavailable"; }
    var d = DeviceState {};
    if !device_load(d) { ct_device_close(); return "device_state_invalid"; }
    if d.candidate_id.len == 0 { ct_device_close(); return "device_not_selected"; }
    if !ownership_selectable(directory, d, mode) {
        ct_device_close();
        return "takeover_unavailable_resident_loop_and_revocation_drill_required";
    }
    d.ownership = mode;
    let saved = device_save(d);
    ct_device_close();
    if !saved { return "device_result_not_durable"; }
    return "";
}

fn device_select(directory: const u8[:], observed: const u8[:], candidate: const u8[:],
        stem: const u8[:], port: i64, existing_credentials: bool = false, reset_proven: bool = false) -> bool {
    if !valid_id(candidate, 64) || !valid_id(stem, 27) || port < 1 || port > 65535 || !device_open(directory, 1) { return false; }
    var old = DeviceState {};
    // Re-selecting the same candidate is the owner's recovery action after a
    // factory reset: the saved binding is stale (its minted admin is gone) and
    // the only way back to the ceremony is to discard it. A different candidate
    // still cannot clobber a live binding; selection requires an unbound record.
    // reset_proven: the bound router refused the saved admin password, so the
    // binding is stale even if the router is now reached over another link.
    if !device_load(old) || (old.candidate_id.len > 0 && old.phase != "selected" && old.candidate_id != candidate && !reset_proven) {
        ct_device_close(); return false;
    }
    var doc: json::Node[>..] = []; var decoded: u8[>..] = [];
    let root, err = json::parse(observed, doc, decoded);
    let candidates = json::member(root, "candidates");
    if !root || !candidates { ct_device_close(); return false; }
    var c = candidates.first;
    while c {
        let id, has_id = json::as_string(json::member(c, "candidate_id"));
        let host, h = json::as_string(json::member(c, "address"));
        let iface, i = json::as_string(json::member(c, "interface"));
        if has_id && id == candidate && h && i && valid_id(host, 64) && valid_id(iface, 64) &&
                candidate == str(iface, ":", host) && router_prefix(host).len > 0 {
            var kind: u8[..16] = "";
            let interfaces = json::member(root, "interfaces");
            if interfaces {
                var link = interfaces.first;
                while link {
                    let name, named = json::as_string(json::member(link, "name"));
                    let value, typed = json::as_string(json::member(link, "kind"));
                    let up, known_up = json::as_bool(json::member(link, "up"));
                    if named && name == iface && typed && value.len <= 16 && known_up && up { kind = value; }
                    link .= link.next;
                }
            }
            if kind != "wifi" && kind != "ethernet" { ct_device_close(); return false; }
            var d = DeviceState { candidate_id: candidate, phase: "selected" };
            d.connection = LeapConfig { host: host, port: port, interface_id: iface, ssid_stem: stem,
                control_rides_wifi: kind == "wifi", rejoin: kind == "wifi" };
            // Per-enrollment identities, not the address's old credential slots.
            let enrollment = str("continuum.device.", time_ns());
            d.connection.admin_ref = if existing_credentials { leap_admin_ref(host) } else { str(enrollment, ".admin") };
            d.connection.psk_ref = if existing_credentials { leap_psk_ref(host) } else { str(enrollment, ".psk") };
            let ok = device_save(d); ct_device_close(); return ok;
        }
        c .= c.next;
    }
    ct_device_close(); return false;
}

// A fresh authenticated receipt must match the enrolled device AND firmware.
// Credentials or an unchanged IP alone cannot carry readiness to another box.
fn device_identity(d: DeviceState&, raw: const u8[:]) -> bool {
    var doc: json::Node[>..] = []; var decoded: u8[>..] = [];
    let root, err = json::parse(raw, doc, decoded);
    let authenticated, a = json::as_bool(json::member(root, "authenticated"));
    let settings = json::member(root, "settings");
    let product, p = json::as_string(json::member(settings, "productid"));
    let mac, m = json::as_string(json::member(settings, "lan_hwaddr"));
    let version, v = json::as_string(json::member(settings, "firmver"));
    let build, b = json::as_string(json::member(settings, "buildno"));
    let extend, e = json::as_string(json::member(settings, "extendno"));
    let configured, x = json::as_string(json::member(settings, "x_Setting"));
    if !root || !a || !authenticated || !settings || !p || !m || !v || !b || !e || !x || configured != "1" ||
            product.len == 0 || product.len > 64 || mac.len == 0 || mac.len > 64 || version.len == 0 {
        d.reason = "authenticated_device_identity_unavailable"; return false;
    }
    let firmware = str(version, "/", build, "/", extend);
    if firmware.len > 128 { d.reason = "firmware_identity_over_bound"; return false; }
    if d.mac.len > 0 && (d.mac != mac || d.productid != product || d.firmware != firmware) {
        d.reason = "device_identity_changed"; return false;
    }
    d.mac = mac; d.productid = product; d.firmware = firmware; d.reason = ""; return true;
}
fn device_inventory(d: DeviceState, authorize: bool = false) -> DeviceObservation {
    if d.candidate_id.len == 0 { return DeviceObservation {}; }
    // A reset unit would only count a refused login against the real one to
    // come (see leap_factory_open). Skipped while a reboot is awaited: the
    // unit is configured then and the probe would only double each timeout.
    if d.phase != "reboot_pending" && leap_factory_open(d.connection) {
        return DeviceObservation { reason: "protected_authentication_refused_factory_unit" };
    }
    var raw: u8[>..] = [];
    if !commission_request(d.connection, if authorize { "authorize" } else { "inspect" }, "", false, raw, true) || raw.len > 8192 {
        var why: u8[..256] = "protected_device_observation_unavailable";
        var doc: json::Node[>..] = []; var decoded: u8[>..] = [];
        let root, err = json::parse(raw, doc, decoded);
        let reason, r = json::as_string(json::member(root, "reason"));
        if r && reason.len <= 256 { why = reason; }
        return DeviceObservation { reason: why };
    }
    var checked = d;
    if !device_identity(checked, raw) { return DeviceObservation { reason: checked.reason }; }
    return DeviceObservation { authenticated: true, reason: "", receipt: raw };
}
fn device_view(d: DeviceState, observed: DeviceObservation) -> u8[>..] {
    var out: u8[>..] = [];
    out.append("{\"candidate_id\":"); json::format_string(out, d.candidate_id);
    out.append(",\"host\":"); json::format_string(out, d.connection.host);
    out.append(",\"port\":"); json::format_int(out, d.connection.port);
    out.append(",\"phase\":"); json::format_string(out, d.phase);
    out.append(",\"authenticated\":"); json::format_bool(out, observed.authenticated);
    out.append(",\"ready\":false,\"reason\":");
    json::format_string(out, if observed.authenticated { d.reason } else { observed.reason });
    out.append(",\"inventory\":"); out.append(observed.receipt); out.append("}"); return out;
}

// Caller holds the exclusive binding lock. Persist ambiguous-effect phases
// before dispatch; retrying setup may inspect/verify but never replay enrollment,
// a baseline write or reboot just because a previous response was lost.
fn device_enroll(directory: const u8[:], d: DeviceState&, execute: bool) -> bool {
    if !execute && !d.setup_approved { d.reason = "standing_setup_permission_required"; return false; }
    d.setup_approved = true;
    if !device_save(d) { return false; }
    if d.phase == "selected" || d.phase == "enrolling" {
        var observed = device_inventory(d);
        // A retry after an interrupted ceremony: the unit may already be on the
        // renamed radio this host has not rejoined. Rejoin, then re-probe.
        if !observed.authenticated && d.phase == "enrolling" && d.connection.rejoin && leap_rejoin_renamed(d.connection) {
            observed = device_inventory(d);
        }
        // A unit that does not answer the staged credential is either factory
        // (no credential works yet) or configured under a different password.
        // Either way the ceremony's first act is a read-only factory login: it
        // refuses a configured unit instead of writing, so an unfinished
        // attempt may re-probe. Completed enrollment never reaches here.
        if !observed.authenticated {
            d.phase = "enrolling";
            if !device_save(d) { return false; }
            var cfg = d.connection; cfg.execute = true;
            let enrolled = run_leap(cfg);
            if !enrolled.ok { d.reason = enrolled.reason; return false; }
            observed = device_inventory(d);
        }
        if !observed.authenticated || !device_identity(d, observed.receipt) {
            d.reason = if observed.authenticated { d.reason } else { observed.reason }; return false;
        }
        d.phase = "enrolled";
        d.network_load_verified = false; d.baseline_at = 0;
        if !device_save(d) { return false; }
    }
    // Enrollment is a capability. The model chooses commissioning work and
    // subsequent verification; setup must never imply a cleanup or reboot.
    d.reason = "model_directed_commissioning_pending";
    return device_save(d);
}
fn device_request_reboot(d: DeviceState&) -> bool {
    if d.recovery_directory.len == 0 || d.phase != "baseline_applied" {
        d.reason = "verified_owned_baseline_required"; return false;
    }
    let observed = device_inventory(d);
    if !observed.authenticated || !d.runtime_verified || !d.recovery_verified {
        d.reason = observed.reason; return false;
    }
    d.phase = "reboot_pending";
    if !device_save(d) { return false; }
    var raw: u8[>..] = [];
    let ok = commission_request(d.connection, "reboot", d.recovery_directory, true, raw, true, "", true);
    d.reason = if ok { "owner_reboot_requested_verify_after_return" } else { "reboot_outcome_unknown_verify_before_retry" };
    return ok;
}
// Owner-facing QoS step. The model path narrates the demo, but an owner must be
// able to apply or undo the qdisc without a provider call, and a lab A/B that
// depends on a paid model call is not a controlled measurement.
fn device_qos_step(directory: const u8[:], payload: const u8[:], restore: bool) -> i64 {
    if !device_open(directory, 1) {
        print("DEVICE_REFUSED binding busy or private storage unavailable");
        return 1;
    }
    var d = DeviceState {};
    if !device_load(d) || d.candidate_id.len == 0 {
        ct_device_close(); print("DEVICE_REFUSED select an observed device first"); return 1;
    }
    let result = device_qos(d, directory, if restore { "restore_qos" } else { "apply_qos" }, payload);
    ct_device_close();
    if result.receipt.len > 0 { print(result.receipt); }
    if !result.ok { return 1; }
    return 0;
}

// Qualification is the last gate and the only one a measurement may open. The
// evidence is produced by --measure, which already refuses an unsampled or
// failed run; this step re-checks the file, the sample floor and the ordering,
// so an old artifact or a model conclusion cannot manufacture readiness.
fn device_qualify(directory: const u8[:], evidence: const u8[:], execute: bool) -> i64 {
    if !device_open(directory, 1) { print("DEVICE_REFUSED binding busy or private storage unavailable"); return 1; }
    var d = DeviceState {};
    if !device_load(d) || d.candidate_id.len == 0 {
        ct_device_close(); print("DEVICE_REFUSED select an observed device first; invalid state is not replaced"); return 1;
    }
    var ok = false;
    if !execute {
        d.reason = "explicit_execute_permission_required";
    } else if d.phase != "network_qualification_required" || !d.runtime_verified || !d.recovery_verified || !d.persistence_verified {
        d.reason = "runtime_recovery_and_persistence_verification_required";
    } else if evidence.len == 0 || evidence.len > 1024 {
        d.reason = "measurement_evidence_required";
    } else {
        var raw: u8[>..] = [];
        if !read_file(evidence, raw) || raw.len == 0 || raw.len > 65536 {
            d.reason = "measurement_evidence_unreadable";
        } else {
            var doc: json::Node[>..] = [];
            var decoded: u8[>..] = [];
            let root, err = json::parse(raw, doc, decoded);
            let verdict, has_verdict = json::as_string(json::member(root, "verdict"));
            let measured, has_measured = json::as_i64(json::member(root, "measured_at"));
            let body = json::member(root, "evidence");
            let idle, idle_ok = json::as_i64(json::member(body, "idle_samples"));
            let loaded, loaded_ok = json::as_i64(json::member(body, "loaded_samples"));
            let bytes, bytes_ok = json::as_i64(json::member(body, "load_bytes"));
            if !root || !has_verdict || !has_measured || verdict != "claimable" {
                d.reason = "measurement_not_claimable";
            } else if !idle_ok || !loaded_ok || !bytes_ok || idle < MEASURE_MIN_SAMPLES ||
                    loaded < MEASURE_MIN_SAMPLES || bytes <= 0 {
                d.reason = "measurement_below_sample_floor";
            } else if measured <= d.baseline_at {
                d.reason = "evidence_predates_baseline";
            } else {
                d.network_load_verified = true;
                d.reason = "routed_load_measured_ready";
                ok = true;
            }
        }
    }
    if !device_save(d) { ok = false; }
    print(device_record(d)); ct_device_close();
    if !ok { return 1; }
    return 0;
}

// Whether this host still holds an address in the router's /24 on the bound
// interface. A Wi-Fi control link that lost its association holds none.
fn device_link_holds(d: DeviceState) -> bool {
    let prefix = router_prefix(d.connection.host);
    if prefix.len == 0 { return true; }
    let host = discover_host();
    var doc: json::Node[>..] = []; var decoded: u8[>..] = [];
    let root, err = json::parse(host, doc, decoded);
    let interfaces = json::member(root, "interfaces");
    if !root || !interfaces { return true; }
    var link = interfaces.first;
    while link {
        let name, n = json::as_string(json::member(link, "name"));
        let address, a = json::as_string(json::member(link, "address"));
        if n && a && name == d.connection.interface_id && address.len > prefix.len && address[..prefix.len] == prefix { return true; }
        link .= link.next;
    }
    return false;
}
fn device_step(directory: const u8[:], action: const u8[:], execute: bool) -> i64 {
    if !device_open(directory, 1) { print("DEVICE_REFUSED binding busy or private storage unavailable"); return 1; }
    var d = DeviceState {};
    if !device_load(d) || d.candidate_id.len == 0 {
        ct_device_close(); print("DEVICE_REFUSED select an observed device first; invalid state is not replaced"); return 1;
    }
    if execute && (action == "reboot" || action == "restore") {
        let refused = owner_admit(action, 0, true);
        if refused.len > 0 { ct_device_close(); print(discovery_rejected(refused)); return 1; }
    }
    var ok = false;
    if action == "revoke" && execute {
        d.setup_approved = false; d.reason = "owner_revoked_standing_device_permission"; ok = true;
    } else if action == "inspect" || action == "authorize" {
        var observed = device_inventory(d, action == "authorize");
        // After a reboot the router's radios return on their own schedule and
        // macOS does not always rejoin them (seen live: en0 left unassociated).
        // When this host has lost its address on the router's link, rejoin the
        // renamed Wi-Fi; the protected read afterwards is still the proof.
        if !observed.authenticated && d.phase == "reboot_pending" && d.connection.rejoin &&
                !device_link_holds(d) && leap_rejoin_renamed(d.connection) {
            observed = device_inventory(d, action == "authorize");
        }
        if observed.authenticated && device_identity(d, observed.receipt) {
            if d.phase == "selected" || d.phase == "enrolling" { d.phase = "enrolled"; }
            ok = true;
        } else { d.reason = observed.reason; }
    } else if action == "reboot" && execute {
        ok = device_request_reboot(d);
    } else if action == "enroll" {
        // Creating the admin credential is the authentication boundary. It takes
        // the owner's explicit execute, never a standing grant or a model field,
        // and it is the one deterministic step on a factory-pending unit: a
        // reset router has no admin password to type, so the program mints one,
        // stores it in the credential vault and proves it by login.
        if !execute {
            d.reason = "explicit_execute_permission_required";
        } else {
            let refused = owner_admit("enroll", 0, true);
            if refused.len > 0 { d.reason = refused; }
            else { ok = device_enroll(directory, d, true); }
        }
    } else if action == "verify" && execute {
        // Persistence is the device's own proof, never a model conclusion: a
        // changed boot identity and every owned setting still in force. The
        // owner's confirmed step is the approval; no owned setting is written.
        let proof = device_execute(directory, d, "verify", "", true);
        if proof.receipt.len > 0 { print(proof.receipt); }
        ok = proof.ok && d.persistence_verified;
        if !ok {
            // The adapter's refusal (reboot_not_observed, unreachable...) is the
            // fact the owner acts on; a generic "unresolved" would hide it.
            var doc: json::Node[>..] = []; var decoded: u8[>..] = [];
            let root, err = json::parse(proof.receipt, doc, decoded);
            let why, w = json::as_string(json::member(root, "reason"));
            if w && why.len > 0 && why.len <= 200 { d.reason = why; } else { d.reason = "persistence_unverified"; }
        }
    } else if action == "qos-status" {
        // Read-only preflight for the optimization effect: proves the qdisc
        // tool is present and reports the current root before any window.
        let preflight = device_qos(d, directory, "read_qos", "");
        ok = preflight.ok;
        if preflight.receipt.len > 0 { print(preflight.receipt); }
        else { d.reason = "qos_preflight_unavailable"; }
    } else if action == "restore" && execute && d.recovery_directory.len > 0 {
        let observed = device_inventory(d);
        if observed.authenticated {
            var raw: u8[>..] = [];
            ok = commission_request(d.connection, "restore", d.recovery_directory, true, raw) && device_identity(d, raw);
            if ok {
                d.phase = "enrolled"; d.runtime_verified = false; d.recovery_verified = false; d.persistence_verified = false;
                d.network_load_verified = false; d.baseline_at = 0;
            }
        } else { d.reason = observed.reason; }
    } else { d.reason = "unsupported_action_or_explicit_execute_permission_missing"; }
    if !device_save(d) { ok = false; }
    print(device_record(d)); ct_device_close();
    if !ok { return 1; }
    return 0;
}
