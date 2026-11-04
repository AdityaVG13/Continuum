// The post-enrollment commissioning boundary. A protected inventory is not a
// ready device; native receipts retain the unverified runtime/recovery gates.
// Policy/orchestration stays here; credentials never leave the native adapter.
import .leap;
import json;
namespace continuum;

extern fn ct_asus_commission_json(req: const u8[:], receipt: u8[:], receipt_len: i64&) -> i32;

// A QoS profile is validated before any device I/O: the caller chooses values,
// never a shell string. The native adapter rechecks the same bounds.
struct QosProfile {
    bandwidth_kbps: i64 = 0,
    interface_id: u8[..8] = "",
    mode: u8[..16] = "",
    overhead_bytes: i64 = 0,
}

fn commission_authenticated(text: const u8[:]) -> bool {
    var doc: json::Node[>..] = [];
    var decoded: u8[>..] = [];
    let root, err = json::parse(text, doc, decoded);
    let authenticated, valid_auth = json::as_bool(json::member(root, "authenticated"));
    if !root || !valid_auth || !authenticated { return false; }
    return true;
}


fn commission_request(cfg: LeapConfig, action: const u8[:], directory: const u8[:], execute: bool,
        result: u8[>..]&, quiet: bool = false, disable: const u8[:] = "",
        owner_reboot_approved: bool = false) -> bool {
    if action != "inspect" && action != "apply" && action != "restore"
            && action != "authorize" && action != "runtime"
            && action != "reboot" && action != "verify" && action != "capabilities" {
        if !quiet { print("COMMISSION_REFUSED unsupported action"); }
        return false;
    }
    var bind: u8[>..] = [];
    bind.append(cfg.bind_addr);
    if bind.len == 0 && cfg.interface_id.len > 0 {
        var iface_req: u8[>..] = [];
        var iface_resp: u8[>..] = [];
        if host_iface_request(cfg, iface_req) && leap_call(6, iface_req, iface_resp) == 0 {
            let info = parse_iface_receipt(iface_resp);
            if info.ok { bind.append(info.ip); }
        }
    }
    // A reboot may make macOS roam to another network. Recover only the
    // enrolled Wi-Fi path, with explicit permission and no caller-supplied bind
    // to reinterpret. The native protected read still proves device identity.
    if action == "verify" && execute && cfg.control_rides_wifi && cfg.rejoin
            && cfg.bind_addr.len == 0 {
        let prefix = router_prefix(cfg.host);
        if prefix.len > 0 && (bind.len < prefix.len || bind[..prefix.len] != prefix) {
            var joined = false;
            var band: i64 = 2;
            while band >= 0 && !joined {
                var ssid: u8[>..] = [];
                ssid.append(cfg.ssid_stem);
                if band == 2 { ssid.append("_5G2"); }
                else if band == 1 { ssid.append("_5G"); }
                else { ssid.append("_2G"); }
                var join_req: u8[>..] = [];
                var join_resp: u8[>..] = [];
                if host_rejoin_request(cfg, ssid, true, 30, join_req) {
                    let status = leap_call(5, join_req, join_resp);
                    let info = parse_rejoin_receipt(join_resp);
                    if status == 0 && info.ok && info.joined {
                        bind = info.ip;
                        joined = true;
                    }
                }
                band--;
            }
            if !joined {
                if !quiet { print("COMMISSION_FAILED enrolled_wifi_rejoin_failed"); }
                return false;
            }
        }
    }
    var req: u8[>..] = [];
    if !valid_id(cfg.admin_user, 32) || !valid_id(cfg.admin_ref, 128)
            || !leap_common(cfg, bind, req) {
        if !quiet { print("COMMISSION_REFUSED invalid target or credential reference"); }
        return false;
    }
    req.append(",\"admin_user\":");
    json::format_string(req, cfg.admin_user);
    req.append(",\"admin_ref\":");
    json::format_string(req, cfg.admin_ref);
    req.append(",\"action\":");
    json::format_string(req, action);
    req.append(",\"directory\":");
    json::format_string(req, directory);
    req.append(",\"execute\":");
    json::format_bool(req, execute);
    req.append(",\"owner_reboot_approved\":"); json::format_bool(req, owner_reboot_approved);
    // The selection is capability ids the device itself reported, not keys the
    // controller knows. The adapter resolves them and refuses unknown ids.
    req.append(",\"disable\":"); json::format_string(req, disable); req.append("}");
    var receipt: u8[..16384] = [0; 16384];
    var n: i64 = 0;
    let rc = ct_asus_commission_json(req, receipt, n);
    if n > 0 && n <= receipt.len { result.append(receipt[..n]); }
    if rc != 0 || n <= 0 || n > receipt.len {
        if !quiet { print("COMMISSION_FAILED status=", rc, " reason=", leap_reason(rc)); }
        return false;
    }
    if !commission_authenticated(receipt[..n]) {
        if !quiet { print("COMMISSION_FAILED malformed or unauthenticated receipt"); }
        return false;
    }
    return true;
}

