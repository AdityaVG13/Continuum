// Item 1: the JSON gate between a model (or test) and the guardian.
// Every tool call arrives as text shaped like schemas/meta-tools.json and
// leaves here as a typed struct or a rejection with a literal reason code.
// Mirrors the schema by hand, per tool, so each bound is reviewable next
// to the check that enforces it. Unknown tools, missing or mistyped args,
// out-of-range ints, over-long strings, ids outside the catalogue pattern,
// extra fields and non-JSON text all fail closed: no partial request ever
// reaches admission. Timestamps and run binding are the controller's job
// at dispatch; this module stamps neither.
import .contracts;
import json;
namespace continuum;

const MAX_ENVELOPE_BYTES: i64 = 8192;
const MAX_REVISIONS: i64 = 9007199254740991;
const MIN_APPLY_LEASE_MS: i64 = 1000;
const MAX_APPLY_LEASE_MS: i64 = 60000;
const MAX_OBSERVE_AGE_MS: i64 = 5000;
const MAX_RATIONALE_LEN: i64 = 512;

struct ValidCall {
    ok: bool = false,
    reason: u8[..256] = "",
    request: ActionRequest = ActionRequest {},
}

struct ReadCall {
    ok: bool = false,
    reason: u8[..256] = "",
    tool: ToolName = ToolName.ReadObservation,
    arg: u8[..64] = "",
}

struct ToolResultCheck {
    ok: bool = false,
    reason: u8[..256] = "",
}

