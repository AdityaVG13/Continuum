# Synthetic contract examples

Every file in this directory was authored to illustrate the proposed contracts. None is a captured Meta response, measured network result or executed action. The contract suites read some of them as shape inputs; no lane presents them as a completed demo.

`controller-context.example.json` shows the data sent to the Meta controller. `apply-profile.example.json` and `restore-profile.example.json` show hypothetical model calls. They are independent shape examples, not a recorded sequential transcript; the later observation/lease IDs would need actual receipts in a live run. The 9000 kbit/s fixture rate is invented and must never become a default shaping rate.

`meta-request.example.json` shows an example HTTP body and contains obvious replacement markers for the prompt and validated context. It includes six tool definitions for inspection, and is not a command to issue a live request. The implemented adapter (`src/meta_provider.goose`) loads current instructions, builds input, preserves response/tool pairings, enforces budgets and retains provenance on every request.

`tool-result.example.json` intentionally reports NOT_IMPLEMENTED. `workload-result.example.json` reports missing evidence, not a successful report. Semantic guards must reject cross-run revisions, stale observation IDs, missing profile authority and uncited findings even when their JSON shapes validate.

## Synthetic release corpus

`corpus/` contains manually authored release evidence and expected findings for the proposed meaningful task. `workload-hold.example.json` illustrates a candidate hold decision citing that corpus. Both are design fixtures; neither is a captured Meta result or evidence that a live semantic validator exists. Keep the corpus version and evidence IDs stable when implementing and evaluating the workload.
