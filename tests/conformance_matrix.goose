// Conformance matrix (item 2): table-driven sweep over
//   decision x severity x evidence-presence x schema_version
// for validate_workload_result, plus task_revision negative/zero rows.
// Every row cites its oracle: schemas/workload-result.schema.json (the shape
// rule) and src/workload.goose (the meaning rule that rejects beyond shape).
//
// Run: goose run tests/conformance_matrix.goose   (exit 0 = all green, ends
// CONFORMANCE_ALL_GREEN). No network, no router, no ROUTER_* read: the two
// transport rows (web_apply/web_reconcile, src/router_web.goose:128-148) are
// require-lab and always SKIP here with a fail-closed message. Live transport
// proof belongs to `make web-e2e-run` / `make transport-check` (LAB_ROUTER=1),
// never to this file: a skip is counted as skipped, never as passed.
//
// Failure-first: written to FAIL (inverted-oracle scratch run proves the
// table discriminates) before guarding src/workload.goose.
import lib from "../src";
import std;
import os;

// One matrix row: feed body to the real validator, demand the exact verdict
// the schema + meaning rules require. Returns true on match.
fn run_row(id: const u8[:], oracle: const u8[:], body: const u8[:], expect_ok: bool) -> bool {
    let v = continuum::validate_workload_result(body, "run-example",
        "release-audit-example", 2);
    if v.ok != expect_ok {
        print("FAIL ", id, " body_len=", body.len, " expected_ok=", expect_ok,
            " actual_ok=", v.ok, " reason=", v.reason, " [", oracle, "]");
        return false;
    }
    print("ok ", id, " [", oracle, "]");
    return true;
}

