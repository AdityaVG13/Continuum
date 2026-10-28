// Fuzz lane, round 1: seeded-PRNG mutator over the known-good apply
// envelope (validate_apply_call) + fixed adversarial shapes for
// meta_parse_response. Reports bugs, fixes nothing: any crash/hang or
// accept-that-should-reject (or reject-that-should-accept) aborts here
// with the seed/iter/class that triggered it; bug-hunt lanes fix src.
// Run: goose run tests/fuzz_tooljson.goose   (exit 0 = FUZZ_ALL_GREEN)
import lib from "../src";
import std;
import os;

fn check(cond: bool, label: const u8[:]) {
    if !cond {
        print("FAIL ", label);
        abort(str("fuzz violated: ", label));
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

// Harness-side copy of the catalogue-id rule (src/tooljson.goose:
// 1..64 bytes of [A-Za-z0-9_.:-]). Used only to state expectations for
// the string-pool class; the validator under test is never consulted.
fn harness_valid_id(s: const u8[:]) -> bool {
    if s.len <= 0 || s.len > 64 {
        return false;
    }
    for i in 0..s.len {
        let b = s[i];
        let alnum = (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9');
        if !alnum && b != '_' && b != '.' && b != ':' && b != '-' {
            return false;
        }
    }
    return true;
}

// Fixed field fragments of the canonical seed (values mirror
// fixtures/apply-profile.example.json; the control below pins that).
fn emit_field(out: u8[>..]&, k: i64) {
    if k == 0 {
        out.append("\"request_id\":\"action-example-1\"");
    } else if k == 1 {
        out.append("\"scope_id\":\"lab-uplink\"");
    } else if k == 2 {
        out.append("\"path_id\":\"owned-lab-path\"");
    } else if k == 3 {
        out.append("\"profile_id\":\"balanced-calibrated\"");
    } else if k == 4 {
        out.append("\"observation_id\":\"obs-synthetic-3\"");
    } else if k == 5 {
        out.append("\"task_revision\":2");
    } else if k == 6 {
        out.append("\"route_epoch\":1");
    } else if k == 7 {
        out.append("\"config_revision\":7");
    } else if k == 8 {
        out.append("\"lease_ms\":30000");
    } else {
        out.append("\"rationale\":\"Synthetic example: stable gateway and elevated remote echo under sustained upload make an owned-queue trial plausible; verify latency and useful throughput.\"");
    }
}

fn canonical_seed() -> u8[>..] {
    var b: u8[>..] = [];
    b.append("{\"tool\":\"apply_profile\",\"arguments\":{");
    for k in 0..10 {
        if k > 0 {
            b.append(",");
        }
        emit_field(b, k);
    }
    b.append("}}");
    return b;
}

fn same_request(a: continuum::ValidCall, b: continuum::ValidCall) -> bool {
    return a.ok && b.ok
        && a.request.request_id == b.request.request_id
        && a.request.scope_id == b.request.scope_id
        && a.request.path_id == b.request.path_id
        && a.request.profile_id == b.request.profile_id
        && a.request.observation_id == b.request.observation_id
        && a.request.task_revision == b.request.task_revision
        && a.request.route_epoch == b.request.route_epoch
        && a.request.config_revision == b.request.config_revision
        && a.request.lease_ms == b.request.lease_ms
        && a.request.rationale == b.request.rationale;
}

fn main() {
    // --- controls: both seeds accept, and decode identically ---
    let fixture = read_fixture("fixtures/apply-profile.example.json");
    let vf = continuum::validate_apply_call(fixture);
    check(vf.ok, "fuzz fixture seed accepts");
    let base = canonical_seed();
    let vb = continuum::validate_apply_call(base);
    check(vb.ok, "fuzz canonical seed accepts");
    check(same_request(vf, vb), "fuzz seeds decode identically");
    check(vb.request.lease_ms == 30000, "fuzz seed lease pins 30000");

    var n_total: i64 = 0;
    var n_accept: i64 = 0;
    var n_reject: i64 = 0;

    // --- deterministic sweep: truncate at every 16th byte, both seeds ---
    var cut: i64 = 0;
    while cut < base.len {
        check(!continuum::validate_apply_call(base[..cut]).ok, "fuzz canonical prefix rejects");
        n_total += 1;
        n_reject += 1;
        cut += 16;
    }
    cut = 0;
    while cut < fixture.len {
        check(!continuum::validate_apply_call(fixture[..cut]).ok, "fuzz fixture prefix rejects");
        n_total += 1;
        n_reject += 1;
        cut += 16;
    }
    print("ok fuzz truncate sweep done total=", n_total);

    // --- seeded PRNG loop: 6 mutation classes over the canonical seed ---
    var seeds: u64[>..] = [];
    seeds.push(11);
    seeds.push(77);
    seeds.push(104729);
    let iters: i64 = 2000;

    var a64: u8[>..] = [];
    push_n(a64, 'a', 64);
    var a65: u8[>..] = [];
    push_n(a65, 'a', 65);
    var uni_e: u8[>..] = [];
    uni_e.append("id-");
    push_utf8(uni_e, 233);

    for s in seeds {
        var r = rng { s };
        var i: i64 = 0;
        while i < iters {
            let class = rand_int(r, 6);
            var mut: u8[>..] = [];
            // expectation bookkeeping: -1 = must reject, 0 = either way
            // with decoded-equality on accept, 1 = must accept identical
            var expect: i64 = -1;
            if class == 0 {
                // byte-truncate at a random point
                let at = 1 + rand_int(r, base.len - 1);
                mut.append(base[..at]);
            } else if class == 1 {
                // field-duplicate, identical value: first wins, must accept
                mut.append(base[..base.len - 2]);
                mut.append(",");
                emit_field(mut, rand_int(r, 10));
                mut.append("}}");
                expect = 1;
            } else if class == 2 {
                // lease_ms int-boundary / type swap
                let pick = rand_int(r, 12);
                var rep: u8[>..] = [];
                rep.append("\"lease_ms\":");
                var acc = false;
                var want: i64 = 0;
                if pick == 0 {
                    rep.append("999");
                } else if pick == 1 {
                    rep.append("-1");
                } else if pick == 2 {
                    rep.append("0");
                } else if pick == 3 {
                    rep.append("1000");
                    acc = true;
                    want = 1000;
                } else if pick == 4 {
                    rep.append("60000");
                    acc = true;
                    want = 60000;
                } else if pick == 5 {
                    rep.append("60001");
                } else if pick == 6 {
                    rep.append("999999");
                } else if pick == 7 {
                    rep.append("9223372036854775807");
                } else if pick == 8 {
                    rep.append("-9223372036854775808");
                } else if pick == 9 {
                    rep.append("\"30000\"");
                } else if pick == 10 {
                    rep.append("true");
                } else {
                    rep.append("null");
                }
                format_replaced(mut, base[..], "\"lease_ms\":30000", rep[..]);
                if acc {
                    let v = continuum::validate_apply_call(mut[..]);
                    print("fuzz lease accept-check seed=", s, " iter=", i, " pick=", pick);
                    check(v.ok && v.request.lease_ms == want, "fuzz in-range lease swap accepts with swapped value");
                    n_total += 1;
                    n_accept += 1;
                    i += 1;
                    continue;
                }
            } else if class == 3 {
                // string-pool injection into request_id / scope_id
                let target_req = rand_int(r, 2) == 0;
                let pick = rand_int(r, 12);
                var withb: u8[>..] = [];
                var acc = false;
                var want_id: u8[>..] = [];
                if pick == 0 {
                    withb.append("a");
                    acc = true;
                    want_id.append("a");
                } else if pick == 1 {
                    withb.append(a64[..]);
                    acc = true;
                    want_id.append(a64[..]);
                } else if pick == 2 {
                    withb.append("A0:b.c_d-e");
                    acc = true;
                    want_id.append("A0:b.c_d-e");
                } else if pick == 3 {
                    withb.append("\\u0041");
                    acc = true;
                    want_id.append("A");
                } else if pick == 4 {
                    withb.append("");
                } else if pick == 5 {
                    withb.append("req 5 spaces");
                } else if pick == 6 {
                    withb.append("a/b");
                } else if pick == 7 {
                    withb.append(a65[..]);
                } else if pick == 8 {
                    withb.append("a\\tb");
                } else if pick == 9 {
                    withb.append(uni_e[..]);
                } else if pick == 10 {
                    withb.append(" ");
                } else {
                    withb.append("x;y");
                }
                var frag: u8[>..] = [];
                if target_req {
                    frag.append("\"request_id\":\"action-example-1\"");
                } else {
                    frag.append("\"scope_id\":\"lab-uplink\"");
                }
                var rep2: u8[>..] = [];
                if target_req {
                    rep2.append("\"request_id\":\"");
                } else {
                    rep2.append("\"scope_id\":\"");
                }
                rep2.append(withb[..]);
                rep2.append("\"");
                format_replaced(mut, base[..], frag[..], rep2[..]);
                if acc {
                    let v = continuum::validate_apply_call(mut[..]);
                    print("fuzz id accept-check seed=", s, " iter=", i, " pick=", pick);
                    // pick 3 is a JSON \u-escape: the source text is not
                    // itself a valid id, only its decoding ("A") is.
                    if pick != 3 {
                        check(harness_valid_id(withb[..]), "fuzz harness pool entry is a valid id");
                    }
                    var got_ok = false;
                    if target_req {
                        got_ok = v.ok && v.request.request_id == want_id[..];
                    } else {
                        got_ok = v.ok && v.request.scope_id == want_id[..];
                    }
                    check(got_ok, "fuzz valid id injection accepts with injected value");
                    n_total += 1;
                    n_accept += 1;
                    i += 1;
                    continue;
                }
            } else if class == 4 {
                // nesting-depth growth: unknown deep key, or rationale type swap
                let variant = rand_int(r, 3);
                if variant == 0 {
                    mut.append(base[..base.len - 2]);
                    mut.append(",\"zz_nest\":");
                    var d: i64 = 0;
                    while d < 128 {
                        mut.push('[');
                        d += 1;
                    }
                    d = 0;
                    while d < 128 {
                        mut.push(']');
                        d += 1;
                    }
                    mut.append("}}");
                } else if variant == 1 {
                    // rationale frag is literal-duplicated from emit_field;
                    // if it ever drifts, no replacement happens, the mutant
                    // equals the seed, and the must-reject check below fires.
                    format_replaced(mut, base[..],
                        "\"rationale\":\"Synthetic example: stable gateway and elevated remote echo under sustained upload make an owned-queue trial plausible; verify latency and useful throughput.\"",
                        "\"rationale\":[[[\"x\"]]]");
                } else {
                    format_replaced(mut, base[..],
                        "\"rationale\":\"Synthetic example: stable gateway and elevated remote echo under sustained upload make an owned-queue trial plausible; verify latency and useful throughput.\"",
                        "\"rationale\":7");
                }
            } else {
                // argument-order permutation: same bytes, shuffled keys.
                // Order must not matter: must accept with identical decode.
                var idx: i64[>..] = [];
                for k in 0..10 {
                    idx.push(k);
                }
                var j = 9;
                while j > 0 {
                    swap_at(idx[..], j, rand_int(r, j + 1));
                    j -= 1;
                }
                mut.append("{\"tool\":\"apply_profile\",\"arguments\":{");
                for k in 0..10 {
                    if k > 0 {
                        mut.append(",");
                    }
                    emit_field(mut, idx[k]);
                }
                mut.append("}}");
                expect = 1;
            }
            let v = continuum::validate_apply_call(mut[..]);
            if v.ok {
                n_accept += 1;
            } else {
                n_reject += 1;
            }
            n_total += 1;
            if expect == 1 {
                print("fuzz equiv-accept check seed=", s, " iter=", i, " class=", class);
                check(v.ok && same_request(v, vb), "fuzz semantics-preserving mutant accepts identically");
            } else {
                if v.ok {
                    print("fuzz UNEXPECTED ACCEPT seed=", s, " iter=", i, " class=", class,
                        " len=", mut.len, " head=", mut[..min(mut.len, 160)]);
                    check(false, "fuzz breaking mutant must reject");
                }
            }
            i += 1;
        }
    }
    print("fuzz apply loop done total=", n_total, " accept=", n_accept, " reject=", n_reject);
    check(n_accept > 0, "fuzz accept-path exercised");
    check(n_accept + n_reject == n_total, "fuzz stats balance");

    // --- second target: meta_parse_response adversarial shapes (fixed) ---
    let resp = str("{\"id\":\"resp-1\",\"model\":\"muse-spark\",\"output\":[{\"type\":\"function_call\",\"call_id\":\"call-9\",\"name\":\"read_observation\",\"arguments\":\"{\\\"path_id\\\":\\\"sim0\\\",\\\"max_age_ms\\\":1000}\"}]}");
    var mr0 = continuum::ModelResult {};
    var ma0: u8[>..] = [];
    var mt0: u8[>..] = [];
    check(continuum::meta_parse_response(resp, "req-shape", mr0, ma0, mt0)
        && mr0.has_tool_call && mr0.call_id == "call-9", "fuzz meta control accepts");

    var mr1 = continuum::ModelResult {};
    var ma1: u8[>..] = [];
    var mt1: u8[>..] = [];
    var big: u8[>..] = [];
    big.append("{\"id\":\"resp-big\",\"model\":\"muse-spark\",\"output\":[{\"type\":\"function_call\",\"call_id\":\"call-big\",\"name\":\"read_observation\",\"arguments\":\"");
    push_n(big, 'x', 1000000);
    big.append("\"}]}");
    check(!continuum::meta_parse_response(big[..], "req-big", mr1, ma1, mt1), "fuzz meta 1MB arguments blob rejects");

    let two = str("{\"id\":\"resp-2\",\"model\":\"muse-spark\",\"output\":[{\"type\":\"function_call\",\"call_id\":\"c1\",\"name\":\"read_observation\",\"arguments\":\"{\\\"path_id\\\":\\\"sim0\\\",\\\"max_age_ms\\\":1000}\"},{\"type\":\"function_call\",\"call_id\":\"c2\",\"name\":\"read_observation\",\"arguments\":\"{\\\"path_id\\\":\\\"sim0\\\",\\\"max_age_ms\\\":1000}\"}]}");
    var mr2 = continuum::ModelResult {};
    var ma2: u8[>..] = [];
    var mt2: u8[>..] = [];
    check(!continuum::meta_parse_response(two, "req-2", mr2, ma2, mt2), "fuzz meta double function_call rejects");

    let evil = str("{\"id\":\"resp-3\",\"model\":\"muse-spark\",\"output\":[{\"type\":\"function_call\",\"call_id\":\"e1\",\"name\":\"format_disk\",\"arguments\":\"{}}\"},{\"type\":\"function_call\",\"call_id\":\"c3\",\"name\":\"read_observation\",\"arguments\":\"{\\\"path_id\\\":\\\"sim0\\\",\\\"max_age_ms\\\":1000}\"}]}");
    var mr3 = continuum::ModelResult {};
    var ma3: u8[>..] = [];
    var mt3: u8[>..] = [];
    check(!continuum::meta_parse_response(evil, "req-3", mr3, ma3, mt3), "fuzz meta unknown name interleaved rejects");

    let evil1 = str("{\"id\":\"resp-4\",\"model\":\"muse-spark\",\"output\":[{\"type\":\"function_call\",\"call_id\":\"e1\",\"name\":\"format_disk\",\"arguments\":\"{\\\"path_id\\\":\\\"sim0\\\"}\"}]}");
    var mr4 = continuum::ModelResult {};
    var ma4: u8[>..] = [];
    var mt4: u8[>..] = [];
    check(!continuum::meta_parse_response(evil1, "req-4", mr4, ma4, mt4), "fuzz meta lone unknown name rejects");

    let mixed = str("{\"id\":\"resp-5\",\"model\":\"muse-spark\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"hi\"}]},{\"type\":\"function_call\",\"call_id\":\"call-9\",\"name\":\"read_observation\",\"arguments\":\"{\\\"path_id\\\":\\\"sim0\\\",\\\"max_age_ms\\\":1000}\"},{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"bye\"}]}]}");
    var mr5 = continuum::ModelResult {};
    var ma5: u8[>..] = [];
    var mt5: u8[>..] = [];
    check(continuum::meta_parse_response(mixed, "req-5", mr5, ma5, mt5)
        && mr5.has_tool_call && mr5.call_id == "call-9", "fuzz meta mixed message/call array accepts one call");

    let noout = str("{\"id\":\"resp-6\",\"model\":\"muse-spark\"}");
    var mr6 = continuum::ModelResult {};
    var ma6: u8[>..] = [];
    var mt6: u8[>..] = [];
    check(!continuum::meta_parse_response(noout, "req-6", mr6, ma6, mt6), "fuzz meta missing output rejects");

    var wide: u8[>..] = [];
    wide.append("{\"id\":\"resp-7\",\"model\":\"muse-spark\",\"output\":[{\"type\":\"function_call\",\"call_id\":\"c7\",\"name\":\"read_observation\",\"arguments\":\"");
    push_n(wide, 'x', 9000);
    wide.append("\"}]}");
    var mr7 = continuum::ModelResult {};
    var ma7: u8[>..] = [];
    var mt7: u8[>..] = [];
    check(!continuum::meta_parse_response(wide[..], "req-7", mr7, ma7, mt7), "fuzz meta oversize arguments rejects");

    let msgonly = str("{\"id\":\"resp-8\",\"model\":\"muse-spark\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"hello\"}]}]}");
    var mr8 = continuum::ModelResult {};
    var ma8: u8[>..] = [];
    var mt8: u8[>..] = [];
    check(continuum::meta_parse_response(msgonly, "req-8", mr8, ma8, mt8)
        && !mr8.has_tool_call, "fuzz meta message-only accepts without call");

    print("FUZZ_ALL_GREEN total=", n_total, " accept=", n_accept, " reject=", n_reject);
}
