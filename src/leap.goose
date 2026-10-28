// The leap ceremony executor: onboarding.goose plans, this module runs.
// It is the Goose port of the proven bench ceremony (docs/ONBOARDING.md
// sec. 7): discover a factory unit, stage credentials durably, let the
// planner admit the leap, rotate + apply through the vendor adapter,
// rejoin the renamed radio, verify under the staged credential, and
// classify the outcome with the planner's table.
//
// Boundary discipline matches router_web.goose: request JSON carries
// routing and credential REFS only; secrets are generated, vaulted, and
// fetched inside the C++ adapters (native/asus_web.cpp for the device,
// native/host_macos.cpp for the keychain and the OS Wi-Fi join) and never
// enter Goose, a request, or a receipt. run_leap prints phase lines
// because it is an operator command that runs for minutes across a
// planned disconnect; every decision it prints is also in LeapReport.
//
// v1 scope: the fresh-run ceremony with stage-reuse idempotence. A unit
// discover reports as already secured is refused, never re-leapt; the
// rerun story is the physical reset the planner's honesty bound names.
import .onboarding;
import .tooljson;
import json;
namespace continuum;

// The runtime provides gs_os_sleep_ms but the os module does not surface
// it in this toolchain; declare the binding directly.
extern "gs_os_sleep_ms" fn leap_sleep_ms(ms: i64);

extern fn ct_asus_discover_json(req: const u8[:], receipt: u8[:], receipt_len: i64&) -> i32;
extern fn ct_asus_rotate_json(req: const u8[:], receipt: u8[:], receipt_len: i64&) -> i32;
extern fn ct_asus_apply_json(req: const u8[:], receipt: u8[:], receipt_len: i64&) -> i32;
extern fn ct_asus_verify_json(req: const u8[:], receipt: u8[:], receipt_len: i64&) -> i32;
extern fn ct_host_stage_json(req: const u8[:], receipt: u8[:], receipt_len: i64&) -> i32;
extern fn ct_host_rejoin_json(req: const u8[:], receipt: u8[:], receipt_len: i64&) -> i32;
extern fn ct_host_iface_json(req: const u8[:], receipt: u8[:], receipt_len: i64&) -> i32;

// Everything the ceremony needs, and nothing secret: refs name keychain
// slots (StagedSetup's contract), factory_* are vendor-published defaults.
struct LeapConfig {
    host: u8[..253] = "",
    port: i64 = 80,
    interface_id: u8[..64] = "",
    ssid_stem: u8[..27] = "",
    admin_user: u8[..32] = "admin",
    factory_user: u8[..32] = "admin",
    factory_pass: u8[..64] = "admin",
    admin_ref: u8[..128] = "",
    psk_ref: u8[..128] = "",
    bind_addr: u8[..64] = "",
    control_rides_wifi: bool = true,
    execute: bool = false,
    rejoin: bool = true,
    radio_wait_sec: i64 = 45,
}

struct LeapReport {
    ok: bool = false,
    dry_run: bool = false,
    refused: bool = false,
    phase: u8[..32] = "",
    reason: u8[..256] = "",
    outcome: LeapOutcome = LeapOutcome.Unset,
    productid: u8[..64] = "",
    session_first: bool = false,
    branch: u8[..16] = "",
    reply_cut: bool = false,
    staged_reused: bool = false,
    joined_ssid: u8[..64] = "",
    ip: u8[..64] = "",
}

// Keychain service names. The bench ceremony staged under exactly these
// refs, so existing staged credentials stay readable across the port.
fn leap_admin_ref(host: const u8[:]) -> u8[..128] {
    var b: u8[..128] = "continuum.router.";
    b.append(host);
    b.append(".admin");
    return b;
}

fn leap_psk_ref(host: const u8[:]) -> u8[..128] {
    var b: u8[..128] = "continuum.router.";
    b.append(host);
    b.append(".psk");
    return b;
}

// The staged admin length: 20 by default, capped by the firmware's
// MaxLen_http_passwd when discover reports one (some builds reject
// longer credentials outright). A cap under 8 cannot hold a sane
// credential, so the ceremony refuses rather than staging a weak one.
fn leap_admin_len(max_admin_len: i64) -> i64 {
    if max_admin_len <= 0 {
        return 20;
    }
    if max_admin_len < 8 {
        return 0;
    }
    return if max_admin_len < 20 { max_admin_len } else { 20 };
}

