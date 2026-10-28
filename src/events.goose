import .contracts;
import os;
namespace continuum;

// Ordered journal (M07). In-memory ring for the running process plus an
// optional append-only file sink: one line per beat,
// seq|timestamp_ms|type|run|payload. Payloads are operator text and
// measurements, never credentials. Sequence numbers are assigned here, at
// append time, so file order and memory order cannot disagree.
var journal: Event[>..] = [];
var journal_path: u8[..256] = "";
var journal_to_file: bool = false;

fn journal_enable_file(path: const u8[:]) {
    journal_path = path;
    journal_to_file = path.len > 0;
}

fn journal_disable_file() {
    journal_to_file = false;
    journal_path = "";
}

fn append_event(event: Event) -> Outcome {
    var stamped = event;
    stamped.sequence = journal.len;
    if journal_to_file {
        let line = str(stamped.sequence, "|", stamped.timestamp_ms, "|",
            stamped.event_type, "|", stamped.run_id, "|", stamped.payload_json, "\n");
        if !append_file(journal_path, line) {
            // Memory stays untouched: file order and memory order cannot
            // disagree, and the sequence number is reused by the next beat.
            return Outcome { status: Status.Failed, message: "journal file append failed" };
        }
    }
    journal.push(stamped);
    return Outcome { status: Status.Completed, message: "journaled" };
}

fn journal_len() -> i64 {
    return journal.len;
}

fn journal_seq(i: i64) -> i64 {
    return journal[i].sequence;
}

fn journal_type(i: i64) -> u8[:] {
    return journal[i].event_type;
}
