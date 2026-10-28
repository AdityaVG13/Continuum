// The leap ceremony as an operator command: configuration from the
// environment, one run_leap, exit code from the verdict. Dry run is
// the default -- LEAP_EXECUTE=1 is the only way to write to a device.
// Secrets never transit the environment here: refs name keychain
// slots, the native stage step mints the values, and the vendor
// adapter fetches them by ref (see src/leap.goose).
//
//   ROUTER_HOST=192.168.50.1 SSID_STEM=ContinuumLab make leap        # dry
//   ... LEAP_EXECUTE=1 make leap-run                                 # write
//
// Knobs: ROUTER_PORT(80) WIFI_INTERFACE(en0) ADMIN_USER(admin)
// FACTORY_USER/PASS(admin/admin) ADMIN_REF/PSK_REF(derived from host)
// BIND_ADDR(auto) CONTROL_RIDES_WIFI(1) LEAP_REJOIN(1) RADIO_WAIT_SEC(45)
import .lib;
import std;
import os;
import json;

fn env_into(name: const u8[:], fallback: const u8[:]) -> u8[>..] {
    var v: u8[>..] = [];
    if env(name, v) && v.len > 0 && v.len <= 256 {
        return v;
    }
    v.clear();
    v.append(fallback);
    return v;
}

fn env_i64(name: const u8[:], fallback: i64) -> i64 {
    var v: u8[>..] = [];
    if env(name, v) && v.len > 0 && v.len < 20 {
        var doc: json::Node[>..] = [];
        var decoded: u8[>..] = [];
        let root, err = json::parse(v, doc, decoded);
        let n, is_i = json::as_i64(root);
        if is_i {
            return n;
        }
    }
    return fallback;
}

fn env_flag(name: const u8[:], fallback: bool) -> bool {
    var v: u8[>..] = [];
    if env(name, v) && v.len > 0 {
        return v == "1";
    }
    return fallback;
}

fn main() {
    let host = env_into("ROUTER_HOST", "");
    let stem = env_into("SSID_STEM", "");
    if host.len == 0 || stem.len == 0 {
        print("Usage: ROUTER_HOST=<addr> SSID_STEM=<stem> [LEAP_EXECUTE=1] continuum-leap");
        print("Dry run unless LEAP_EXECUTE=1. See src/leap_main.goose for knobs.");
        exit(2);
    }
    var cfg = continuum::LeapConfig {};
    if host.len <= 253 {
        cfg.host.append(host);
    }
    cfg.port = env_i64("ROUTER_PORT", 80);
    let iface = env_into("WIFI_INTERFACE", "en0");
    if iface.len <= 64 {
        cfg.interface_id.append(iface);
    }
    if stem.len <= 27 {
        cfg.ssid_stem.append(stem);
    }
    let admin_user = env_into("ADMIN_USER", "admin");
    if admin_user.len <= 32 {
        cfg.admin_user.clear();
        cfg.admin_user.append(admin_user);
    }
    let fuser = env_into("FACTORY_USER", "admin");
    if fuser.len <= 32 {
        cfg.factory_user.clear();
        cfg.factory_user.append(fuser);
    }
    let fpass = env_into("FACTORY_PASS", "admin");
    if fpass.len <= 64 {
        cfg.factory_pass.clear();
        cfg.factory_pass.append(fpass);
    }
    let aref = env_into("ADMIN_REF", "");
    if aref.len > 0 && aref.len <= 128 {
        cfg.admin_ref.append(aref);
    } else {
        cfg.admin_ref = continuum::leap_admin_ref(cfg.host);
    }
    let pref = env_into("PSK_REF", "");
    if pref.len > 0 && pref.len <= 128 {
        cfg.psk_ref.append(pref);
    } else {
        cfg.psk_ref = continuum::leap_psk_ref(cfg.host);
    }
    let bind = env_into("BIND_ADDR", "");
    if bind.len > 0 && bind.len <= 64 {
        cfg.bind_addr.append(bind);
    }
    cfg.control_rides_wifi = env_flag("CONTROL_RIDES_WIFI", true);
    cfg.rejoin = env_flag("LEAP_REJOIN", true);
    cfg.radio_wait_sec = env_i64("RADIO_WAIT_SEC", 45);
    cfg.execute = env_flag("LEAP_EXECUTE", false);
    if !cfg.execute {
        print("leap: LEAP_EXECUTE not set -- dry run (discover + plan only)");
    }

    let report = continuum::run_leap(cfg);
    if report.ok && report.dry_run {
        print("leap: dry run complete; re-run with LEAP_EXECUTE=1 to write");
        return;
    }
    if report.ok {
        print("leap: LEAP_OK");
        return;
    }
    print("leap: LEAP_FAILED phase=", report.phase, " outcome=",
        continuum::leap_outcome_name(report.outcome), " reason=", report.reason);
    exit(1);
}