// The /24 a rejoin lease must land in, "192.168.50.1" -> "192.168.50.".
// Anything that is not exactly four dotted decimal octets has no prefix
// here: lease checks need the numeric form, never a hostname guess.
fn router_prefix(host: const u8[:]) -> u8[..64] {
    var b: u8[..64] = "";
    var dots: i64 = 0;
    var last_dot: i64 = -1;
    var i: i64 = 0;
    while i < host.len {
        let c = host[i];
        if c == '.' {
            dots++;
            last_dot = i;
        } else if c < '0' || c > '9' {
            return b;
        }
        i++;
    }
    if dots != 3 || last_dot <= 0 || last_dot >= host.len - 1 {
        return b;
    }
    b.append(host[..last_dot + 1]);
    return b;
}

// First problem with the config, or "" when the ceremony may start.
// Builders re-check their own fields; this is the operator-facing
// preflight so a bad config fails before any socket opens.
fn leap_config_problem(cfg: LeapConfig) -> const u8[:] {
    if !valid_id(cfg.host, 253) {
        return "host is empty or not a plain address";
    }
    if cfg.port <= 0 || cfg.port > 65535 {
        return "port outside 1..65535";
    }
    if !valid_id(cfg.ssid_stem, 27) {
        return "ssid stem is empty or not a plain token";
    }
    if !valid_id(cfg.admin_user, 32) {
        return "admin user is empty or not a plain token";
    }
    if !valid_id(cfg.admin_ref, 128) || !valid_id(cfg.psk_ref, 128) {
        return "credential refs are empty or not plain tokens";
    }
    if cfg.bind_addr.len > 0 && !valid_id(cfg.bind_addr, 64) {
        return "bind address is not a plain address";
    }
    if cfg.rejoin && !valid_id(cfg.interface_id, 64) {
        return "rejoin needs the Wi-Fi interface id";
    }
    return "";
}

// --- request builders (router_web discipline: gated ids, exact shapes) --

fn leap_common(cfg: LeapConfig, bind_addr: const u8[:], out: u8[>..]&) -> bool {
    if !valid_id(cfg.host, 253) || cfg.port <= 0 || cfg.port > 65535 {
        return false;
    }
    if bind_addr.len > 64 || (bind_addr.len > 0 && !valid_id(bind_addr, 64)) {
        return false;
    }
    out.append("{\"host\":");
    json::format_string(out, cfg.host);
    out.append(",\"port\":");
    json::format_int(out, cfg.port);
    out.append(",\"bind_addr\":");
    json::format_string(out, bind_addr);
    return true;
}

fn asus_discover_request(cfg: LeapConfig, bind_addr: const u8[:], out: u8[>..]&) -> bool {
    if !leap_common(cfg, bind_addr, out) {
        return false;
    }
    out.append(",\"factory_user\":");
    json::format_string(out, cfg.factory_user);
    out.append(",\"factory_pass\":");
    json::format_string(out, cfg.factory_pass);
    out.append("}");
    return true;
}

fn asus_rotate_request(cfg: LeapConfig, bind_addr: const u8[:], session_first: bool, out: u8[>..]&) -> bool {
    if !valid_id(cfg.admin_user, 32) || !valid_id(cfg.admin_ref, 128) {
        return false;
    }
    if !leap_common(cfg, bind_addr, out) {
        return false;
    }
    out.append(",\"admin_user\":");
    json::format_string(out, cfg.admin_user);
    out.append(",\"admin_ref\":");
    json::format_string(out, cfg.admin_ref);
    out.append(",\"factory_user\":");
    json::format_string(out, cfg.factory_user);
    out.append(",\"factory_pass\":");
    json::format_string(out, cfg.factory_pass);
    out.append(",\"session_first\":");
    json::format_bool(out, session_first);
    out.append("}");
    return true;
}

