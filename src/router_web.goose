// The WebApi actuator in Goose (item 6): request JSON out, receipt in.
// The bytes cross into C through native/goose_bridge.c, which reframes the
// slices and calls native/router_web.cpp. This module owns the Goose side:
// building the request from an admitted ActionRequest, mapping transport
// statuses, and parsing the receipt with the same JSON checks as item 1.
// Router passwords never appear here: the native layer reads
// ROUTER_PASSWORD from the environment itself.
import .contracts;
import .tooljson;
import json;
namespace continuum;

extern fn ct_apply_json(req: const u8[:], receipt: u8[:], receipt_len: i64&) -> i32;
extern fn ct_restore_json(req: const u8[:], receipt: u8[:], receipt_len: i64&) -> i32;
extern fn ct_reconcile_json(req: const u8[:], receipt: u8[:], receipt_len: i64&) -> i32;

struct WebResult {
    ok: bool = false,
    reason: u8[..256] = "",
    revision: i64 = -1,
    verified: bool = false,
}

fn bad_web(reason: const u8[:]) -> WebResult {
    return WebResult { ok: false, reason: reason };
}

fn transport_reason(rc: i32) -> const u8[:] {
    if rc == -4 {
        return "router rejected the call (auth or scope)";
    }
    if rc == -1 {
        return "transport refused the request shape";
    }
    if rc == -2 {
        return "receipt buffer too small";
    }
    if rc == -5 {
        return "transport failed (unreachable or timeout)";
    }
    return "unknown transport status";
}

// {"host":..,"port":..,"profile_id":..,"rate_mbit":..,
//  "scope_id":..,"lease_id":..,"revision":..}
// Ids are pattern-checked, so no quoting or escaping issue can smuggle
// syntax in; the port and rate are range-checked integers.
fn web_request_json(profile_id: const u8[:], rate_mbit: i64,
        scope_id: const u8[:], lease_id: const u8[:], revision: i64,
        host: const u8[:], port: i64, out: u8[>..]&) -> bool {
    if !valid_id(profile_id, 64) || !valid_id(scope_id, 64)
            || !valid_id(lease_id, 64) || !valid_id(host, 253) {
        return false;
    }
    if rate_mbit < 1 || rate_mbit > 1000 || port <= 0 || port > 65535
            || revision < 0 {
        return false;
    }
    out.append("{\"host\":\"");
    out.append(host);
    out.append("\",\"port\":");
    json::format_int(out, port);
    out.append(",\"profile_id\":\"");
    out.append(profile_id);
    out.append("\",\"rate_mbit\":");
    json::format_int(out, rate_mbit);
    out.append(",\"scope_id\":\"");
    out.append(scope_id);
    out.append("\",\"lease_id\":\"");
    out.append(lease_id);
    out.append("\",\"revision\":");
    json::format_int(out, revision);
    out.append("}");
    return true;
}

fn parse_receipt(text: u8[:], lease_id: const u8[:], kind: i64) -> WebResult {
    if text.len <= 0 || text.len > 2048 {
        return bad_web("receipt size outside 1..2048");
    }
    var doc: json::Node[>..] = [];
    var decoded: u8[>..] = [];
    let root, err = json::parse(text, doc, decoded);
    if !root {
        return bad_web("receipt is not JSON");
    }
    // The marker must match the issued operation: an apply receipt never
    // proves a restore and vice versa. kind mirrors web_call (0 = apply,
    // 1 = restore); any other kind accepts no mutation marker.
    var ok_key = if kind == 0 { json::member(root, "applied") }
        else if kind == 1 { json::member(root, "restored") }
        else { json::member(root, "") };
    // Neither backend ever emits both markers: a receipt carrying the
    // other operation's marker is contradictory, not lenient.
    var other = if kind == 0 { json::member(root, "restored") }
        else if kind == 1 { json::member(root, "applied") }
        else { json::member(root, "") };
    if other {
        return bad_web("receipt mixes apply and restore markers");
    }
    let done, is_b = json::as_bool(ok_key);
    if !is_b || !done {
        return bad_web("receipt does not confirm the mutation");
    }
    let ver, is_v = json::as_bool(json::member(root, "verified"));
    if !is_v || !ver {
        return bad_web("receipt lacks readback verification");
    }
    let rev, is_r = json::as_i64(json::member(root, "revision"));
    if !is_r || rev < 0 {
        return bad_web("receipt lacks a revision");
    }
    let got_lease, is_l = json::as_string(json::member(root, "lease_id"));
    if !is_l || got_lease != lease_id {
        return bad_web("receipt lease does not match");
    }
    return WebResult { ok: true, revision: rev, verified: true };
}