// QoS uses the same transport, credential reference and authentication proof
// as the service cleanup path, but keeps its own effect class: the baseline is
// the interface's qdisc state and restore returns the kernel-default root.
fn commission_qos(cfg: LeapConfig, directory: const u8[:], execute: bool, op: const u8[:],
        qos: QosProfile, result: u8[>..]&, quiet: bool = false) -> bool {
    if op != "apply" && op != "restore" && op != "status" {
        if !quiet { print("COMMISSION_REFUSED unsupported qos operation"); }
        return false;
    }
    var bind: u8[>..] = [];
    bind.append(cfg.bind_addr);
    if bind.len == 0 && cfg.interface_id.len > 0 {
        var iface_req: u8[>..] = [];
        var iface_resp: u8[>..] = [];
        if host_iface_request(cfg, iface_req) && leap_call(6, iface_req, iface_resp) == 0 {
            let info = parse_iface_receipt(iface_resp);
            if info.ok { bind.append(info.ip); }
        }
    }
    var req: u8[>..] = [];
    if !valid_id(cfg.admin_user, 32) || !valid_id(cfg.admin_ref, 128)
            || !leap_common(cfg, bind, req) {
        if !quiet { print("COMMISSION_REFUSED invalid target or credential reference"); }
        return false;
    }
    req.append(",\"admin_user\":");
    json::format_string(req, cfg.admin_user);
    req.append(",\"admin_ref\":");
    json::format_string(req, cfg.admin_ref);
    req.append(",\"action\":\"qos\",\"directory\":");
    json::format_string(req, directory);
    req.append(",\"execute\":");
    json::format_bool(req, execute);
    req.append(",\"qos_op\":");
    json::format_string(req, op);
    req.append(",\"qos_interface\":");
    json::format_string(req, qos.interface_id);
    req.append(",\"qos_mode\":");
    json::format_string(req, qos.mode);
    req.append(",\"qos_bandwidth_kbps\":");
    json::format_int(req, qos.bandwidth_kbps);
    req.append(",\"qos_overhead_bytes\":");
    json::format_int(req, qos.overhead_bytes);
    req.append("}");
    var receipt: u8[..16384] = [0; 16384];
    var n: i64 = 0;
    let rc = ct_asus_commission_json(req, receipt, n);
    if n > 0 && n <= receipt.len { result.append(receipt[..n]); }
    if rc != 0 || n <= 0 || n > receipt.len {
        if !quiet { print("COMMISSION_FAILED status=", rc, " reason=", leap_reason(rc)); }
        return false;
    }
    if !commission_authenticated(receipt[..n]) {
        if !quiet { print("COMMISSION_FAILED malformed or unauthenticated receipt"); }
        return false;
    }
    return true;
}

fn commission_run(cfg: LeapConfig, action: const u8[:], directory: const u8[:], execute: bool,
        owner_reboot_approved: bool = false, disable: const u8[:] = "") -> bool {
    var receipt: u8[>..] = [];
    let ok = commission_request(cfg, action, directory, execute, receipt, false, disable, owner_reboot_approved);
    if receipt.len > 0 { print(receipt); }
    return ok;
}