fn asus_apply_request(cfg: LeapConfig, bind_addr: const u8[:], out: u8[>..]&) -> bool {
    if !valid_id(cfg.admin_user, 32) || !valid_id(cfg.admin_ref, 128)
            || !valid_id(cfg.psk_ref, 128) || !valid_id(cfg.ssid_stem, 27) {
        return false;
    }
    if !leap_common(cfg, bind_addr, out) {
        return false;
    }
    out.append(",\"admin_user\":");
    json::format_string(out, cfg.admin_user);
    out.append(",\"admin_ref\":");
    json::format_string(out, cfg.admin_ref);
    out.append(",\"psk_ref\":");
    json::format_string(out, cfg.psk_ref);
    out.append(",\"ssid_stem\":");
    json::format_string(out, cfg.ssid_stem);
    out.append("}");
    return true;
}

fn asus_verify_request(cfg: LeapConfig, bind_addr: const u8[:], out: u8[>..]&) -> bool {
    if !valid_id(cfg.admin_user, 32) || !valid_id(cfg.admin_ref, 128) {
        return false;
    }
    if !leap_common(cfg, bind_addr, out) {
        return false;
    }
    out.append(",\"admin_user\":");
    json::format_string(out, cfg.admin_user);
    out.append(",\"admin_ref\":");
    json::format_string(out, cfg.admin_ref);
    out.append("}");
    return true;
}

fn host_stage_request(cfg: LeapConfig, admin_len: i64, reuse: bool, out: u8[>..]&) -> bool {
    if !valid_id(cfg.admin_ref, 128) || !valid_id(cfg.psk_ref, 128) {
        return false;
    }
    if admin_len < 8 || admin_len > 64 {
        return false;
    }
    out.append("{\"admin_ref\":");
    json::format_string(out, cfg.admin_ref);
    out.append(",\"psk_ref\":");
    json::format_string(out, cfg.psk_ref);
    out.append(",\"admin_len\":");
    json::format_int(out, admin_len);
    out.append(",\"psk_len\":16,\"reuse\":");
    json::format_bool(out, reuse);
    out.append("}");
    return true;
}

fn host_rejoin_request(cfg: LeapConfig, ssid: const u8[:], with_psk: bool, wait_sec: i64, out: u8[>..]&) -> bool {
    if !valid_id(cfg.interface_id, 64) || ssid.len <= 0 || ssid.len > 64 {
        return false;
    }
    if wait_sec <= 0 || wait_sec > 300 {
        return false;
    }
    let prefix = router_prefix(cfg.host);
    if prefix.len <= 0 {
        return false;
    }
    if with_psk && !valid_id(cfg.psk_ref, 128) {
        return false;
    }
    out.append("{\"interface\":");
    json::format_string(out, cfg.interface_id);
    out.append(",\"ssid\":");
    json::format_string(out, ssid);
    out.append(",\"psk_ref\":");
    json::format_string(out, if with_psk { cfg.psk_ref } else { "" });
    out.append(",\"prefix\":");
    json::format_string(out, prefix);
    out.append(",\"wait_sec\":");
    json::format_int(out, wait_sec);
    out.append("}");
    return true;
}

fn host_iface_request(cfg: LeapConfig, out: u8[>..]&) -> bool {
    if !valid_id(cfg.interface_id, 64) {
        return false;
    }
    out.append("{\"interface\":");
    json::format_string(out, cfg.interface_id);
    out.append("}");
    return true;
}

// --- receipt parsers -------------------------------------------------------
// Each parses into plain bounded values inside one function (the node
// pool never escapes), requires every field its native counterpart
// emits, and treats a denied verdict (submitted:false and friends) as a
// parse failure: a receipt that does not confirm proves nothing.
// authenticated:false / joined:false are DATA, not errors -- the caller
// classifies from them.

struct DiscoverInfo {
    ok: bool = false,
    reason: u8[..256] = "",
    productid: u8[..64] = "",
    configured_flag: bool = false,
    session_first: bool = false,
    max_admin_len: i64 = 0,
    band_count: i64 = 0,
    ssids: u8[..64][..4] = [],
    secured_count: i64 = 0,
}

struct StepInfo {
    ok: bool = false,
    reason: u8[..256] = "",
    branch: u8[..16] = "",
}