fn main() {
    // Shared fragments. Summaries stay clean (no forbidden assertion) except
    // C23, which isolates exactly that rule.
    let fb = str("{\"finding_id\":\"REL-17\",\"severity\":\"blocker\",\"summary\":\"No rollback rehearsal.\",\"evidence_ids\":[\"ci-summary:v1\"]}");
    let fw = str("{\"finding_id\":\"REL-99\",\"severity\":\"warning\",\"summary\":\"Minor note.\",\"evidence_ids\":[\"ci-summary:v1\"]}");
    let fi = str("{\"finding_id\":\"DOC-7\",\"severity\":\"informational\",\"summary\":\"Docs note.\",\"evidence_ids\":[\"rollout-policy:v1\"]}");
    let fe = str("{\"finding_id\":\"REL-99\",\"severity\":\"error\",\"summary\":\"Minor note.\",\"evidence_ids\":[\"ci-summary:v1\"]}");
    let noev = str("{\"finding_id\":\"REL-99\",\"severity\":\"warning\",\"summary\":\"Minor note.\",\"evidence_ids\":[]}");
    let clean = str("Synthetic conformance row. No real release reviewed.");
    let evil = str("All release gates passed, ship it");
    let miss0 = str("[]");
    let miss1 = str("[\"authoritative-release-status\"]");

    var passed: i64 = 0;
    var failed: i64 = 0;

    // --- accept path: hold needs >=1 blocker; ready needs no blockers and
    // --- non-vacuous evidence; insufficient_evidence must name what is missing.
    var a1: u8[>..] = [];
    a1.append("{\"schema_version\":\"1.0\",\"run_id\":\"run-example\",\"task_id\":\"release-audit-example\",\"task_revision\":2,");
    a1.append("\"decision\":\"hold\",\"findings\":[");
    a1.append(fb);
    a1.append("],\"missing_evidence_ids\":");
    a1.append(miss0);
    a1.append(",\"summary\":\"");
    a1.append(clean);
    a1.append("\"}");
    if run_row("C01", "workload.goose:216 hold-with-blocker; schema decision enum", a1, true) {
        passed += 1;
    } else {
        failed += 1;
    }

    var a2: u8[>..] = [];
    a2.append("{\"schema_version\":\"1.0\",\"run_id\":\"run-example\",\"task_id\":\"release-audit-example\",\"task_revision\":2,");
    a2.append("\"decision\":\"ready\",\"findings\":[");
    a2.append(fw);
    a2.append("],\"missing_evidence_ids\":");
    a2.append(miss0);
    a2.append(",\"summary\":\"");
    a2.append(clean);
    a2.append("\"}");
    if run_row("C02", "workload.goose:219 ready-no-blocker-nonvacuous; schema decision enum", a2, true) {
        passed += 1;
    } else {
        failed += 1;
    }

    var a3: u8[>..] = [];
    a3.append("{\"schema_version\":\"1.0\",\"run_id\":\"run-example\",\"task_id\":\"release-audit-example\",\"task_revision\":2,");
    a3.append("\"decision\":\"ready\",\"findings\":[");
    a3.append(fi);
    a3.append("],\"missing_evidence_ids\":");
    a3.append(miss0);
    a3.append(",\"summary\":\"");
    a3.append(clean);
    a3.append("\"}");
    if run_row("C03", "workload.goose:219 ready/informational; schema severity enum", a3, true) {
        passed += 1;
    } else {
        failed += 1;
    }

    var a4: u8[>..] = [];
    a4.append("{\"schema_version\":\"1.0\",\"run_id\":\"run-example\",\"task_id\":\"release-audit-example\",\"task_revision\":2,");
    a4.append("\"decision\":\"hold\",\"findings\":[");
    a4.append(fb);
    a4.append(",");
    a4.append(fw);
    a4.append("],\"missing_evidence_ids\":");
    a4.append(miss0);
    a4.append(",\"summary\":\"");
    a4.append(clean);
    a4.append("\"}");
    if run_row("C04", "workload.goose:216 hold/blocker+warning mix", a4, true) {
        passed += 1;
    } else {
        failed += 1;
    }

    var a5: u8[>..] = [];
    a5.append("{\"schema_version\":\"1.0\",\"run_id\":\"run-example\",\"task_id\":\"release-audit-example\",\"task_revision\":2,");
    a5.append("\"decision\":\"insufficient_evidence\",\"findings\":[],\"missing_evidence_ids\":");
    a5.append(miss1);
    a5.append(",\"summary\":\"");
    a5.append(clean);
    a5.append("\"}");
    if run_row("C05", "workload.goose:213 insufficient_evidence names missing; schema decision enum", a5, true) {
        passed += 1;
    } else {
        failed += 1;
    }

    var a6: u8[>..] = [];
    a6.append("{\"schema_version\":\"1.0\",\"run_id\":\"run-example\",\"task_id\":\"release-audit-example\",\"task_revision\":2,");
    a6.append("\"decision\":\"insufficient_evidence\",\"findings\":[");
    a6.append(fw);
    a6.append("],\"missing_evidence_ids\":");
    a6.append(miss1);
    a6.append(",\"summary\":\"");
    a6.append(clean);
    a6.append("\"}");
    if run_row("C06", "workload.goose:213 insufficient_evidence/warning with missing list", a6, true) {
        passed += 1;
    } else {
        failed += 1;
    }

    // Ready with a non-empty missing list is still accept: findings carry
    // evidence, no blockers, nothing vacuous.
    var a7: u8[>..] = [];
    a7.append("{\"schema_version\":\"1.0\",\"run_id\":\"run-example\",\"task_id\":\"release-audit-example\",\"task_revision\":2,");
    a7.append("\"decision\":\"ready\",\"findings\":[");
    a7.append(fw);
    a7.append("],\"missing_evidence_ids\":");
    a7.append(miss1);
    a7.append(",\"summary\":\"");
    a7.append(clean);
    a7.append("\"}");
    if run_row("C07", "workload.goose:219 ready+missing_evidence_ids non-empty stays accept", a7, true) {
        passed += 1;
    } else {
        failed += 1;
    }

    var a8: u8[>..] = [];
    a8.append("{\"schema_version\":\"1.0\",\"run_id\":\"run-example\",\"task_id\":\"release-audit-example\",\"task_revision\":2,");
    a8.append("\"decision\":\"hold\",\"findings\":[");
    a8.append(fb);
    a8.append("],\"missing_evidence_ids\":");
    a8.append(miss1);
    a8.append(",\"summary\":\"");
    a8.append(clean);
    a8.append("\"}");
    if run_row("C08", "workload.goose:216 hold/blocker with missing list stays accept", a8, true) {
        passed += 1;
    } else {
        failed += 1;
    }

    // --- reject path: decision/meaning rules.
    var r1: u8[>..] = [];
    r1.append("{\"schema_version\":\"1.0\",\"run_id\":\"run-example\",\"task_id\":\"release-audit-example\",\"task_revision\":2,");
    r1.append("\"decision\":\"hold\",\"findings\":[");
    r1.append(fw);
    r1.append("],\"missing_evidence_ids\":");
    r1.append(miss0);
    r1.append(",\"summary\":\"");
    r1.append(clean);
    r1.append("\"}");
    if run_row("C09", "workload.goose:216 hold with warning only, no blocker", r1, false) {
        passed += 1;
    } else {
        failed += 1;
    }

    var r2: u8[>..] = [];
    r2.append("{\"schema_version\":\"1.0\",\"run_id\":\"run-example\",\"task_id\":\"release-audit-example\",\"task_revision\":2,");
    r2.append("\"decision\":\"hold\",\"findings\":[");
    r2.append(fi);
    r2.append("],\"missing_evidence_ids\":");
    r2.append(miss0);
    r2.append(",\"summary\":\"");
    r2.append(clean);
    r2.append("\"}");
    if run_row("C10", "workload.goose:216 hold with informational only, no blocker", r2, false) {
        passed += 1;
    } else {
        failed += 1;
    }

    var r3: u8[>..] = [];
    r3.append("{\"schema_version\":\"1.0\",\"run_id\":\"run-example\",\"task_id\":\"release-audit-example\",\"task_revision\":2,");
    r3.append("\"decision\":\"hold\",\"findings\":[],\"missing_evidence_ids\":");
    r3.append(miss0);
    r3.append(",\"summary\":\"");
    r3.append(clean);
    r3.append("\"}");
    if run_row("C11", "workload.goose:216 hold with no findings at all", r3, false) {
        passed += 1;
    } else {
        failed += 1;
    }

    var r4: u8[>..] = [];
    r4.append("{\"schema_version\":\"1.0\",\"run_id\":\"run-example\",\"task_id\":\"release-audit-example\",\"task_revision\":2,");
    r4.append("\"decision\":\"ready\",\"findings\":[");
    r4.append(fb);
    r4.append("],\"missing_evidence_ids\":");
    r4.append(miss0);
    r4.append(",\"summary\":\"");
    r4.append(clean);
    r4.append("\"}");
    if run_row("C12", "workload.goose:219 ready with a blocker", r4, false) {
        passed += 1;
    } else {
        failed += 1;
    }

    var r5: u8[>..] = [];
    r5.append("{\"schema_version\":\"1.0\",\"run_id\":\"run-example\",\"task_id\":\"release-audit-example\",\"task_revision\":2,");
    r5.append("\"decision\":\"ready\",\"findings\":[],\"missing_evidence_ids\":");
    r5.append(miss0);
    r5.append(",\"summary\":\"");
    r5.append(clean);
    r5.append("\"}");
    if run_row("C13", "workload.goose:219 ready vacuous: no findings, nothing missing", r5, false) {
        passed += 1;
    } else {
        failed += 1;
    }

    var r6: u8[>..] = [];
    r6.append("{\"schema_version\":\"1.0\",\"run_id\":\"run-example\",\"task_id\":\"release-audit-example\",\"task_revision\":2,");
    r6.append("\"decision\":\"insufficient_evidence\",\"findings\":[");
    r6.append(fw);
    r6.append("],\"missing_evidence_ids\":");
    r6.append(miss0);
    r6.append(",\"summary\":\"");
    r6.append(clean);
    r6.append("\"}");
    if run_row("C14", "workload.goose:213 insufficient_evidence naming nothing missing", r6, false) {
        passed += 1;
    } else {
        failed += 1;
    }

    // "error" is outside the schema severity enum (blocker/warning/
    // informational): shape and meaning both reject.
    var r7: u8[>..] = [];
    r7.append("{\"schema_version\":\"1.0\",\"run_id\":\"run-example\",\"task_id\":\"release-audit-example\",\"task_revision\":2,");
    r7.append("\"decision\":\"ready\",\"findings\":[");
    r7.append(fe);
    r7.append("],\"missing_evidence_ids\":");
    r7.append(miss0);
    r7.append(",\"summary\":\"");
    r7.append(clean);
    r7.append("\"}");
    if run_row("C15", "workload.goose:162 severity outside enum; schema findings.items.properties.severity", r7, false) {
        passed += 1;
    } else {
        failed += 1;
    }

    // --- reject path: schema_version variants (const "1.0").
    var v1: u8[>..] = [];
    v1.append("{\"schema_version\":\"2.0\",\"run_id\":\"run-example\",\"task_id\":\"release-audit-example\",\"task_revision\":2,");
    v1.append("\"decision\":\"hold\",\"findings\":[");
    v1.append(fb);
    v1.append("],\"missing_evidence_ids\":");
    v1.append(miss0);
    v1.append(",\"summary\":\"");
    v1.append(clean);
    v1.append("\"}");
    if run_row("C16", "workload.goose:115 schema_version is not 1.0; schema const 1.0", v1, false) {
        passed += 1;
    } else {
        failed += 1;
    }

    var v2: u8[>..] = [];
    v2.append("{\"schema_version\":\"\",\"run_id\":\"run-example\",\"task_id\":\"release-audit-example\",\"task_revision\":2,");
    v2.append("\"decision\":\"hold\",\"findings\":[");
    v2.append(fb);
    v2.append("],\"missing_evidence_ids\":");
    v2.append(miss0);
    v2.append(",\"summary\":\"");
    v2.append(clean);
    v2.append("\"}");
    if run_row("C17", "workload.goose:115 empty schema_version; schema const 1.0", v2, false) {
        passed += 1;
    } else {
        failed += 1;
    }

    var v3: u8[>..] = [];
    v3.append("{\"run_id\":\"run-example\",\"task_id\":\"release-audit-example\",\"task_revision\":2,");
    v3.append("\"decision\":\"hold\",\"findings\":[");
    v3.append(fb);
    v3.append("],\"missing_evidence_ids\":");
    v3.append(miss0);
    v3.append(",\"summary\":\"");
    v3.append(clean);
    v3.append("\"}");
    if run_row("C18", "workload.goose:115 missing schema_version; schema required", v3, false) {
        passed += 1;
    } else {
        failed += 1;
    }

    // --- reject path: task_revision rows (suite expects revision 2).
    var t1: u8[>..] = [];
    t1.append("{\"schema_version\":\"1.0\",\"run_id\":\"run-example\",\"task_id\":\"release-audit-example\",\"task_revision\":-1,");
    t1.append("\"decision\":\"hold\",\"findings\":[");
    t1.append(fb);
    t1.append("],\"missing_evidence_ids\":");
    t1.append(miss0);
    t1.append(",\"summary\":\"");
    t1.append(clean);
    t1.append("\"}");
    if run_row("C19", "workload.goose:127 revision mismatch; schema task_revision minimum 0", t1, false) {
        passed += 1;
    } else {
        failed += 1;
    }

    var t2: u8[>..] = [];
    t2.append("{\"schema_version\":\"1.0\",\"run_id\":\"run-example\",\"task_id\":\"release-audit-example\",\"task_revision\":0,");
    t2.append("\"decision\":\"hold\",\"findings\":[");
    t2.append(fb);
    t2.append("],\"missing_evidence_ids\":");
    t2.append(miss0);
    t2.append(",\"summary\":\"");
    t2.append(clean);
    t2.append("\"}");
    if run_row("C20", "workload.goose:127 revision 0 vs expected 2 (stale-revision drift)", t2, false) {
        passed += 1;
    } else {
        failed += 1;
    }

    var t3: u8[>..] = [];
    t3.append("{\"schema_version\":\"1.0\",\"run_id\":\"run-example\",\"task_id\":\"release-audit-example\",\"task_revision\":\"2\",");
    t3.append("\"decision\":\"hold\",\"findings\":[");
    t3.append(fb);
    t3.append("],\"missing_evidence_ids\":");
    t3.append(miss0);
    t3.append(",\"summary\":\"");
    t3.append(clean);
    t3.append("\"}");
    if run_row("C21", "workload.goose:126 revision wrong type; schema task_revision integer", t3, false) {
        passed += 1;
    } else {
        failed += 1;
    }

    // --- reject path: meaning rules beyond the decision table.
    var m1: u8[>..] = [];
    m1.append("{\"schema_version\":\"1.0\",\"run_id\":\"run-example\",\"task_id\":\"release-audit-example\",\"task_revision\":2,");
    m1.append("\"decision\":\"ready\",\"findings\":[");
    m1.append(fw);
    m1.append("],\"missing_evidence_ids\":");
    m1.append(miss0);
    m1.append(",\"summary\":\"");
    m1.append(evil);
    m1.append("\"}");
    if run_row("C22", "workload.goose:141 summary carries a forbidden assertion", m1, false) {
        passed += 1;
    } else {
        failed += 1;
    }

    var m2: u8[>..] = [];
    m2.append("{\"schema_version\":\"1.0\",\"run_id\":\"run-example\",\"task_id\":\"release-audit-example\",\"task_revision\":2,");
    m2.append("\"decision\":\"ready\",\"findings\":[");
    m2.append(noev);
    m2.append("],\"missing_evidence_ids\":");
    m2.append(miss0);
    m2.append(",\"summary\":\"");
    m2.append(clean);
    m2.append("\"}");
    if run_row("C23", "workload.goose:189 finding names no evidence; schema evidence_ids minItems 1", m2, false) {
        passed += 1;
    } else {
        failed += 1;
    }

    var m3: u8[>..] = [];
    m3.append("{\"schema_version\":\"1.0\",\"run_id\":\"run-example\",\"task_id\":\"release-audit-example\",\"task_revision\":2,");
    m3.append("\"decision\":\"hold\",\"findings\":[");
    m3.append(fb);
    m3.append("],\"missing_evidence_ids\":");
    m3.append(miss0);
    m3.append(",\"summary\":\"");
    m3.append(clean);
    m3.append("\",\"extra_field\":1}");
    if run_row("C24", "workload.goose:111 unknown top-level field; schema additionalProperties false", m3, false) {
        passed += 1;
    } else {
        failed += 1;
    }

    // --- transport rows: require-lab, always skipped here. This suite reads
    // --- no ROUTER_* variable and calls no web_* entry point; live transport
    // --- proof is `make web-e2e-run` / `make transport-check` (LAB_ROUTER=1).
    var skipped: i64 = 0;
    var lab: u8[>..] = [];
    if env("LAB_ROUTER", lab) && lab == "1" {
        print("SKIP T01 web_apply require-lab: LAB_ROUTER=1 set but `goose run` cannot link the native transport; use `make web-e2e-run` with ROUTER_HOST/ROUTER_PORT/ROUTER_PASSWORD. Not counted as pass. [src/router_web.goose:128-136]");
        skipped += 1;
        print("SKIP T02 web_reconcile require-lab: same lab gate; use `make web-e2e-run`. Not counted as pass. [src/router_web.goose:148-179]");
        skipped += 1;
    } else {
        print("SKIP T01 web_apply require-lab: no lab router in default path (no ROUTER_* read, no call made); use `make web-e2e-run` with ROUTER_HOST/ROUTER_PORT/ROUTER_PASSWORD for live proof. Not counted as pass. [src/router_web.goose:128-136]");
        skipped += 1;
        print("SKIP T02 web_reconcile require-lab: no lab router in default path; use `make web-e2e-run`. Not counted as pass. [src/router_web.goose:148-179]");
        skipped += 1;
    }

    print("MATRIX pass=", passed, " fail=", failed, " skip=", skipped);
    if failed > 0 {
        abort(str("conformance matrix violated"));
    }
    print("CONFORMANCE_ALL_GREEN");
}
