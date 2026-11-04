// Item 2: the workload-result validator. A model (or test) hands back a
// verdict shaped like schemas/workload-result.schema.json; this module
// checks the shape AND the meaning against named fixtures: exact run, task
// and revision identity, a decision drawn from the three legal verdicts,
// required findings with blocker severity and evidence behind them, and a
// summary free of the forbidden assertions in fixtures/corpus. Content-hash
// pinning of the corpus documents stays a build ticket: Goose has no sha
// primitive, so evidence binding here is id-pattern plus manifest listing,
// done by evidence_doc_listed against the manifest text the caller read.
// A ready verdict with no findings and no missing evidence is vacuous and
// rejected; insufficient_evidence must name what is missing; hold needs at
// least one blocker.
import .contracts;
import .tooljson;
import json;
namespace continuum;

const MAX_FINDINGS: i64 = 16;
const MAX_EVIDENCE_IDS: i64 = 16;
const MAX_SUMMARY_LEN: i64 = 2048;

struct WorkloadVerdict {
    ok: bool = false,
    reason: u8[..256] = "",
    decision: u8[..32] = "",
    blockers: i64 = 0,
}

fn bad_verdict(reason: const u8[:]) -> WorkloadVerdict {
    return WorkloadVerdict { ok: false, reason: reason };
}

fn json_array(node: json::Node?) -> bool {
    if !node { return false; }
    match node.val {
        Arr => { return true; },
        _ => { return false; },
    }
}

fn json_string_list_has(node: json::Node?, value: const u8[:]) -> bool {
    if !node || !json_array(node) { return false; }
    var item = node.first;
    while item {
        let text, ok = json::as_string(item);
        if ok && text == value { return true; }
        item .= item.next;
    }
    return false;
}

fn has_sub(text: const u8[:], sub: const u8[:]) -> bool {
    if sub.len <= 0 || sub.len > text.len {
        return false;
    }
    for i in 0..text.len - sub.len + 1 {
        var hit = true;
        for j in 0..sub.len {
            if text[i + j] != sub[j] {
                hit = false;
                break;
            }
        }
        if hit {
            return true;
        }
    }
    return false;
}

// One of the four assertions fixtures/corpus forbids: a summary that
// claims a gate passed, a finding closed, or ownership missing.
fn summary_clean(summary: const u8[:]) -> bool {
    if has_sub(summary, "All release gates passed") {
        return false;
    }
    if has_sub(summary, "REL-17 is closed") {
        return false;
    }
    if has_sub(summary, "SEC-42 is fixed or waived") {
        return false;
    }
    if has_sub(summary, "Support ownership is missing") {
        return false;
    }
    return true;
}

// Borrow the current validation's manifest DOM. All citations share one
// parse, without retaining evidence across calls or weakening source checks.
fn evidence_doc_listed(root: json::Node?, evidence_id: const u8[:]) -> bool {
    if !root { return false; }
    let docs = json::member(root, "documents");
    if !docs {
        return false;
    }
    var c = docs.first;
    while c {
        let id, has_id = json::as_string(json::member(c, "evidence_id"));
        if has_id && id == evidence_id {
            return true;
        }
        c .= c.next;
    }
    return false;
}

fn validate_workload_result(text: const u8[:], run_id: const u8[:],
        task_id: const u8[:], revision: i64) -> WorkloadVerdict {
    if text.len <= 0 || text.len > 32768 {
        return bad_verdict("result size outside 1..32768");
    }
    var doc: json::Node[>..] = [];
    var decoded: u8[>..] = [];
    let root, err = json::parse(text, doc, decoded);
    if !root {
        return bad_verdict("result is not JSON");
    }
    let known: const u8[:][8] = ["schema_version", "run_id", "task_id",
        "task_revision", "decision", "findings", "missing_evidence_ids",
        "summary"];
    if !no_unknown(root, known) {
        return bad_verdict("unknown top-level field present");
    }
    let version, has_v = json::as_string(json::member(root, "schema_version"));
    if !has_v || version != "1.0" {
        return bad_verdict("schema_version is not 1.0");
    }
    let got_run, has_run = json::as_string(json::member(root, "run_id"));
    if !has_run || got_run != run_id {
        return bad_verdict("run id does not match");
    }
    let got_task, has_task = json::as_string(json::member(root, "task_id"));
    if !has_task || got_task != task_id {
        return bad_verdict("task id does not match");
    }
    let got_rev, has_rev = json::as_i64(json::member(root, "task_revision"));
    if !has_rev || got_rev != revision {
        return bad_verdict("task revision does not match");
    }
    let decision, has_d = json::as_string(json::member(root, "decision"));
    if !has_d {
        return bad_verdict("decision is not a string");
    }
    if decision != "ready" && decision != "hold" && decision != "insufficient_evidence" {
        return bad_verdict("decision outside ready/hold/insufficient_evidence");
    }
    let summary, has_s = json::as_string(json::member(root, "summary"));
    if !has_s || summary.len > MAX_SUMMARY_LEN {
        return bad_verdict("summary missing or over length bound");
    }
    if !summary_clean(summary) {
        return bad_verdict("summary carries a forbidden assertion");
    }
    // Findings: each fully shaped, severities counted, evidence ids sane.
    let findings = json::member(root, "findings");
    if !findings || !json_array(findings) {
        return bad_verdict("findings must be an array");
    }
    var seen_count: i64 = 0;
    var blockers: i64 = 0;
    var c = findings.first;
    while c {
        seen_count += 1;
        if seen_count > MAX_FINDINGS {
            return bad_verdict("findings over 16 items");
        }
        let fid, has_fid = json::as_string(json::member(c, "finding_id"));
        if !has_fid || !valid_id(fid, 64) {
            return bad_verdict("finding id invalid");
        }
        let sev, has_sev = json::as_string(json::member(c, "severity"));
        if !has_sev || (sev != "blocker" && sev != "warning" && sev != "informational") {
            return bad_verdict("finding severity outside enum");
        }
        if sev == "blocker" {
            blockers += 1;
        }
        let fsum, has_fsum = json::as_string(json::member(c, "summary"));
        if !has_fsum || fsum.len > 512 {
            return bad_verdict("finding summary missing or over 512");
        }
        let ev = json::member(c, "evidence_ids");
        if !ev || !json_array(ev) {
            return bad_verdict("finding evidence ids must be an array");
        }
        var ev_count: i64 = 0;
        var e = ev.first;
        while e {
            ev_count += 1;
            if ev_count > 8 {
                return bad_verdict("finding evidence over 8 ids");
            }
            let eid, has_eid = json::as_string(e);
            if !has_eid || !valid_id(eid, 64) {
                return bad_verdict("finding evidence id invalid");
            }
            e .= e.next;
        }
        if ev_count <= 0 {
            return bad_verdict("finding names no evidence");
        }
        c .= c.next;
    }
    // Missing evidence: list shape only; non-empty is enforced per decision.
    let missing = json::member(root, "missing_evidence_ids");
    if !missing || !json_array(missing) {
        return bad_verdict("missing_evidence_ids must be an array");
    }
    var missing_count: i64 = 0;
    var m = missing.first;
    while m {
        missing_count += 1;
        if missing_count > MAX_EVIDENCE_IDS {
            return bad_verdict("missing evidence over 16 ids");
        }
        let mid, has_mid = json::as_string(m);
        if !has_mid || !valid_id(mid, 64) {
            return bad_verdict("missing evidence id invalid");
        }
        m .= m.next;
    }
    // Decision rules: the verdict must mean what it says.
    if decision == "insufficient_evidence" && missing_count <= 0 {
        return bad_verdict("insufficient_evidence names nothing missing");
    }
    if decision == "hold" && blockers <= 0 {
        return bad_verdict("hold with no blocker");
    }
    if decision == "ready" && (blockers > 0 || (seen_count <= 0 && missing_count <= 0)) {
        return bad_verdict("ready with blockers or vacuous");
    }
    return WorkloadVerdict { ok: true, decision: decision, blockers: blockers };
}

