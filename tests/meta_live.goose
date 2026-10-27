// Manual live probe (item M01/C03): one real Meta Responses round trip.
// NOT part of `make test`: it needs MODEL_API_KEY in the environment and
// spends one bounded provider call.
//
// Build on macOS (pinned toolchain):
//   cd tests
//   ../.build/toolchain/goose-v2026.3-macos-arm64/goose \
//       -o meta_live.c meta_live.goose
//   cc -O2 meta_live.c ../native/goose_bridge.c ../native/meta_web.cpp \
//       -o meta_live -lstdc++ -pthread
// Run with no key (fail-closed check, no network spent):
//   ./meta_live
// Run live (one bounded call, read-only intent):
//   MODEL_API_KEY='<key>' META_CONTROLLER_MODEL='muse-wonder-1.0' ./meta_live
//
// What it proves: without a key the adapter fails closed with no network;
// with a key, one real request returns a typed parse - model, response
// and call ids, allowlisted tool or explicit abstention - and provenance
// Live. Nothing here acts on the network: any tool call the model
// returns is printed, never dispatched. Exit 0 prints META_LIVE_*.
import lib from "../src";
import std;
import os;
import json;

fn check(cond: bool, label: const u8[:]) {
    if !cond {
        print("FAIL ", label);
        abort(str("meta_live contract violated: ", label));
    }
    print("ok ", label);
}

fn getenv_into(name: const u8[:], fallback: const u8[:], out: u8[>..]&) {
    var v: u8[>..] = [];
    if env(name, v) && v.len > 0 && v.len <= 256 {
        out.append(v);
        return;
    }
    out.append(fallback);
}

fn base_config() -> continuum::ModelConfig {
    var model_b: u8[>..] = [];
    getenv_into("META_CONTROLLER_MODEL", "muse-wonder-1.0", model_b);
    var cfg = continuum::ModelConfig {
        base_url: "https://api.meta.ai/v1",
        request_timeout_ms: 30000,
        max_output_tokens: 2048,
        max_tool_rounds: 4,
    };
    cfg.controller_model = model_b;
    cfg.task_model = model_b;
    return cfg;
}

fn main() {
    // Fail-closed without credentials: an absent key source must fail
    // before any socket opens, with provenance Unset.
    var absent_cfg = base_config();
    absent_cfg.api_key_env_name = "CONTINUUM_DEFINITELY_ABSENT_KEY";
    let absent_req = continuum::ModelRequest {
        request_id: "live-probe-nokey",
        run_id: "live-probe",
        role_id: "controller",
        prompt_revision: "controller.md",
        context: "no-key probe: this request must never leave the machine",
    };
    let absent = continuum::request_meta(absent_cfg, absent_req);
    check(absent.outcome.status == continuum::Status.Failed,
        "absent key fails closed");
    check(absent.provenance == continuum::Provenance.Unset,
        "absent key leaves provenance Unset");
    check(!absent.has_tool_call, "absent key yields no tool call");

    // Live round trip only when a key is actually present. Presence is a
    // non-empty read; the value itself is never printed or logged.
    var key_probe: u8[>..] = [];
    let have_key = env("MODEL_API_KEY", key_probe) && key_probe.len > 0;
    if !have_key {
        print("META_LIVE_SKIPPED_NO_KEY");
        return;
    }
    let cfg = base_config();
    let req = continuum::ModelRequest {
        request_id: "live-probe-1",
        run_id: "live-probe",
        role_id: "controller",
        prompt_revision: "controller.md",
        context: "live probe: a lab queue is bloated (sim0). Reply with one read_observation call for path sim0, or abstain in prose. Take no other action.",
    };
    let r = continuum::request_meta(cfg, req);
    check(r.outcome.status == continuum::Status.Completed,
        "live round trip completes");
    check(r.provenance == continuum::Provenance.Live,
        "live round trip is provenance Live");
    check(r.provider_model_id.len > 0, "provider reports its model id");
    check(r.response_id.len > 0, "provider returns a response id");
    check(r.request_id == "live-probe-1", "request id correlates");
    print("META-LIVE model=", r.provider_model_id);
    print("META-LIVE response=", r.response_id);
    if r.has_tool_call {
        check(r.call_id.len > 0, "tool call carries a call id");
        print("META-LIVE tool call=", r.call_id);
        // Read-only calls validate locally; anything else is reported,
        // never dispatched by this probe.
        if r.tool == continuum::ToolName.ReadObservation {
            var call_text: u8[>..] = [];
            call_text.append("{\"tool\":\"read_observation\",\"arguments\":");
            call_text.append(r.arguments_json);
            call_text.append("}");
            check(continuum::validate_read_call(call_text,
                    continuum::ToolName.ReadObservation).ok,
                "live read_observation call validates");
        }
    } else {
        print("META-LIVE abstention (prose, no tool call)");
    }

    print("META_LIVE_ROUND_TRIP");
}
