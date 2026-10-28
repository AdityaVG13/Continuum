// Leap ceremony logic contracts: the pure surface of src/leap.goose --
// config preflight, request shapes, receipt parsing, and the outcome
// fold -- with no socket and no keychain touched. The receipt strings
// below are byte-for-byte what native/asus_web.cpp and
// native/host_macos.cpp emit (same fixtures as the C++ harnesses), so a
// format drift on either side turns this red.
// Failure-first: written against the intended API before src/leap.goose
// existed (first run: unknown type continuum::LeapConfig).
// Run: goose run tests/leap_logic.goose   (exit 0 = all green)
import lib from "../src";
import std;

fn check(cond: bool, label: const u8[:]) {
    if !cond {
        print("FAIL ", label);
        abort(str("leap contract violated: ", label));
    }
    print("ok ", label);
}

fn main() {
    // --- credential refs: the staged keychain names, stable forever ---
    check(continuum::leap_admin_ref("192.168.50.1")
        == "continuum.router.192.168.50.1.admin", "admin ref derives");
    check(continuum::leap_psk_ref("192.168.50.1")
        == "continuum.router.192.168.50.1.psk", "psk ref derives");

    // --- admin length: default 20, firmware cap wins, tiny cap refuses ---
    check(continuum::leap_admin_len(0) == 20, "no cap -> 20");
    check(continuum::leap_admin_len(16) == 16, "cap 16 -> 16");
    check(continuum::leap_admin_len(32) == 20, "cap 32 -> 20");
    check(continuum::leap_admin_len(7) == 0, "cap under 8 refuses");

    // --- router prefix for the rejoin lease check ---
    check(continuum::router_prefix("192.168.50.1") == "192.168.50.",
        "prefix strips last octet");
    check(continuum::router_prefix("10.0.0.254") == "10.0.0.",
        "prefix on another network");
    check(continuum::router_prefix("router.local") == "",
        "hostname has no prefix");
    check(continuum::router_prefix("192.168.50") == "",
        "short address has no prefix");
    check(continuum::router_prefix("192.168.50.1.") == "",
        "trailing dot has no prefix");

    var cfg = continuum::LeapConfig {
        host: "192.168.50.1", port: 80, interface_id: "en0",
        ssid_stem: "ContinuumLab", admin_ref: "continuum.router.192.168.50.1.admin",
        psk_ref: "continuum.router.192.168.50.1.psk",
    };

    // --- config preflight: first problem wins, happy path is "" ---
    check(continuum::leap_config_problem(cfg) == "", "good config passes");
    var bad_host = cfg;
    bad_host.host = "";
    check(continuum::leap_config_problem(bad_host) != "", "empty host refused");
    var bad_port = cfg;
    bad_port.port = 0;
    check(continuum::leap_config_problem(bad_port) != "", "port 0 refused");
    var bad_stem = cfg;
    bad_stem.ssid_stem = "has space";
    check(continuum::leap_config_problem(bad_stem) != "", "spaced stem refused");
    var no_iface = cfg;
    no_iface.interface_id = "";
    check(continuum::leap_config_problem(no_iface) != "",
        "rejoin without interface refused");
    var wired = cfg;
    wired.interface_id = "";
    wired.rejoin = false;
    wired.control_rides_wifi = false;
    check(continuum::leap_config_problem(wired) == "",
        "wired config needs no interface");

    // --- request shapes: exact field order, refs only, gates hold ---
    var req: u8[>..] = [];
    check(continuum::asus_discover_request(cfg, "192.168.50.7", req),
        "discover request builds");
    check(req == "{\"host\":\"192.168.50.1\",\"port\":80,\"bind_addr\":\"192.168.50.7\",\"factory_user\":\"admin\",\"factory_pass\":\"admin\"}",
        "discover request shape");

    req.clear();
    check(continuum::asus_rotate_request(cfg, "", true, req),
        "rotate request builds");
    check(req == "{\"host\":\"192.168.50.1\",\"port\":80,\"bind_addr\":\"\",\"admin_user\":\"admin\",\"admin_ref\":\"continuum.router.192.168.50.1.admin\",\"factory_user\":\"admin\",\"factory_pass\":\"admin\",\"session_first\":true}",
        "rotate request shape");

    req.clear();
    check(continuum::asus_apply_request(cfg, "192.168.50.7", req),
        "apply request builds");
    check(req == "{\"host\":\"192.168.50.1\",\"port\":80,\"bind_addr\":\"192.168.50.7\",\"admin_user\":\"admin\",\"admin_ref\":\"continuum.router.192.168.50.1.admin\",\"psk_ref\":\"continuum.router.192.168.50.1.psk\",\"ssid_stem\":\"ContinuumLab\"}",
        "apply request shape");

    req.clear();
    check(continuum::asus_verify_request(cfg, "", req), "verify request builds");
    check(req == "{\"host\":\"192.168.50.1\",\"port\":80,\"bind_addr\":\"\",\"admin_user\":\"admin\",\"admin_ref\":\"continuum.router.192.168.50.1.admin\"}",
        "verify request shape");

    req.clear();
    check(continuum::host_stage_request(cfg, 20, true, req),
        "stage request builds");
    check(req == "{\"admin_ref\":\"continuum.router.192.168.50.1.admin\",\"psk_ref\":\"continuum.router.192.168.50.1.psk\",\"admin_len\":20,\"psk_len\":16,\"reuse\":true}", "stage request shape");
    req.clear();
    check(!continuum::host_stage_request(cfg, 0, true, req),
        "stage refuses length 0");

    req.clear();
    check(continuum::host_rejoin_request(cfg, "ContinuumLab_5G2", true, 30, req),
        "rejoin request builds");
    check(req == "{\"interface\":\"en0\",\"ssid\":\"ContinuumLab_5G2\",\"psk_ref\":\"continuum.router.192.168.50.1.psk\",\"prefix\":\"192.168.50.\",\"wait_sec\":30}", "rejoin request shape");
    req.clear();
    check(continuum::host_rejoin_request(cfg, "ASUS_50", false, 30, req),
        "open rejoin request builds");
    check(req == "{\"interface\":\"en0\",\"ssid\":\"ASUS_50\",\"psk_ref\":\"\",\"prefix\":\"192.168.50.\",\"wait_sec\":30}",
        "open rejoin carries no psk ref");

    req.clear();
    check(continuum::host_iface_request(cfg, req), "iface request builds");
    check(req == "{\"interface\":\"en0\"}", "iface request shape");

    // --- discover receipt: arrays carry the ceremony's decisions ---
    let disc = continuum::parse_discover_receipt("{\"productid\":\"RT-AX58U\",\"x_setting\":\"0\",\"session_first\":false,\"max_admin_len\":16,\"bands\":[0,1,2],\"ssids\":[\"ASUS\",\"ASUS_5G\",\"ASUS_5G2\"],\"secured\":[]}");
    check(disc.ok, "discover receipt parses");
    check(disc.productid == "RT-AX58U", "discover product");
    check(!disc.configured_flag, "x_setting 0 is unconfigured");
    check(!disc.session_first && disc.max_admin_len == 16, "discover scalars");
    check(disc.band_count == 3 && disc.secured_count == 0, "discover lists");
    check(disc.ssids[2] == "ASUS_5G2", "discover third ssid");

    let disc2 = continuum::parse_discover_receipt("{\"productid\":\"RT-AX58U\",\"x_setting\":\"1\",\"session_first\":true,\"max_admin_len\":0,\"bands\":[0,1],\"ssids\":[\"ContinuumLab\",\"ContinuumLab_5G\"],\"secured\":[0,1]}");
    check(disc2.ok && disc2.configured_flag && disc2.secured_count == 2,
        "configured unit reads back as secured");

    check(!continuum::parse_discover_receipt("{\"productid\":\"RT-AX58U\",\"x_setting\":\"0\",\"session_first\":false,\"max_admin_len\":16,\"bands\":[0,1,2],\"ssids\":[\"ASUS\"],\"secured\":[]}").ok,
        "ssid count must match band count");
    check(!continuum::parse_discover_receipt("{\"x_setting\":\"0\"}").ok,
        "discover without product rejected");
    check(!continuum::parse_discover_receipt("not json").ok,
        "garbage discover rejected");

    // --- rotate / apply / stage: a receipt that denies proves nothing ---
    let rot = continuum::parse_rotate_receipt(
        "{\"rotated\":true,\"branch\":\"session\",\"login_verified\":true}");
    check(rot.ok && rot.branch == "session", "rotate receipt parses");
    check(!continuum::parse_rotate_receipt(
        "{\"rotated\":true,\"branch\":\"open\",\"login_verified\":false}").ok,
        "unproven rotation rejected");
    check(!continuum::parse_rotate_receipt(
        "{\"rotated\":true,\"branch\":\"sideways\",\"login_verified\":true}").ok,
        "unknown branch rejected");

    let appl = continuum::parse_apply_receipt("{\"submitted\":true,\"reply_cut\":true,\"new_ssids\":[\"ContinuumLab\",\"ContinuumLab_5G\",\"ContinuumLab_5G2\"]}");
    check(appl.ok && appl.reply_cut && appl.new_ssid_count == 3,
        "apply receipt parses");
    check(appl.new_ssids[0] == "ContinuumLab", "apply first new ssid");
    check(!continuum::parse_apply_receipt(
        "{\"submitted\":false,\"reply_cut\":false,\"new_ssids\":[\"X\"]}").ok,
        "unsubmitted apply rejected");
    check(!continuum::parse_apply_receipt(
        "{\"submitted\":true,\"reply_cut\":false,\"new_ssids\":[]}").ok,
        "apply without ssids rejected");

    let st = continuum::parse_stage_receipt(
        "{\"staged\":true,\"reused\":true,\"admin_len\":16,\"psk_len\":16}");
    check(st.ok && st.reused && st.admin_len == 16, "stage receipt parses");
    check(!continuum::parse_stage_receipt(
        "{\"staged\":false,\"reused\":false,\"admin_len\":20,\"psk_len\":16}").ok,
        "unstaged receipt rejected");

    // --- verify / rejoin / iface: a false verdict is data, not an error ---
    let ver = continuum::parse_verify_receipt(
        "{\"authenticated\":true,\"x_setting\":\"1\",\"wl0_ssid\":\"ContinuumLab\"}");
    check(ver.ok && ver.authenticated && ver.configured_flag,
        "verify receipt parses");
    let ver_no = continuum::parse_verify_receipt(
        "{\"authenticated\":false,\"x_setting\":\"\",\"wl0_ssid\":\"\"}");
    check(ver_no.ok && !ver_no.authenticated,
        "refused credential is receipt data");

    let j = continuum::parse_rejoin_receipt(
        "{\"joined\":true,\"already\":false,\"ip\":\"192.168.50.7\"}");
    check(j.ok && j.joined && j.ip == "192.168.50.7", "rejoin receipt parses");
    let j_no = continuum::parse_rejoin_receipt(
        "{\"joined\":false,\"already\":false,\"ip\":\"\"}");
    check(j_no.ok && !j_no.joined, "failed join is receipt data");

    let ii = continuum::parse_iface_receipt("{\"ip\":\"192.168.50.7\"}");
    check(ii.ok && ii.ip == "192.168.50.7", "iface receipt parses");

    // --- the outcome fold mirrors the bench ceremony exactly ---
    check(continuum::leap_classify_from(true, true, false)
        == continuum::LeapOutcome.Verified, "joined+authed verifies");
    check(continuum::leap_classify_from(true, false, false)
        == continuum::LeapOutcome.AdminAuthFailed, "joined but refused admin");
    check(continuum::leap_classify_from(false, false, true)
        == continuum::LeapOutcome.NotApplied, "old config intact");
    check(continuum::leap_classify_from(false, false, false)
        == continuum::LeapOutcome.Unreachable, "nothing answers");

    // --- operator strings: every outcome names itself and its recovery ---
    check(continuum::leap_outcome_name(continuum::LeapOutcome.NotApplied)
        == "NotApplied", "outcome names");
    check(continuum::leap_recovery(continuum::LeapOutcome.CredentialMismatch).len > 0,
        "recovery text exists for mismatch");
    check(continuum::leap_needs_physical_reset(
        continuum::leap_classify_from(true, false, false)),
        "admin failure needs the paperclip");

    print("LEAP_LOGIC_ALL_GREEN");
}