struct ApplyInfo {
    ok: bool = false,
    reason: u8[..256] = "",
    reply_cut: bool = false,
    new_ssid_count: i64 = 0,
    new_ssids: u8[..64][..4] = [],
}

struct VerifyInfo {
    ok: bool = false,
    reason: u8[..256] = "",
    authenticated: bool = false,
    configured_flag: bool = false,
    wl0_ssid: u8[..64] = "",
}

struct StageInfo {
    ok: bool = false,
    reason: u8[..256] = "",
    reused: bool = false,
    admin_len: i64 = 0,
    psk_len: i64 = 0,
}

struct RejoinInfo {
    ok: bool = false,
    reason: u8[..256] = "",
    joined: bool = false,
    already: bool = false,
    ip: u8[..64] = "",
}

struct IfaceInfo {
    ok: bool = false,
    reason: u8[..256] = "",
    ip: u8[..64] = "",
}

fn bounded64(s: const u8[:]) -> u8[..64] {
    var b: u8[..64] = "";
    b.append(s);
    return b;
}

// Copy a required string member into a bounded slot; false when absent,
// not a string, or too long to store without truncation.
fn req_str(root: json::Node?, key: const u8[:], out: u8[..64]&) -> bool {
    let v, is_s = json::as_string(json::member(root, key));
    if !is_s || v.len > 64 {
        return false;
    }
    out = bounded64(v);
    return true;
}

// Count an int array member exactly; -1 when absent or malformed.
fn count_ints(root: json::Node?, key: const u8[:]) -> i64 {
    let node = json::member(root, key);
    if !node {
        return -1;
    }
    var n: i64 = 0;
    var c = node.first;
    while c {
        let v, is_i = json::as_i64(c);
        if !is_i || v < 0 || v > 255 {
            return -1;
        }
        n++;
        c .= c.next;
    }
    return n;
}

// Fill up to 4 string slots from an array member; count or -1.
fn fill_strs(root: json::Node?, key: const u8[:], out: u8[..64][..4]&) -> i64 {
    let node = json::member(root, key);
    if !node {
        return -1;
    }
    var n: i64 = 0;
    var c = node.first;
    while c {
        let v, is_s = json::as_string(c);
        if !is_s || v.len > 64 || n >= 4 {
            return -1;
        }
        out.push(bounded64(v));
        n++;
        c .= c.next;
    }
    return n;
}

fn parse_discover_receipt(text: u8[:]) -> DiscoverInfo {
    var info = DiscoverInfo {};
    if text.len <= 0 || text.len > 4096 {
        info.reason = "receipt size outside 1..4096";
        return info;
    }
    var doc: json::Node[>..] = [];
    var decoded: u8[>..] = [];
    let root, err = json::parse(text, doc, decoded);
    if !root {
        info.reason = "receipt is not JSON";
        return info;
    }
    if !req_str(root, "productid", info.productid) {
        info.reason = "receipt lacks productid";
        return info;
    }
    var xs: u8[..64] = "";
    if !req_str(root, "x_setting", xs) || (xs != "0" && xs != "1") {
        info.reason = "receipt lacks a usable x_setting";
        return info;
    }
    info.configured_flag = xs == "1";
    let sf, is_sf = json::as_bool(json::member(root, "session_first"));
    let ml, is_ml = json::as_i64(json::member(root, "max_admin_len"));
    if !is_sf || !is_ml || ml < 0 || ml > 256 {
        info.reason = "receipt lacks session/maxlen fields";
        return info;
    }
    info.session_first = sf;
    info.max_admin_len = ml;
    info.band_count = count_ints(root, "bands");
    info.secured_count = count_ints(root, "secured");
    let n_ssid = fill_strs(root, "ssids", info.ssids);
    if info.band_count <= 0 || info.secured_count < 0 || n_ssid != info.band_count {
        info.reason = "receipt band lists are inconsistent";
        return info;
    }
    info.ok = true;
    return info;
}

