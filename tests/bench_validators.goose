// Pass 1 baseline: timed loop harness over the LANE-J validators.
// Read-only w.r.t. src/: invokes real validators on fixed in-tree fixtures,
// N iterations each, and prints per-validator wall time. No optimization,
// no mocks, no weakened assertions — every timed call's verdict is checked.
// Run: goose run tests/bench_validators.goose   (exit 0 = all green)
import lib from "../src";
import std;
import os;

fn check(cond: bool, label: const u8[:]) {
    if !cond {
        print("FAIL ", label);
        abort(str("bench contract violated: ", label));
    }
    print("ok ", label);
}

fn read_fixture(path: const u8[:]) -> u8[>..] {
    var text: u8[>..] = [];
    if !read_file(path, text) {
        print("FAIL missing fixture ", path);
        abort(str("missing fixture: ", path));
    }
    return text;
}

fn main() {
    let iters: i64 = 2000;

    let good_apply = str("{\"tool\":\"apply_profile\",\"arguments\":{",
        "\"request_id\":\"req-1\",\"scope_id\":\"lab-sim\",\"path_id\":\"sim0\",",
        "\"profile_id\":\"sqm-fair\",\"observation_id\":\"sim-obs\",",
        "\"task_revision\":1,\"route_epoch\":3,\"config_revision\":7,",
        "\"lease_ms\":10000,\"rationale\":\"drain the bloated queue\"}}");
    let good_restore = str("{\"tool\":\"restore_profile\",\"arguments\":{",
        "\"request_id\":\"req-r1\",\"scope_id\":\"lab-sim\",\"lease_id\":\"req-1\",",
        "\"expected_revision\":7,\"observation_id\":\"sim-obs\",",
        "\"rationale\":\"verified repair, restore baseline\"}}");
    let hold_text = read_fixture("fixtures/workload-hold.example.json");
    let resp = str("{\"id\":\"resp-1\",\"model\":\"muse-spark\",\"output\":[{\"type\":\"function_call\",\"call_id\":\"call-9\",\"name\":\"read_observation\",\"arguments\":\"{\\\"path_id\\\":\\\"sim0\\\",\\\"max_age_ms\\\":1000}\"}]}");

    // Sanity: timed inputs must be the accept-path fixtures (reject-path
    // timing would measure early exits, not the hot path).
    check(continuum::validate_apply_call(good_apply).ok, "bench apply fixture accepts");
    check(continuum::validate_restore_call(good_restore).ok, "bench restore fixture accepts");
    check(continuum::validate_workload_result(hold_text, "run-example",
        "release-audit-example", 2).ok, "bench workload fixture accepts");

    var ok_count: i64 = 0;
    var t0: i64 = 0;
    var t1: i64 = 0;

    // --- validate_apply_call ---
    t0 = clock_ns();
    var i: i64 = 0;
    while i < iters {
        if continuum::validate_apply_call(good_apply).ok {
            ok_count += 1;
        }
        i += 1;
    }
    t1 = clock_ns();
    let apply_ns = t1 - t0;
    print("bench validate_apply_call iters=", iters, " wall_ns=", apply_ns,
        " ns_per_call=", apply_ns / iters, " ok=", ok_count);
    check(ok_count == iters, "apply all iters accepted");

    // --- validate_restore_call ---
    ok_count = 0;
    t0 = clock_ns();
    i = 0;
    while i < iters {
        if continuum::validate_restore_call(good_restore).ok {
            ok_count += 1;
        }
        i += 1;
    }
    t1 = clock_ns();
    let restore_ns = t1 - t0;
    print("bench validate_restore_call iters=", iters, " wall_ns=", restore_ns,
        " ns_per_call=", restore_ns / iters, " ok=", ok_count);
    check(ok_count == iters, "restore all iters accepted");

    // --- validate_workload_result (hold fixture, 2 blockers) ---
    ok_count = 0;
    t0 = clock_ns();
    i = 0;
    while i < iters {
        if continuum::validate_workload_result(hold_text, "run-example",
                "release-audit-example", 2).ok {
            ok_count += 1;
        }
        i += 1;
    }
    t1 = clock_ns();
    let workload_ns = t1 - t0;
    print("bench validate_workload_result iters=", iters, " wall_ns=", workload_ns,
        " ns_per_call=", workload_ns / iters, " ok=", ok_count);
    check(ok_count == iters, "workload all iters accepted");

    // --- meta_parse_response (tool-call response; fresh out-buffers per
    // iteration, matching real per-call pool behavior) ---
    ok_count = 0;
    t0 = clock_ns();
    i = 0;
    while i < iters {
        var mr = continuum::ModelResult {};
        var margs: u8[>..] = [];
        var mtext: u8[>..] = [];
        if continuum::meta_parse_response(resp, "req-shape", mr, margs, mtext) {
            if mr.has_tool_call && mr.call_id == "call-9" {
                ok_count += 1;
            }
        }
        i += 1;
    }
    t1 = clock_ns();
    let meta_ns = t1 - t0;
    print("bench meta_parse_response iters=", iters, " wall_ns=", meta_ns,
        " ns_per_call=", meta_ns / iters, " ok=", ok_count);
    check(ok_count == iters, "meta all iters accepted");

    print("BENCH_ALL_GREEN");
}