// Corpus-specific independent checks. The expected finding ids, severities
// and required source bindings are validator input, never part of the model
// prompt. Free-form prose is not a generally machine-proven semantic claim.
fn validate_audit_findings(text: const u8[:], manifest: const u8[:], requirements: const u8[:]) -> WorkloadVerdict {
    var doc: json::Node[>..] = [];
    var decoded: u8[>..] = [];
    let root, err = json::parse(text, doc, decoded);
    var rules_doc: json::Node[>..] = [];
    var rules_dec: u8[>..] = [];
    let rules, rules_err = json::parse(requirements, rules_doc, rules_dec);
    if !root || !rules { return bad_verdict("audit result or validation facts unavailable"); }
    let decision, has_decision = json::as_string(json::member(root, "decision"));
    let expected, has_expected = json::as_string(json::member(rules, "expected_decision"));
    if !has_decision || !has_expected || decision != expected {
        return bad_verdict("audit decision does not match supplied evidence");
    }
    let findings = json::member(root, "findings");
    let required = json::member(rules, "required_findings");
    if !findings || !required || !json_array(findings) || !json_array(required) || !required.first {
        return bad_verdict("audit findings or required facts unavailable");
    }
    var manifest_doc: json::Node[>..] = [];
    var manifest_dec: u8[>..] = [];
    let bounded_manifest = if manifest.len > 0 && manifest.len <= 8192 { manifest } else { "" };
    let manifest_root, manifest_err = json::parse(bounded_manifest, manifest_doc, manifest_dec);
    var finding = findings.first;
    while finding {
        let known: const u8[:][4] = ["finding_id", "severity", "summary", "evidence_ids"];
        if !no_unknown(finding, known) { return bad_verdict("unknown finding field"); }
        let evidence = json::member(finding, "evidence_ids");
        if !evidence || !json_array(evidence) { return bad_verdict("finding evidence must be an array"); }
        var citation = evidence.first;
        while citation {
            let id, ok = json::as_string(citation);
            if !ok || !evidence_doc_listed(manifest_root, id) {
                return bad_verdict("finding cites evidence not supplied to the task");
            }
            citation .= citation.next;
        }
        finding .= finding.next;
    }
    var needed = required.first;
    while needed {
        let id, has_id = json::as_string(json::member(needed, "finding_id"));
        let severity, has_severity = json::as_string(json::member(needed, "severity"));
        let sources = json::member(needed, "required_evidence_ids");
        if !has_id || !has_severity || !sources || !json_array(sources) { return bad_verdict("required audit fact malformed"); }
        var matches: i64 = 0;
        finding .= findings.first;
        while finding {
            let actual, has_actual = json::as_string(json::member(finding, "finding_id"));
            if has_actual && actual == id {
                matches += 1;
                let got_severity, has_got = json::as_string(json::member(finding, "severity"));
                if !has_got || got_severity != severity { return bad_verdict("required finding severity changed"); }
                let evidence = json::member(finding, "evidence_ids");
                var source = sources.first;
                while source {
                    let source_id, has_source = json::as_string(source);
                    if !has_source || !json_string_list_has(evidence, source_id) {
                        return bad_verdict("required finding lacks its supporting source binding");
                    }
                    source .= source.next;
                }
            }
            finding .= finding.next;
        }
        if matches != 1 { return bad_verdict("required audit finding missing or duplicated"); }
        needed .= needed.next;
    }
    return WorkloadVerdict { ok: true, decision: decision };
}