fn parse_rotate_receipt(text: u8[:]) -> StepInfo {
    var info = StepInfo {};
    if text.len <= 0 || text.len > 4096 {
        info.reason = "receipt size outside 1..4096";
        return info;
    }
    var doc: json::Node[>..] = [];
    var decoded: u8[>..] = [];
    let root, err = json::parse(text, doc, decoded);
    if !root {
        info.reason = "receipt is not JSON";
        return info;
    }
    let rot, is_r = json::as_bool(json::member(root, "rotated"));
    let proof, is_p = json::as_bool(json::member(root, "login_verified"));
    if !is_r || !rot || !is_p || !proof {
        info.reason = "receipt does not confirm a proven rotation";
        return info;
    }
    var br: u8[..64] = "";
    if !req_str(root, "branch", br) || (br != "open" && br != "session") {
        info.reason = "receipt lacks a known branch";
        return info;
    }
    info.branch.append(br);
    info.ok = true;
    return info;
}

fn parse_apply_receipt(text: u8[:]) -> ApplyInfo {
    var info = ApplyInfo {};
    if text.len <= 0 || text.len > 4096 {
        info.reason = "receipt size outside 1..4096";
        return info;
    }
    var doc: json::Node[>..] = [];
    var decoded: u8[>..] = [];
    let root, err = json::parse(text, doc, decoded);
    if !root {
        info.reason = "receipt is not JSON";
        return info;
    }
    let sub, is_s = json::as_bool(json::member(root, "submitted"));
    let cut, is_c = json::as_bool(json::member(root, "reply_cut"));
    if !is_s || !sub || !is_c {
        info.reason = "receipt does not confirm submission";
        return info;
    }
    info.reply_cut = cut;
    info.new_ssid_count = fill_strs(root, "new_ssids", info.new_ssids);
    if info.new_ssid_count <= 0 {
        info.reason = "receipt lacks the new ssids";
        return info;
    }
    info.ok = true;
    return info;
}

fn parse_verify_receipt(text: u8[:]) -> VerifyInfo {
    var info = VerifyInfo {};
    if text.len <= 0 || text.len > 4096 {
        info.reason = "receipt size outside 1..4096";
        return info;
    }
    var doc: json::Node[>..] = [];
    var decoded: u8[>..] = [];
    let root, err = json::parse(text, doc, decoded);
    if !root {
        info.reason = "receipt is not JSON";
        return info;
    }
    let auth, is_a = json::as_bool(json::member(root, "authenticated"));
    if !is_a {
        info.reason = "receipt lacks the auth verdict";
        return info;
    }
    info.authenticated = auth;
    var xs: u8[..64] = "";
    if !req_str(root, "x_setting", xs) || !req_str(root, "wl0_ssid", info.wl0_ssid) {
        info.reason = "receipt lacks readback fields";
        return info;
    }
    info.configured_flag = xs == "1";
    info.ok = true;
    return info;
}

fn parse_stage_receipt(text: u8[:]) -> StageInfo {
    var info = StageInfo {};
    if text.len <= 0 || text.len > 4096 {
        info.reason = "receipt size outside 1..4096";
        return info;
    }
    var doc: json::Node[>..] = [];
    var decoded: u8[>..] = [];
    let root, err = json::parse(text, doc, decoded);
    if !root {
        info.reason = "receipt is not JSON";
        return info;
    }
    let staged, is_s = json::as_bool(json::member(root, "staged"));
    let reused, is_r = json::as_bool(json::member(root, "reused"));
    let al, is_al = json::as_i64(json::member(root, "admin_len"));
    let pl, is_pl = json::as_i64(json::member(root, "psk_len"));
    if !is_s || !staged || !is_r || !is_al || !is_pl || al <= 0 || pl <= 0 {
        info.reason = "receipt does not confirm durable staging";
        return info;
    }
    info.reused = reused;
    info.admin_len = al;
    info.psk_len = pl;
    info.ok = true;
    return info;
}

fn parse_rejoin_receipt(text: u8[:]) -> RejoinInfo {
    var info = RejoinInfo {};
    if text.len <= 0 || text.len > 4096 {
        info.reason = "receipt size outside 1..4096";
        return info;
    }
    var doc: json::Node[>..] = [];
    var decoded: u8[>..] = [];
    let root, err = json::parse(text, doc, decoded);
    if !root {
        info.reason = "receipt is not JSON";
        return info;
    }
    let joined, is_j = json::as_bool(json::member(root, "joined"));
    let already, is_a = json::as_bool(json::member(root, "already"));
    if !is_j || !is_a || !req_str(root, "ip", info.ip) {
        info.reason = "receipt lacks the join verdict";
        return info;
    }
    info.joined = joined;
    info.already = already;
    info.ok = true;
    return info;
}

