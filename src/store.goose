// Durable lease store: the apply-intent record that survives a crash.
// Written BEFORE any mutation (actuator contract), cleared only after a
// verified restore. Format is one key=value per line, atomically replaced,
// so a torn write can never look like a valid lease. Malformed or partial
// files load as "not found" -- fail-closed, never a guessed lease.
import .contracts;
import std;
import os;
namespace continuum;

struct LeaseFile {
    found: bool = false,
    lease_id: u8[..64] = "",
    profile_id: u8[..64] = "",
    prev_profile_id: u8[..64] = "",
    revision: i64 = 0,
    expires_at_ms: i64 = 0,
}

fn lease_save(path: const u8[:], lease_id: const u8[:], profile_id: const u8[:],
              prev_profile_id: const u8[:], revision: i64, expires_at_ms: i64) -> bool {
    if lease_id == "" || profile_id == "" || prev_profile_id == "" {
        return false;
    }
    let text = str("lease=", lease_id,
        "\nprofile=", profile_id,
        "\nprev=", prev_profile_id,
        "\nrevision=", revision,
        "\nexpires=", expires_at_ms, "\n");
    return write_file_atomic(path, text);
}

fn lease_load(path: const u8[:]) -> LeaseFile {
    var out = LeaseFile {};
    var text: u8[>..] = [];
    guard read_file(path, text) else { return out; }
    var have_lease = false;
    var have_profile = false;
    var have_prev = false;
    var have_expiry = false;
    each_split(text, '\n') {
        let eq = find(it, "=");
        if eq > 0 {
            let key = it[..eq];
            let val = it[eq + 1..];
            if key == "lease" {
                out.lease_id = val;
                have_lease = val.len > 0;
            } else if key == "profile" {
                out.profile_id = val;
                have_profile = val.len > 0;
            } else if key == "prev" {
                out.prev_profile_id = val;
                have_prev = val.len > 0;
            } else if key == "revision" {
                let v, ok = parse_int(val);
                if ok { out.revision = v; }
            } else if key == "expires" {
                let v, ok = parse_int(val);
                if ok { out.expires_at_ms = v; have_expiry = true; }
            }
        }
    };
    out.found = have_lease && have_profile && have_prev && have_expiry;
    if !out.found {
        return LeaseFile {};
    }
    return out;
}

fn lease_clear(path: const u8[:]) -> bool {
    if !file_exists(path) {
        return true;
    }
    return delete_file(path);
}
