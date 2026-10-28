// End-to-end (item 6): the full Goose loop against the virtual router
// over real HTTP. NOT part of `make test`: it talks to the C++ double
// (tests/router_double.cpp), which `make web-e2e-run` spawns itself
// with a test-only password. ROUTER_HOST/ROUTER_PORT/ROUTER_PASSWORD
// can still point the binary at any other double instance.
//
//   make web-e2e-run        # self-contained
//
// What it proves: an envelope validated by tooljson, admitted by the
// guardian, applied through the C++ transport to a router that bumps its
// revision, verified by readback, restored, and reconciled - with the lease
// echo checked at every step. Exit 0 prints WEB_E2E_ALL_GREEN.
import lib from "../src";
import std;
import os;
import json;

fn check(cond: bool, label: const u8[:]) {
    if !cond {
        print("FAIL ", label);
        abort(str("web_e2e contract violated: ", label));
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

fn getenv_i64(name: const u8[:], fallback: i64) -> i64 {
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

fn main() {
    var host_b: u8[>..] = [];
    getenv_into("ROUTER_HOST", "127.0.0.1", host_b);
    let port = getenv_i64("ROUTER_PORT", 18081);
    continuum::beat("e2e-start", "web loop against virtual router");

    // One bloated observation from the sim, one validated apply envelope.
    // The envelope carries the ten arguments schemas/meta-tools.json
    // requires; every value is chosen to satisfy the guardian below
    // (owned lab-sim profile, sim-obs evidence, epoch 3, lease in bounds).
    continuum::sim_reset(77);
    let obs = continuum::sim_observe("sim0", 0).observation;
    check(continuum::bloat_detected(obs, 100.0), "sim is bloated");
    var env_text: u8[>..] = [];
    env_text.append("{\"tool\":\"apply_profile\",\"arguments\":{");
    env_text.append("\"request_id\":\"web-req-1\",");
    env_text.append("\"scope_id\":\"lab-sim\",\"path_id\":\"sim0\",");
    env_text.append("\"profile_id\":\"sqm-fair\",\"observation_id\":\"sim-obs\",");
    env_text.append("\"task_revision\":1,\"route_epoch\":3,");
    env_text.append("\"config_revision\":1,\"lease_ms\":10000,");
    env_text.append("\"rationale\":\"web e2e: drain bloated queue with fair profile\"}}");
    let vc0 = continuum::validate_apply_call(env_text);
    check(vc0.ok, "tooljson validates the apply envelope");
    let cat = continuum::list_profiles("lab-sim");
    check(cat.profiles.len == 2, "catalogue lists both sim profiles");
    let fair = cat.profiles[1];
    check(fair.profile_id == "sqm-fair", "slot 1 is the fair profile");

    // Dispatch binding (the controller's job, not the model's): the envelope
    // carries no revision; the dispatcher stamps the catalogue revision the
    // guardian must match before admission.
    var vc = vc0;
    vc.request.expected_revision = fair.revision;
    let adm = continuum::admit_action(vc.request, obs, fair, continuum::sim_now_ms());
    check(adm.admitted, "guardian admits the validated request");

    let before = continuum::web_reconcile("lab-sim", "probe", 0, host_b, port);
    check(before.revision >= 0, "pre-apply revision reads back");
    print("WEB-E2E pre revision=", before.revision);

    let ap = continuum::web_apply(fair.profile_id, fair.configured_rate_kbit / 1000,
        "lab-sim", adm.action_id, fair.revision, host_b, port);
    check(ap.ok && ap.verified, "apply returns a verified receipt");
    check(ap.revision == before.revision + 1, "router revision advances by exactly one");
    print("WEB-E2E applied verified revision=", ap.revision);
    continuum::beat("e2e-apply", "virtual router applied and verified");

    let sync = continuum::web_reconcile("lab-sim", adm.action_id, ap.revision,
        host_b, port);
    check(sync.ok, "reconcile confirms the applied revision");
    check(sync.revision == ap.revision, "reconciled revision matches the receipt");
    print("WEB-E2E reconcile in_sync revision=", sync.revision);

    let rs = continuum::web_restore("lab-sim", adm.action_id, ap.revision, host_b, port);
    check(rs.ok && rs.verified, "restore returns a verified receipt");
    let after = continuum::web_reconcile("lab-sim", adm.action_id, ap.revision,
        host_b, port);
    check(!after.ok, "post-restore state reports drift");
    print("WEB-E2E restored, drift reported as expected");
    continuum::beat("e2e-done", "web loop green");

    print("WEB_E2E_ALL_GREEN");
}