fn parse_iface_receipt(text: u8[:]) -> IfaceInfo {
    var info = IfaceInfo {};
    if text.len <= 0 || text.len > 4096 {
        info.reason = "receipt size outside 1..4096";
        return info;
    }
    var doc: json::Node[>..] = [];
    var decoded: u8[>..] = [];
    let root, err = json::parse(text, doc, decoded);
    if !root {
        info.reason = "receipt is not JSON";
        return info;
    }
    if !req_str(root, "ip", info.ip) {
        info.reason = "receipt lacks the address";
        return info;
    }
    info.ok = true;
    return info;
}

// --- outcome surface --------------------------------------------------------

fn leap_outcome_name(outcome: LeapOutcome) -> const u8[:] {
    match outcome {
        Unset => "Unset",
        Verified => "Verified",
        NotApplied => "NotApplied",
        CredentialMismatch => "CredentialMismatch",
        AdminAuthFailed => "AdminAuthFailed",
        Unreachable => "Unreachable",
    }
}

fn leap_recovery(outcome: LeapOutcome) -> const u8[:] {
    match outcome {
        Verified => "setup took; the protected read answers under the staged credential",
        NotApplied => "old SSID/config intact; submission did not take -- safe to fix inputs and retry",
        CredentialMismatch => "new SSID visible but the staged PSK does not join it -- paperclip factory reset, rerun",
        AdminAuthFailed => "new SSID joins but the staged admin credential is refused -- paperclip factory reset, rerun",
        Unreachable => "neither SSID answers -- check power and radio LEDs; paperclip reset if it does not return",
        Unset => "no outcome was reached",
    }
}

// The executor's fold of classify_leap: this host observes "seen"
// through join attempts (no scan surface), so new_ssid_seen rides
// joined_new and CredentialMismatch is not reachable from here -- the
// same fold the bench ceremony used, kept explicit.
fn leap_classify_from(joined_new: bool, authenticated_ok: bool, old_still_answers: bool) -> LeapOutcome {
    return classify_leap(joined_new, old_still_answers, joined_new, authenticated_ok);
}

// --- transport --------------------------------------------------------------

fn leap_reason(rc: i32) -> const u8[:] {
    if rc == -4 {
        return "refused (auth, scope, or the OS said no)";
    }
    if rc == -1 {
        return "request shape refused";
    }
    if rc == -2 {
        return "receipt buffer too small";
    }
    if rc == -5 {
        return "transport failed (unreachable or timeout)";
    }
    return "unknown transport status";
}

// One native round trip: receipt bytes appended to out, status returned.
// Rejoin's CT_REJECTED still carries a receipt; callers decide.
fn leap_call(kind: i64, req_text: const u8[:], out: u8[>..]&) -> i32 {
    var receipt: u8[..4096] = [0; 4096];
    var n: i64 = 0;
    let rc = if kind == 0 { ct_asus_discover_json(req_text, receipt, n) }
        else if kind == 1 { ct_asus_rotate_json(req_text, receipt, n) }
        else if kind == 2 { ct_asus_apply_json(req_text, receipt, n) }
        else if kind == 3 { ct_asus_verify_json(req_text, receipt, n) }
        else if kind == 4 { ct_host_stage_json(req_text, receipt, n) }
        else if kind == 5 { ct_host_rejoin_json(req_text, receipt, n) }
        else { ct_host_iface_json(req_text, receipt, n) };
    if n > 0 && n <= receipt.len {
        out.append(receipt[..n]);
    }
    return rc;
}

fn fail_report(phase: const u8[:], reason: const u8[:]) -> LeapReport {
    var r = LeapReport {};
    r.phase.append(phase);
    r.reason.append(reason);
    print("leap: ", phase, " failed: ", reason);
    return r;
}

// --- the ceremony -----------------------------------------------------------

