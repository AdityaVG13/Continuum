// Measurement is evidence, not a claim. One run probes a named target twice —
// idle, then while a bulk transfer fills the same path — and records both
// windows with their sample counts. A run below the sample floor, or one with
// failed probes, is refused rather than averaged into a number that looks like
// an improvement.
import .device;
import .continuity;
import .service;
import json;
import os;
namespace continuum;

extern fn ct_probe_run(host: const u8[:], port: i64, path: const u8[:], samples: i64,
    load_path: const u8[:], load_ms: i64, upload: i64, out: u8[:], length: i64&) -> i32;

const MEASURE_MIN_SAMPLES: i64 = 20;

// `host:port/path` — IPv4 or a plain hostname. The path carries the query, so
// the same endpoint describes idle and loaded probes.
fn measure_target(target: const u8[:], host: u8[..256]&, port: i64&, path: u8[..1025]&) -> bool {
    let slash = target.find("/");
    var authority: u8[..256] = "";
    if slash < 0 { authority.append(target); }
    else { authority.append(target[..slash]); path.clear(); path.append(target[slash..]); }
    let colon = authority.find(":");
    if colon <= 0 || colon >= authority.len { return false; }
    host.clear(); host.append(authority[..colon]);
    var port_text: u8[..8] = "";
    port_text.append(authority[colon + 1..]);
    if host.len == 0 || host.len > 253 || port_text.len == 0 || port_text.len > 5 { return false; }
    var parsed: i64 = 0;
    if !measure_digits(port_text, parsed) || parsed < 1 || parsed > 65535 { return false; }
    port = parsed;
    return true;
}

fn measure_digits(text: const u8[:], out: i64&) -> bool {
    if text.len == 0 || text.len > 5 { return false; }
    var n: i64 = 0;
    var i: i64 = 0;
    while i < text.len {
        let b = text[i];
        if b < '0' || b > '9' { return false; }
        n = n * 10 + (b - '0');
        i += 1;
    }
    out = n;
    return true;
}

fn measure_sample_arg() -> i64 {
    var text: u8[>..] = "";
    if !env("CONTINUUM_MEASURE_SAMPLES", text) { return MEASURE_MIN_SAMPLES; }
    var samples: i64 = 0;
    if !measure_digits(text, samples) { return -1; }
    if samples < MEASURE_MIN_SAMPLES || samples > 200 { return -1; }
    return samples;
}

// The artifact is immutable and uniquely named: a measurement is a record of a
// moment, never something a later run overwrites.
fn measure_cli(directory: const u8[:], target: const u8[:], load_path: const u8[:], upload: bool) -> i64 {
    var host: u8[..256] = ""; var path: u8[..1025] = "/"; var port: i64 = 0;
    if !measure_target(target, host, port, path) {
        print("MEASURE_REFUSED target_must_be_host:port/path");
        return 1;
    }
    if load_path.len == 0 || load_path.len > 1024 || load_path[0] != '/' {
        print("MEASURE_REFUSED load_path_must_be_absolute");
        return 1;
    }
    let samples = measure_sample_arg();
    if samples < 0 {
        // A requested sample count below the floor is refused, not silently
        // raised: the operator asked for a number the evidence cannot support.
        print("MEASURE_REFUSED insufficient_samples");
        return 1;
    }
    var buffer: u8[..65536] = [0; 65536]; var n: i64 = 0;
    if ct_probe_run(host, port, path, samples, load_path, 0, if upload { 1 } else { 0 }, buffer, n) != 0 || n <= 0 || n > buffer.len {
        print("MEASURE_REFUSED probe_unavailable");
        return 1;
    }
    var doc: json::Node[>..] = []; var decoded: u8[>..] = [];
    let root, err = json::parse(buffer[..n], doc, decoded);
    if !root { print("MEASURE_REFUSED probe_result_unreadable"); return 1; }
    let idle_value, idle_ok = json::as_i64(json::member(root, "idle_samples"));
    let loaded_value, loaded_ok = json::as_i64(json::member(root, "loaded_samples"));
    let idle_fail_value, idle_fail_ok = json::as_i64(json::member(root, "idle_failures"));
    let loaded_fail_value, loaded_fail_ok = json::as_i64(json::member(root, "loaded_failures"));
    let load_bytes_value, load_bytes_ok = json::as_i64(json::member(root, "load_bytes"));
    let idle = if idle_ok { idle_value } else { 0 };
    let loaded = if loaded_ok { loaded_value } else { 0 };
    let idle_failures = if idle_fail_ok { idle_fail_value } else { 0 };
    let loaded_failures = if loaded_fail_ok { loaded_fail_value } else { 0 };
    let load_bytes = if load_bytes_ok { load_bytes_value } else { 0 };
    var verdict: u8[..32] = "claimable";
    if idle < samples || loaded < samples { verdict = "insufficient_samples"; }
    else if idle_failures > 0 || loaded_failures > 0 { verdict = "probe_failures"; }
    else if load_bytes <= 0 { verdict = "no_load_observed"; }
    var receipt: u8[..65536] = "";
    receipt.append("{\"verdict\":\""); receipt.append(verdict); receipt.append("\",\"evidence\":");
    receipt.append(buffer[..n]); receipt.append("}");
    let path_text = str(directory, "/device/measure-", time_ns(), ".json");
    let durable = ct_checkpoint_write(path_text, receipt) == 0;
    print(receipt);
    if !durable { print("MEASURE_REFUSED evidence_not_durable"); return 1; }
    if verdict != "claimable" { return 1; }
    return 0;
}
