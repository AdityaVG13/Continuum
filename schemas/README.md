# Contract schemas

These are version 1.0 wire contracts and the authoritative shape reference. The Goose modules enforce them locally (`src/tooljson.goose` for tool calls and results, `src/workload.goose` for workload verdicts, `src/meta_shape.goose` for Meta requests and responses). `meta-tools.json` contains the six flat Responses API function definitions. Their `strict` flag is false deliberately: full local validation is mandatory and provider strict-subset compatibility remains a live preflight gate.

## Files

- `controller-context.schema.json`: bounded model input, references the observation and task schemas.
- `observation.schema.json`: measured or explicitly synthetic signals, units, sample age and route identity. Unknown measurements are null.
- `task-context.schema.json`: goal, revision, deadline, inputs and dependencies; model internals are not task state.
- `action-request.schema.json`: apply/restore requests from model tool calls, never raw shell.
- `tool-result.schema.json`: six tool outcomes, including rejection and unimplemented states.
- `workload-result.schema.json`: cited release findings as candidate output, subject to a separate semantic validator.

## Checks beyond schema

For a new apply, require the same session/run/scope/path, valid task and configuration revisions, route epoch equality, observation age and coherent units. Restoration instead checks owned-lease identity, current revision and restorable state; observation references are audit context, not an age gate. Never let apply cooldowns or exhausted profile-change budgets prevent owned-lease restoration. The guardian must re-read authority immediately before mutation. Profile IDs resolve only to the current local allowlist; schema-valid input does not create authority. Prohibit request-ID reuse with different parameters; duplicate identical requests return the earlier receipt. An `ok` transport response is not the same as an applied action, verified recovery, or accepted task result.

`now_ms`, deadlines and observation timestamps are monotonic times within one explicitly identified session; they are not cross-machine clocks or restart-safe durable timestamps. Restart recovery must create a new session and reconcile owned leases with persistent receipts before accepting requests. Schema IDs use the reserved `.invalid` domain as stable identifiers, not download URLs. Resolve the relative references from this directory.

The Goose records represent optional/unknown values explicitly; JSON conversion, bounds and round-trip conformance are implemented in the adapters and pinned by the contract suites. Keep those suites green when the records change. Numeric JSON limits are conservative for interoperable exact integer handling.

## Ambiguous action outcomes

The apply, action-read and restore receipts permit `state: "unknown"`. Use it when a timeout or interrupted native response leaves the actual network mutation uncertain. `status: "ok"` means the tool returned a valid receipt, not that the mutation succeeded. Reconcile owned state before another mutation; do not convert unknown into failed or repeat an action blindly.

The additional `fixtures/workload-hold.example.json` shows the candidate report format against the synthetic corpus in `fixtures/corpus/`. Corpus expectation files are validator-design inputs, not measured model outputs.