fn run_leap(cfg: LeapConfig) -> LeapReport {
    let problem = leap_config_problem(cfg);
    if problem != "" {
        return fail_report("config", problem);
    }
    var report = LeapReport {};
    var req: u8[>..] = [];
    var resp: u8[>..] = [];

    // Bind discovery to the router-facing interface when we can learn its
    // address; an explicitly configured bind wins. Best effort only --
    // the native layer binds only when bind_addr is non-empty.
    var bind: u8[..64] = "";
    bind.append(cfg.bind_addr);
    if bind.len == 0 && cfg.interface_id.len > 0 {
        req.clear();
        if host_iface_request(cfg, req) {
            resp.clear();
            if leap_call(6, req, resp) == 0 {
                let ii = parse_iface_receipt(resp);
                if ii.ok {
                    bind = ii.ip;
                }
            }
        }
    }

    // Discover: what is this unit, and is it factory enough to leap?
    req.clear();
    if !asus_discover_request(cfg, bind, req) {
        return fail_report("discover", "request fields invalid");
    }
    resp.clear();
    var rc = leap_call(0, req, resp);
    if rc != 0 {
        return fail_report("discover", leap_reason(rc));
    }
    let disc = parse_discover_receipt(resp);
    if !disc.ok {
        return fail_report("discover", disc.reason);
    }
    report.productid = disc.productid;
    report.session_first = disc.session_first;
    print("leap: discovered ", disc.productid, " bands=", disc.band_count,
        " session_first=", disc.session_first);
    if disc.secured_count > 0 {
        // Factory detection is the secured-band conjunction (a refused
        // wizard-open chpass can flip x_Setting alone on this firmware).
        report.refused = true;
        report.phase = "discover";
        report.reason = "unit already has secured bands; the leap ceremony is factory-only (paperclip reset to retry)";
        print("leap: refusing: ", report.reason);
        return report;
    }

    // The planner gates every mutation. First pass with nothing staged:
    // a leap that needs staging gets exactly one stage, then re-plans.
    var path = ControlPath {
        path_id: "control",
        kind: if cfg.control_rides_wifi { PathKind.Wifi } else { PathKind.Wired },
        interface_id: cfg.interface_id,
        bind_addr: bind,
        endpoint: cfg.host,
        rides_target_wifi: cfg.control_rides_wifi,
        reachable: true,
    };
    var paths = ControlPaths {};
    paths.items.push(path);
    var setup = StagedSetup {
        staged: false,
        old_ssid: disc.ssids[0],
        new_ssid: cfg.ssid_stem,
        psk_ref: cfg.psk_ref,
        admin_ref: cfg.admin_ref,
    };
    var plan = plan_leap(paths, setup);
    if plan.strategy == LeapStrategy.NoPath {
        return fail_report("plan", plan.reason);
    }
    if !cfg.execute {
        report.dry_run = true;
        report.ok = true;
        report.phase = "plan";
        print("leap: DRY RUN: strategy admissible after staging=",
            plan.requires_staging, " expects_disconnect=",
            plan.expects_disconnect, "; no writes made");
        return report;
    }
    if plan.requires_staging {
        let admin_len = leap_admin_len(disc.max_admin_len);
        if admin_len == 0 {
            return fail_report("stage", "firmware admin length cap cannot hold a sane credential");
        }
        req.clear();
        if !host_stage_request(cfg, admin_len, true, req) {
            return fail_report("stage", "request fields invalid");
        }
        resp.clear();
        rc = leap_call(4, req, resp);
        if rc != 0 {
            return fail_report("stage", leap_reason(rc));
        }
        let st = parse_stage_receipt(resp);
        if !st.ok {
            return fail_report("stage", st.reason);
        }
        report.staged_reused = st.reused;
        print("leap: staged (reused=", st.reused, " admin_len=", st.admin_len,
            " psk_len=", st.psk_len, ")");
        setup.staged = true;
        plan = plan_leap(paths, setup);
    }
    if !plan.admissible {
        return fail_report("plan", plan.reason);
    }

    // Rotate the admin credential; the native adapter proves it with a
    // fresh login before claiming success.
    req.clear();
    if !asus_rotate_request(cfg, bind, disc.session_first, req) {
        return fail_report("rotate", "request fields invalid");
    }
    resp.clear();
    rc = leap_call(1, req, resp);
    if rc != 0 {
        return fail_report("rotate", leap_reason(rc));
    }
    let rot = parse_rotate_receipt(resp);
    if !rot.ok {
        return fail_report("rotate", rot.reason);
    }
    report.branch = rot.branch;
    print("leap: admin rotated via ", rot.branch, " branch, login verified");

    // The leap POST: on a same-link plan the reply may die with the
    // radio restart; the adapter receipts that as reply_cut.
    req.clear();
    if !asus_apply_request(cfg, bind, req) {
        return fail_report("apply", "request fields invalid");
    }
    resp.clear();
    rc = leap_call(2, req, resp);
    if rc != 0 {
        return fail_report("apply", leap_reason(rc));
    }
    let appl = parse_apply_receipt(resp);
    if !appl.ok {
        return fail_report("apply", appl.reason);
    }
    report.reply_cut = appl.reply_cut;
    print("leap: submitted (reply_cut=", appl.reply_cut, ")");

    // Rejoin on the new SSIDs (highest band first), then verify.
    var joined_new = false;
    var old_answers = false;
    if plan.expects_disconnect && cfg.rejoin {
        print("leap: waiting ", cfg.radio_wait_sec, "s for the radio restart");
        leap_sleep_ms(cfg.radio_wait_sec * 1000);
        var bi = appl.new_ssid_count - 1;
        while bi >= 0 && !joined_new {
            var attempt: i64 = 0;
            while attempt < 6 && !joined_new {
                req.clear();
                if host_rejoin_request(cfg, appl.new_ssids[bi], true, 30, req) {
                    resp.clear();
                    // CT_REJECTED carries {"joined":false,...}: data.
                    let _ = leap_call(5, req, resp);
                    let j = parse_rejoin_receipt(resp);
                    if j.ok && j.joined {
                        joined_new = true;
                        bind = j.ip;
                        report.joined_ssid = appl.new_ssids[bi];
                        report.ip = j.ip;
                        print("leap: rejoined ", appl.new_ssids[bi],
                            " as ", j.ip);
                    }
                }
                if !joined_new {
                    leap_sleep_ms(10000);
                }
                attempt++;
            }
            bi--;
        }
        if !joined_new {
            // Not-applied probe: join an old SSID (open) and ask the unit
            // whether it is still in its factory state.
            var oi = disc.band_count - 1;
            while oi >= 0 && !old_answers {
                req.clear();
                if host_rejoin_request(cfg, disc.ssids[oi], false, 30, req) {
                    resp.clear();
                    let _ = leap_call(5, req, resp);
                    let j = parse_rejoin_receipt(resp);
                    if j.ok && j.joined {
                        bind = j.ip;
                        req.clear();
                        if asus_discover_request(cfg, bind, req) {
                            resp.clear();
                            if leap_call(0, req, resp) == 0 {
                                let again = parse_discover_receipt(resp);
                                old_answers = again.ok && !again.configured_flag;
                            }
                        }
                    }
                }
                oi--;
            }
        }
    } else {
        // Surviving path (or a loopback bench where the link never
        // drops): still attached, so classification rides verify.
        joined_new = true;
    }

    var authenticated = false;
    if joined_new {
        req.clear();
        if !asus_verify_request(cfg, bind, req) {
            return fail_report("verify", "request fields invalid");
        }
        resp.clear();
        rc = leap_call(3, req, resp);
        if rc != 0 {
            return fail_report("verify", leap_reason(rc));
        }
        let ver = parse_verify_receipt(resp);
        if !ver.ok {
            return fail_report("verify", ver.reason);
        }
        authenticated = ver.authenticated;
        print("leap: verify authenticated=", authenticated,
            " wl0=", ver.wl0_ssid);
    }

    report.outcome = leap_classify_from(joined_new, authenticated, old_answers);
    report.ok = report.outcome == LeapOutcome.Verified;
    report.phase = "classified";
    report.reason.append(leap_recovery(report.outcome));
    print("leap: OUTCOME ", leap_outcome_name(report.outcome), " -- ",
        leap_recovery(report.outcome));
    return report;
}