// Catalogue ids: 1..64 bytes of letters, digits, underscore, dot, colon,
// hyphen. Empty is never an id.
fn valid_id(s: const u8[:], max_len: i64) -> bool {
    if s.len <= 0 || s.len > max_len {
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

fn valid_text(s: const u8[:], max_len: i64) -> bool {
    return s.len <= max_len;
}

// The envelope parse lives inline in each validator below: the JSON pool
// that owns the nodes must be a local of the function that walks them
// (§9.2 forbids returning nodes rooted in a helper's pool), and every
// rejection below carries a literal reason code, never the offending text.

// Every member key of args must be in the known list; anything else
// (including array elements, whose keys are empty) rejects the call.
fn no_unknown(args: json::Node?, known: const u8[:][:]) -> bool {
    if !args {
        return true;
    }
    var c = args.first;
    while c {
        var seen = false;
        for k in known {
            if c.key == k {
                seen = true;
                break;
            }
        }
        if !seen {
            return false;
        }
        c .= c.next;
    }
    return true;
}

fn get_id(args: json::Node?, key: const u8[:], max_len: i64) -> const u8[:], u8[..256], bool {
    let node = json::member(args, key);
    if !node {
        return "", "missing required id", false;
    }
    let s, is_str = json::as_string(node);
    if !is_str {
        return "", "id is not a string", false;
    }
    if !valid_id(s, max_len) {
        return "", "id outside catalogue pattern or length", false;
    }
    return s, "", true;
}

fn get_text(args: json::Node?, key: const u8[:], max_len: i64) -> const u8[:], u8[..256], bool {
    let node = json::member(args, key);
    if !node {
        return "", "missing required text", false;
    }
    let s, is_str = json::as_string(node);
    if !is_str {
        return "", "text is not a string", false;
    }
    if !valid_text(s, max_len) {
        return "", "text over length bound", false;
    }
    return s, "", true;
}

fn get_int(args: json::Node?, key: const u8[:], lo: i64, hi: i64) -> i64, u8[..256], bool {
    let node = json::member(args, key);
    if !node {
        return 0, "missing required integer", false;
    }
    let v, is_int = json::as_i64(node);
    if !is_int {
        return 0, "integer is not an integer", false;
    }
    if v < lo || v > hi {
        return 0, "integer outside permitted range", false;
    }
    return v, "", true;
}

fn tool_named(name: const u8[:]) -> ToolName, bool {
    if name == "read_observation" {
        return ToolName.ReadObservation, true;
    }
    if name == "read_task_context" {
        return ToolName.ReadTaskContext, true;
    }
    if name == "list_profiles" {
        return ToolName.ListProfiles, true;
    }
    if name == "apply_profile" {
        return ToolName.ApplyProfile, true;
    }
    if name == "read_action_result" {
        return ToolName.ReadActionResult, true;
    }
    if name == "restore_profile" {
        return ToolName.RestoreProfile, true;
    }
    return ToolName.ReadObservation, false;
}

fn bad(reason: const u8[:]) -> ValidCall {
    return ValidCall { ok: false, reason: reason };
}

fn bad_read(reason: const u8[:]) -> ReadCall {
    return ReadCall { ok: false, reason: reason };
}

// apply_profile, exactly the ten fields schemas/meta-tools.json requires.
fn validate_apply_call(text: const u8[:]) -> ValidCall {
    if text.len <= 0 || text.len > MAX_ENVELOPE_BYTES {
        return bad("envelope size outside 1..8192");
    }
    var doc: json::Node[>..] = [];
    var decoded: u8[>..] = [];
    let root, err = json::parse(text, doc, decoded);
    if !root {
        return bad("envelope is not JSON");
    }
    let tool, has_tool = json::as_string(json::member(root, "tool"));
    if !has_tool || tool.len <= 0 {
        return bad("envelope has no string tool");
    }
    let args = json::member(root, "arguments");
    if !args {
        return bad("envelope has no arguments object");
    }
    if tool != "apply_profile" {
        return bad("not an apply_profile call");
    }
    // Single-pass args dispatch (H2): one walk over the args list captures
    // all ten fields and rejects unknown keys (empty keys, e.g. array
    // elements, match nothing and reject, exactly like no_unknown). The
    // per-field checks below run in the original order with the original
    // literals, so reason codes are byte-identical. First occurrence wins,
    // matching json::member's first-match semantics on duplicate keys.
    // Oversized values are never copied into the fixed holders; the
    // validity checks below still see them as out-of-bound, same reason.
    var req = ActionRequest {};
    var has_request_id = false;
    var request_id_is_str = false;
    var has_scope_id = false;
    var scope_id_is_str = false;
    var has_path_id = false;
    var path_id_is_str = false;
    var has_profile_id = false;
    var profile_id_is_str = false;
    var has_observation_id = false;
    var observation_id_is_str = false;
    var has_task_revision = false;
    var task_revision_is_int = false;
    var has_route_epoch = false;
    var route_epoch_is_int = false;
    var has_config_revision = false;
    var config_revision_is_int = false;
    var has_lease_ms = false;
    var lease_ms_is_int = false;
    var has_rationale = false;
    var rationale_is_str = false;
    var rationale_len: i64 = 0;
    var c = args.first;
    while c {
        if c.key == "request_id" {
            if !has_request_id {
                has_request_id = true;
                let s, is_str = json::as_string(c);
                request_id_is_str = is_str;
                if is_str && s.len <= 64 {
                    req.request_id = s;
                }
            }
        } else if c.key == "scope_id" {
            if !has_scope_id {
                has_scope_id = true;
                let s, is_str = json::as_string(c);
                scope_id_is_str = is_str;
                if is_str && s.len <= 64 {
                    req.scope_id = s;
                }
            }
        } else if c.key == "path_id" {
            if !has_path_id {
                has_path_id = true;
                let s, is_str = json::as_string(c);
                path_id_is_str = is_str;
                if is_str && s.len <= 64 {
                    req.path_id = s;
                }
            }
        } else if c.key == "profile_id" {
            if !has_profile_id {
                has_profile_id = true;
                let s, is_str = json::as_string(c);
                profile_id_is_str = is_str;
                if is_str && s.len <= 64 {
                    req.profile_id = s;
                }
            }
        } else if c.key == "observation_id" {
            if !has_observation_id {
                has_observation_id = true;
                let s, is_str = json::as_string(c);
                observation_id_is_str = is_str;
                if is_str && s.len <= 64 {
                    req.observation_id = s;
                }
            }
        } else if c.key == "task_revision" {
            if !has_task_revision {
                has_task_revision = true;
                let v, is_int = json::as_i64(c);
                task_revision_is_int = is_int;
                if is_int {
                    req.task_revision = v;
                }
            }
        } else if c.key == "route_epoch" {
            if !has_route_epoch {
                has_route_epoch = true;
                let v, is_int = json::as_i64(c);
                route_epoch_is_int = is_int;
                if is_int {
                    req.route_epoch = v;
                }
            }
        } else if c.key == "config_revision" {
            if !has_config_revision {
                has_config_revision = true;
                let v, is_int = json::as_i64(c);
                config_revision_is_int = is_int;
                if is_int {
                    req.config_revision = v;
                }
            }
        } else if c.key == "lease_ms" {
            if !has_lease_ms {
                has_lease_ms = true;
                let v, is_int = json::as_i64(c);
                lease_ms_is_int = is_int;
                if is_int {
                    req.lease_ms = v;
                }
            }
        } else if c.key == "rationale" {
            if !has_rationale {
                has_rationale = true;
                let s, is_str = json::as_string(c);
                rationale_is_str = is_str;
                if is_str {
                    rationale_len = s.len;
                    if s.len <= 1024 {
                        req.rationale = s;
                    }
                }
            }
        } else {
            return bad("unknown argument present");
        }
        c .= c.next;
    }
    if !has_request_id {
        return bad("missing required id");
    }
    if !request_id_is_str {
        return bad("id is not a string");
    }
    if !valid_id(req.request_id, 64) {
        return bad("id outside catalogue pattern or length");
    }
    if !has_scope_id {
        return bad("missing required id");
    }
    if !scope_id_is_str {
        return bad("id is not a string");
    }
    if !valid_id(req.scope_id, 64) {
        return bad("id outside catalogue pattern or length");
    }
    if !has_path_id {
        return bad("missing required id");
    }
    if !path_id_is_str {
        return bad("id is not a string");
    }
    if !valid_id(req.path_id, 64) {
        return bad("id outside catalogue pattern or length");
    }
    if !has_profile_id {
        return bad("missing required id");
    }
    if !profile_id_is_str {
        return bad("id is not a string");
    }
    if !valid_id(req.profile_id, 64) {
        return bad("id outside catalogue pattern or length");
    }
    if !has_observation_id {
        return bad("missing required id");
    }
    if !observation_id_is_str {
        return bad("id is not a string");
    }
    if !valid_id(req.observation_id, 64) {
        return bad("id outside catalogue pattern or length");
    }
    if !has_task_revision {
        return bad("missing required integer");
    }
    if !task_revision_is_int {
        return bad("integer is not an integer");
    }
    if req.task_revision < 0 || req.task_revision > MAX_REVISIONS {
        return bad("integer outside permitted range");
    }
    if !has_route_epoch {
        return bad("missing required integer");
    }
    if !route_epoch_is_int {
        return bad("integer is not an integer");
    }
    if req.route_epoch < 0 || req.route_epoch > MAX_REVISIONS {
        return bad("integer outside permitted range");
    }
    if !has_config_revision {
        return bad("missing required integer");
    }
    if !config_revision_is_int {
        return bad("integer is not an integer");
    }
    if req.config_revision < 0 || req.config_revision > MAX_REVISIONS {
        return bad("integer outside permitted range");
    }
    if !has_lease_ms {
        return bad("missing required integer");
    }
    if !lease_ms_is_int {
        return bad("integer is not an integer");
    }
    if req.lease_ms < MIN_APPLY_LEASE_MS || req.lease_ms > MAX_APPLY_LEASE_MS {
        return bad("integer outside permitted range");
    }
    if !has_rationale {
        return bad("missing required text");
    }
    if !rationale_is_str {
        return bad("text is not a string");
    }
    if rationale_len > MAX_RATIONALE_LEN || !valid_text(req.rationale, MAX_RATIONALE_LEN) {
        return bad("text over length bound");
    }
    return ValidCall {
        ok: true,
        request: ActionRequest {
            request_id: req.request_id,
            kind: ActionKind.ApplyProfile,
            profile_id: req.profile_id,
            scope_id: req.scope_id,
            path_id: req.path_id,
            observation_id: req.observation_id,
            task_revision: req.task_revision,
            config_revision: req.config_revision,
            route_epoch: req.route_epoch,
            lease_ms: req.lease_ms,
            lease_id: req.request_id,
            rationale: req.rationale,
        },
    };
}

// restore_profile: six fields; the lease, not a profile, is named.
fn validate_restore_call(text: const u8[:]) -> ValidCall {
    if text.len <= 0 || text.len > MAX_ENVELOPE_BYTES {
        return bad("envelope size outside 1..8192");
    }
    var doc: json::Node[>..] = [];
    var decoded: u8[>..] = [];
    let root, err = json::parse(text, doc, decoded);
    if !root {
        return bad("envelope is not JSON");
    }
    let tool, has_tool = json::as_string(json::member(root, "tool"));
    if !has_tool || tool.len <= 0 {
        return bad("envelope has no string tool");
    }
    let args = json::member(root, "arguments");
    if !args {
        return bad("envelope has no arguments object");
    }
    if tool != "restore_profile" {
        return bad("not a restore_profile call");
    }
    // Single-pass args dispatch (H5): one walk over the args list captures
    // all six fields and rejects unknown keys (empty keys, e.g. array
    // elements, match nothing and reject, exactly like no_unknown). The
    // per-field checks below run in the original order with the original
    // literals, so reason codes are byte-identical. First occurrence wins,
    // matching json::member's first-match semantics on duplicate keys.
    // Oversized values are never copied into the fixed holders; the
    // validity checks below still see them as out-of-bound, same reason.
    var req = ActionRequest {};
    var has_request_id = false;
    var request_id_is_str = false;
    var has_scope_id = false;
    var scope_id_is_str = false;
    var has_lease_id = false;
    var lease_id_is_str = false;
    var has_expected_revision = false;
    var expected_revision_is_int = false;
    var has_observation_id = false;
    var observation_id_is_str = false;
    var has_rationale = false;
    var rationale_is_str = false;
    var rationale_len: i64 = 0;
    var c = args.first;
    while c {
        if c.key == "request_id" {
            if !has_request_id {
                has_request_id = true;
                let s, is_str = json::as_string(c);
                request_id_is_str = is_str;
                if is_str && s.len <= 64 {
                    req.request_id = s;
                }
            }
        } else if c.key == "scope_id" {
            if !has_scope_id {
                has_scope_id = true;
                let s, is_str = json::as_string(c);
                scope_id_is_str = is_str;
                if is_str && s.len <= 64 {
                    req.scope_id = s;
                }
            }
        } else if c.key == "lease_id" {
            if !has_lease_id {
                has_lease_id = true;
                let s, is_str = json::as_string(c);
                lease_id_is_str = is_str;
                if is_str && s.len <= 64 {
                    req.lease_id = s;
                }
            }
        } else if c.key == "expected_revision" {
            if !has_expected_revision {
                has_expected_revision = true;
                let v, is_int = json::as_i64(c);
                expected_revision_is_int = is_int;
                if is_int {
                    req.expected_revision = v;
                }
            }
        } else if c.key == "observation_id" {
            if !has_observation_id {
                has_observation_id = true;
                let s, is_str = json::as_string(c);
                observation_id_is_str = is_str;
                if is_str && s.len <= 64 {
                    req.observation_id = s;
                }
            }
        } else if c.key == "rationale" {
            if !has_rationale {
                has_rationale = true;
                let s, is_str = json::as_string(c);
                rationale_is_str = is_str;
                if is_str {
                    rationale_len = s.len;
                    if s.len <= 1024 {
                        req.rationale = s;
                    }
                }
            }
        } else {
            return bad("unknown argument present");
        }
        c .= c.next;
    }
    if !has_request_id {
        return bad("missing required id");
    }
    if !request_id_is_str {
        return bad("id is not a string");
    }
    if !valid_id(req.request_id, 64) {
        return bad("id outside catalogue pattern or length");
    }
    if !has_scope_id {
        return bad("missing required id");
    }
    if !scope_id_is_str {
        return bad("id is not a string");
    }
    if !valid_id(req.scope_id, 64) {
        return bad("id outside catalogue pattern or length");
    }
    if !has_lease_id {
        return bad("missing required id");
    }
    if !lease_id_is_str {
        return bad("id is not a string");
    }
    if !valid_id(req.lease_id, 64) {
        return bad("id outside catalogue pattern or length");
    }
    if !has_expected_revision {
        return bad("missing required integer");
    }
    if !expected_revision_is_int {
        return bad("integer is not an integer");
    }
    if req.expected_revision < 0 || req.expected_revision > MAX_REVISIONS {
        return bad("integer outside permitted range");
    }
    if !has_observation_id {
        return bad("missing required id");
    }
    if !observation_id_is_str {
        return bad("id is not a string");
    }
    if !valid_id(req.observation_id, 64) {
        return bad("id outside catalogue pattern or length");
    }
    if !has_rationale {
        return bad("missing required text");
    }
    if !rationale_is_str {
        return bad("text is not a string");
    }
    if rationale_len > MAX_RATIONALE_LEN || !valid_text(req.rationale, MAX_RATIONALE_LEN) {
        return bad("text over length bound");
    }
    return ValidCall {
        ok: true,
        request: ActionRequest {
            request_id: req.request_id,
            kind: ActionKind.RestoreProfile,
            scope_id: req.scope_id,
            observation_id: req.observation_id,
            expected_revision: req.expected_revision,
            lease_id: req.lease_id,
            rationale: req.rationale,
        },
    };
}

// The four read-only tools: one id argument each, no mutation possible.
fn validate_read_call(text: const u8[:], expected: ToolName) -> ReadCall {
    if text.len <= 0 || text.len > MAX_ENVELOPE_BYTES {
        return bad_read("envelope size outside 1..8192");
    }
    var doc: json::Node[>..] = [];
    var decoded: u8[>..] = [];
    let root, err = json::parse(text, doc, decoded);
    if !root {
        return bad_read("envelope is not JSON");
    }
    let tool, has_tool = json::as_string(json::member(root, "tool"));
    if !has_tool || tool.len <= 0 {
        return bad_read("envelope has no string tool");
    }
    let args = json::member(root, "arguments");
    if !args {
        return bad_read("envelope has no arguments object");
    }
    let named, known_tool = tool_named(tool);
    if !known_tool || named != expected {
        return bad_read("tool does not match the expected read");
    }
    if expected == ToolName.ReadObservation {
        let known: const u8[:][2] = ["path_id", "max_age_ms"];
        if !no_unknown(args, known) {
            return bad_read("unknown argument present");
        }
        let path_id, r1, ok1 = get_id(args, "path_id", 64);
        if !ok1 {
            return bad_read(r1);
        }
        let max_age, r2, ok2 = get_int(args, "max_age_ms", 0, MAX_OBSERVE_AGE_MS);
        if !ok2 {
            return bad_read(r2);
        }
        return ReadCall { ok: true, tool: expected, arg: path_id };
    }
    if expected == ToolName.ReadTaskContext {
        let known: const u8[:][1] = ["run_id"];
        if !no_unknown(args, known) {
            return bad_read("unknown argument present");
        }
        let run_id, r1, ok1 = get_id(args, "run_id", 64);
        if !ok1 {
            return bad_read(r1);
        }
        return ReadCall { ok: true, tool: expected, arg: run_id };
    }
    if expected == ToolName.ListProfiles {
        let known: const u8[:][1] = ["scope_id"];
        if !no_unknown(args, known) {
            return bad_read("unknown argument present");
        }
        let scope_id, r1, ok1 = get_id(args, "scope_id", 64);
        if !ok1 {
            return bad_read(r1);
        }
        return ReadCall { ok: true, tool: expected, arg: scope_id };
    }
    let known: const u8[:][1] = ["action_id"];
    if !no_unknown(args, known) {
        return bad_read("unknown argument present");
    }
    let action_id, r1, ok1 = get_id(args, "action_id", 64);
    if !ok1 {
        return bad_read(r1);
    }
    return ReadCall { ok: true, tool: expected, arg: action_id };
}

// A tool result answers exactly one call: both ids must echo the call the
// controller issued. Anything else is a substitution, rejected here.
fn validate_tool_result(text: const u8[:], expected_call_id: const u8[:],
        expected_request_id: const u8[:]) -> ToolResultCheck {
    if text.len <= 0 || text.len > MAX_ENVELOPE_BYTES {
        return ToolResultCheck { ok: false, reason: "result size outside 1..8192" };
    }
    var doc: json::Node[>..] = [];
    var decoded: u8[>..] = [];
    let root, err = json::parse(text, doc, decoded);
    if !root {
        return ToolResultCheck { ok: false, reason: "result is not JSON" };
    }
    let call_id, has_call = json::as_string(json::member(root, "call_id"));
    let request_id, has_req = json::as_string(json::member(root, "request_id"));
    if !has_call || !has_req {
        return ToolResultCheck { ok: false, reason: "result lacks call binding" };
    }
    if call_id != expected_call_id {
        return ToolResultCheck { ok: false, reason: "call id does not match" };
    }
    if request_id != expected_request_id {
        return ToolResultCheck { ok: false, reason: "request id does not match" };
    }
    return ToolResultCheck { ok: true };
}
