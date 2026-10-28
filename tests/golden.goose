// Golden artifact suite: byte-exact pins for the two optimization-sensitive
// surfaces — the run_daemon(12) transcript summary and the exact
// meta_request_body bytes for the fixed cfg (toolbind.goose:222:
// max_tool_rounds=4 serial config).
// Goldens pin VALUES, never timings. No timing is asserted anywhere here.
// Run: goose run tests/golden.goose   (exit 0 = all green, ends GOLDEN_ALL_GREEN)
// Discipline: NEVER regenerate a golden to force green. A mismatch means
// behavior changed — read the printed diff, find the semantic cause, and only
// update the golden for an authorized semantic change with the diff inspected.
import lib from "../src";
import std;
import os;

fn check(cond: bool, label: const u8[:]) {
    if !cond {
        print("FAIL ", label);
        abort(str("golden contract violated: ", label));
    }
    print("ok ", label);
}

// Byte-exact compare with a located diff on mismatch. expected is the
// checked-in golden, actual is today's behavior.
fn expect_bytes_equal(expected: const u8[:], actual: const u8[:], label: const u8[:]) {
    if expected.len != actual.len {
        print("FAIL golden length mismatch ", label,
            " golden_len=", expected.len, " actual_len=", actual.len);
        abort(str("golden length mismatch: ", label));
    }
    var line: i64 = 1;
    var i: i64 = 0;
    while i < expected.len {
        if expected[i] == 10 {
            line += 1;
        }
        if expected[i] != actual[i] {
            print("FAIL golden byte mismatch ", label,
                " byte=", i, " line~=", line,
                " golden=", expected[i], " actual=", actual[i]);
            abort(str("golden byte mismatch: ", label));
        }
        i += 1;
    }
    print("ok ", label);
}

fn daemon_summary() -> u8[>..] {
    let r = continuum::run_daemon(12);
    var s: u8[>..] = [];
    s.append("ticks=");
    json::format_int(s, r.ticks);
    s.append("\nobservations=");
    json::format_int(s, r.observations);
    s.append("\napplies=");
    json::format_int(s, r.applies);
    s.append("\nrestores=");
    json::format_int(s, r.restores);
    s.append("\nmodel_calls=");
    json::format_int(s, r.model_calls);
    s.append("\nescalations=");
    json::format_int(s, r.escalations);
    s.append("\ntokens_estimated=");
    json::format_int(s, r.tokens_estimated);
    s.append("\nstatus=");
    if r.outcome.status == continuum::Status.Completed {
        s.append("Completed");
    } else {
        s.append("NOT-Completed");
    }
    s.append("\nmessage=");
    s.append(r.outcome.message);
    s.append("\nprofile=");
    s.append(continuum::sim_current_profile_id());
    s.append("\n");
    return s;
}

fn main() {
    // Surface 1: daemon transcript summary for the fixed 12-tick schedule.
    var golden_sum: u8[>..] = [];
    check(read_file("tests/golden/daemon-12tick.summary.golden", golden_sum),
        "daemon summary golden readable");
    let actual_sum = daemon_summary();
    expect_bytes_equal(golden_sum, actual_sum, "daemon-12tick summary byte-exact");

    // Surface 2: exact meta_request_body bytes, fixed cfg from toolbind.goose:222.
    var golden_body: u8[>..] = [];
    check(read_file("tests/golden/meta-request-body.golden.json", golden_body),
        "meta body golden readable");
    var tools_buf: u8[>..] = [];
    var tools_text: u8[>..] = [];
    check(read_file("schemas/meta-tools.json", tools_text), "meta tools fixture readable");
    tools_buf.append(tools_text);
    let mcfg = continuum::ModelConfig {
        base_url: "https://api.meta.ai/v1",
        controller_model: "muse-wonder-1.0",
        task_model: "muse-wonder-1.0",
        api_key_env_name: "MODEL_API_KEY",
        request_timeout_ms: 10000,
        max_output_tokens: 2048,
        max_tool_rounds: 4,
    };
    var mbody: u8[>..] = [];
    check(continuum::meta_request_body(mcfg, "muse-wonder-1.0",
            "You are the controller.", "ctx-1 evidence", tools_buf, mbody),
        "meta request body builds");
    expect_bytes_equal(golden_body, mbody, "meta request body byte-exact");

    print("GOLDEN_ALL_GREEN");
}
