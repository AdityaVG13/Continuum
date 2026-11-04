// Owner-authored authority is separate from model knowledge. Every effect
// rechecks this private record under the device binding lock. Constraints
// narrow a grant; neither model text nor a generated program can widen it.
import .meta_provider;
import json;
namespace continuum;

extern fn ct_setup_owner_load(out: u8[:], length: i64&) -> i32;
extern fn ct_setup_owner_store(data: const u8[:]) -> i32;

struct OwnerPolicy {
    allowed_operations: u8[..16][..8] = ["enroll", "runtime", "apply", "restore", "verify"],
    execution_host: u8[..16] = "local",
    allow_host_programs: bool = false,
    protected_clients: u8[..64][..16] = [],
    protected_services: u8[..64][..5] = [],
    max_programs: i64 = 8,
    program_retention_days: i64 = 7,
    program_timeout_ms: i64 = 2000,
}
fn owner_strings(root: json::Node?, key: const u8[:], out: u8[..64][..16]&, limit: i64) -> bool {
    let entries = json::member(root, key);
    if !entries { return false; }
    match entries.val { Arr a => { if a.count > limit { return false; } }, _ => { return false; }, }
    var node = entries.first;
    while node {
        let value, valid = json::as_string(node);
        if !valid || value.len == 0 || value.len > 64 || out.len >= limit { return false; }
        for old in out { if old == value { return false; } }
        out.push(value); node .= node.next;
    }
    return true;
}
fn owner_parse(text: const u8[:], policy: OwnerPolicy&) -> bool {
    if text.len == 0 || text.len > 8192 { return false; }
    var doc: json::Node[>..] = []; var decoded: u8[>..] = [];
    let root, err = json::parse(text, doc, decoded);
    let keys: const u8[:][..9] = ["schema_version", "allowed_operations", "execution_host", "allow_host_programs",
        "protected_clients", "protected_services", "max_programs", "program_retention_days", "program_timeout_ms"];
    if !root || !no_unknown(root, keys) { return false; }
    match root.val { Obj o => { if o.count != keys.len { return false; } }, _ => { return false; }, }
    let version, v = json::as_i64(json::member(root, "schema_version"));
    let host, h = json::as_string(json::member(root, "execution_host"));
    let programs, p = json::as_bool(json::member(root, "allow_host_programs"));
    let count, c = json::as_i64(json::member(root, "max_programs"));
    let days, d = json::as_i64(json::member(root, "program_retention_days"));
    let timeout, t = json::as_i64(json::member(root, "program_timeout_ms"));
    if !v || version != 1 || !h || (host != "local" && host != "disabled") || !p || !c || !d || !t ||
            count < 1 || count > 8 || days < 0 || days > 365 || timeout < 100 || timeout > 10000 { return false; }
    var operations: u8[..64][..16] = []; var clients: u8[..64][..16] = []; var services: u8[..64][..16] = [];
    if !owner_strings(root, "allowed_operations", operations, 8) ||
            !owner_strings(root, "protected_clients", clients, 16) || !owner_strings(root, "protected_services", services, 5) { return false; }
    var candidate = OwnerPolicy { allowed_operations: [], execution_host: host, allow_host_programs: programs,
        max_programs: count, program_retention_days: days, program_timeout_ms: timeout };
    for op in operations {
        if op != "enroll" && op != "runtime" && op != "apply" && op != "restore" && op != "verify" && op != "reboot" { return false; }
        candidate.allowed_operations.push(op);
    }
    for name in services {
        // Capability ids are device vocabulary, so a policy may protect any id
        // the device reports. It cannot protect an empty or oversized token.
        if name.len == 0 || name.len > 64 { return false; }
        candidate.protected_services.push(name);
    }
    candidate.protected_clients = clients; policy = candidate; return true;
}
fn owner_record(policy: OwnerPolicy) -> u8[>..] {
    var out: u8[>..] = []; out.append("{\"schema_version\":1,\"allowed_operations\":[");
    for op, index in policy.allowed_operations {
        if index > 0 { out.append(","); } json::format_string(out, op);
    }
    out.append("],\"execution_host\":"); json::format_string(out, policy.execution_host);
    out.append(",\"allow_host_programs\":"); json::format_bool(out, policy.allow_host_programs);
    out.append(",\"protected_clients\":[");
    for client, index in policy.protected_clients {
        if index > 0 { out.append(","); } json::format_string(out, client);
    }
    out.append("],\"protected_services\":[");
    for service, index in policy.protected_services {
        if index > 0 { out.append(","); } json::format_string(out, service);
    }
    out.append("],\"max_programs\":"); json::format_int(out, policy.max_programs);
    out.append(",\"program_retention_days\":"); json::format_int(out, policy.program_retention_days);
    out.append(",\"program_timeout_ms\":"); json::format_int(out, policy.program_timeout_ms); out.append("}"); return out;
}
fn owner_load(policy: OwnerPolicy&) -> bool {
    var buffer: u8[..8192] = [0; 8192]; var n: i64 = 0;
    if ct_setup_owner_load(buffer, n) != 0 || n < 0 || n > buffer.len { return false; }
    if n == 0 { policy = OwnerPolicy {}; return true; }
    return owner_parse(buffer[..n], policy);
}
fn owner_save(policy: OwnerPolicy) -> bool { return ct_setup_owner_store(owner_record(policy)) == 0; }
fn owner_admit(operation: const u8[:], features: i64 = 0, direct_approval: bool = false) -> const u8[:] {
    var policy = OwnerPolicy {};
    if !owner_load(policy) { return "invalid_owner_policy"; }
    // The current adapter cannot establish per-client continuity across these
    // changes. Refuse, rather than promise that a named user remains connected.
    if policy.protected_clients.len > 0 && operation != "inspect" && operation != "remember" {
        return "protected_connectivity_unverified";
    }
    var allowed = direct_approval;
    for op in policy.allowed_operations { if op == operation { allowed = true; } }
    if !allowed { return if operation == "reboot" { "owner_reboot_approval_required" } else { "owner_policy_denied" }; }
    return "";
}
// Owner-protected capabilities are refused before any device I/O. The check is
// by capability id, which the device reports; core knows no vendor key.
fn owner_protects(id: const u8[:]) -> const u8[:] {
    var policy = OwnerPolicy {};
    if !owner_load(policy) { return "invalid_owner_policy"; }
    for required in policy.protected_services { if required == id { return "protected_service_required"; } }
    return "";
}
fn owner_host_admit(policy: OwnerPolicy) -> const u8[:] {
    if policy.execution_host != "local" { return "owner_execution_disabled"; }
    if !policy.allow_host_programs { return "host_program_permission_required"; }
    return "";
}
fn owner_cli(directory: const u8[:], text: const u8[:], update: bool) -> i64 {
    if !device_open(directory, if update { 1 } else { 0 }) { print(discovery_rejected("device_binding_busy")); return 1; }
    var policy = OwnerPolicy {};
    let ok = if update { owner_parse(text, policy) && owner_save(policy) } else { owner_load(policy) };
    ct_device_close();
    if !ok { print(discovery_rejected("invalid_owner_policy")); return 1; }
    print(owner_record(policy)); return 0;
}