fn web_call(kind: i64, req_text: const u8[:], lease_id: const u8[:]) -> WebResult {
    // Scratch output buffer: the native call needs the capacity, not the
    // length, so fill the bounded array outright; the callee reports how
    // many bytes it actually wrote through receipt_len.
    var receipt: u8[..2048] = [0; 2048];
    var n: i64 = 0;
    let rc = if kind == 0 { ct_apply_json(req_text, receipt, n) }
        else if kind == 1 { ct_restore_json(req_text, receipt, n) }
        else { ct_reconcile_json(req_text, receipt, n) };
    if rc != 0 {
        return bad_web(transport_reason(rc));
    }
    if n <= 0 || n > receipt.len {
        return bad_web("transport returned no receipt");
    }
    return parse_receipt(receipt[..n], lease_id, kind);
}

fn web_apply(profile_id: const u8[:], rate_mbit: i64, scope_id: const u8[:],
        lease_id: const u8[:], revision: i64, host: const u8[:], port: i64) -> WebResult {
    var req_text: u8[>..] = [];
    if !web_request_json(profile_id, rate_mbit, scope_id, lease_id,
            revision, host, port, req_text) {
        return bad_web("request fields invalid");
    }
    return web_call(0, req_text, lease_id);
}

fn web_restore(scope_id: const u8[:], lease_id: const u8[:], revision: i64,
        host: const u8[:], port: i64) -> WebResult {
    var req_text: u8[>..] = [];
    if !web_request_json("baseline-fifo", 100, scope_id, lease_id,
            revision, host, port, req_text) {
        return bad_web("request fields invalid");
    }
    return web_call(1, req_text, lease_id);
}

fn parse_reconcile_receipt(text: u8[:], revision: i64) -> WebResult {
    if text.len <= 0 || text.len > 2048 {
        return bad_web("receipt size outside 1..2048");
    }
    var doc: json::Node[>..] = [];
    var decoded: u8[>..] = [];
    let root, err = json::parse(text, doc, decoded);
    if !root {
        return bad_web("receipt is not JSON");
    }
    let rev, is_r = json::as_i64(json::member(root, "revision"));
    if !is_r || rev < 0 {
        return bad_web("receipt lacks a revision");
    }
    let sync, is_s = json::as_bool(json::member(root, "in_sync"));
    if !is_s {
        return bad_web("receipt lacks sync state");
    }
    // Bind the answer to the question: the receipt echoes the expectation
    // the request carried, and a true in_sync must agree with both the
    // reported and the requested revision. Trusting in_sync alone accepts
    // stale or crossed responses as current truth.
    let exp, is_e = json::as_i64(json::member(root, "expected_revision"));
    if !is_e || exp != revision {
        return bad_web("receipt answers a different expectation");
    }
    if sync && rev != revision {
        return bad_web("receipt claims sync at a moved revision");
    }
    return WebResult { ok: sync, revision: rev, verified: true,
        reason: if sync { "" } else { "router drifted from expected revision" } };
}

fn web_reconcile(scope_id: const u8[:], lease_id: const u8[:],
        revision: i64, host: const u8[:], port: i64) -> WebResult {
    var req_text: u8[>..] = [];
    if !web_request_json("baseline-fifo", 100, scope_id, lease_id,
            revision, host, port, req_text) {
        return bad_web("request fields invalid");
    }
    var receipt: u8[..2048] = [0; 2048];
    var n: i64 = 0;
    let rc = ct_reconcile_json(req_text, receipt, n);
    if rc != 0 {
        return bad_web(transport_reason(rc));
    }
    if n <= 0 || n > receipt.len {
        return bad_web("transport returned no receipt");
    }
    return parse_reconcile_receipt(receipt[..n], revision);
}
