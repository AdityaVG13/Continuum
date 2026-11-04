#!/usr/bin/env python3
"""Cross-process continuity through the real CLI and an authored Meta transport.

No live provider, physical router, model-quality claim, or source-fixture writes.
Every sandbox and transcript remains under .build for repeatable inspection.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
BIN = Path(sys.argv[1]).resolve()
ARTIFACT = ROOT / ".build" / ("continuity-acceptance-" + str(time.time_ns()))
ARTIFACT.mkdir(parents=True)
BASE = {k: v for k, v in os.environ.items() if k not in ("MODEL_API_KEY", "META_API_KEY")}
BASE.update(MODEL_API_KEY="synthetic-continuity-key", CONTINUUM_FIXTURE_SESSION="normal")
transcript = []


def check(ok, message):
    if not ok:
        raise AssertionError(message)
    print("ok", message)


def sandbox(name):
    directory = ARTIFACT / name
    directory.mkdir()
    for entry in ("fixtures", "schemas"):
        shutil.copytree(ROOT / entry, directory / entry)
    shutil.copytree(ROOT / "docs" / "prompts", directory / "docs" / "prompts")
    config = directory / "config"
    config.mkdir()
    return directory, dict(BASE, XDG_CONFIG_HOME=str(config))


def invoke(directory, env, *args):
    result = subprocess.run([str(BIN), *args], cwd=directory, env=env,
                            capture_output=True, text=True, timeout=15)
    transcript.append({"args": args, "status": result.returncode,
                       "stdout": result.stdout, "stderr": result.stderr})
    (ARTIFACT / "transcript.json").write_text(json.dumps(transcript, indent=2) + "\n")
    return result


def report(result):
    return json.loads(next(line for line in result.stdout.splitlines()
                           if line.startswith('{"schema_version":')))


directory, env = sandbox("committed")
first = invoke(directory, env, "--loop", "continuity-proof")
check(first.returncode == 0, "authored controller, workload, validation and restoration complete")
r = report(first)
check(r["task_validated"] and r["task_committed"] and not r["resumed"],
      "validated output reaches a durable commit before CLI success")
check(r["applied"] and r["restored"] and r["profile_after"] == "baseline-fifo",
      "the task and the guarded intervention share one runtime and leave no active lease")
state = Path(r["checkpoint_path"])
check(state.is_file() and state.stat().st_mode & 0o077 == 0,
      "the durable artifact is private to the owner")
check("synthetic-continuity-key" not in state.read_text(), "the checkpoint never persists credentials")

# Fresh process, now with an unavailable provider. Reuse is not a fresh model result.
resume_env = dict(env, CONTINUUM_FIXTURE_SESSION="outage")
resume_env.pop("MODEL_API_KEY")
second = invoke(directory, resume_env, "--resume", "continuity-proof")
s = report(second)
check(second.returncode == 0 and s["resumed"] and s["task_committed"] and s["controller_model_calls"] == 0 and s["task_model_calls"] == 0,
      "a separate process resumes the accepted artifact with no key or provider call")
check(s["task_result"] == r["task_result"] and s["task_provenance"] == r["task_provenance"],
      "resumption preserves exact output and original provenance")
check(s["model_source"] == "committed_artifact" and s["actuator"] == "none"
      and s["observation_provenance"] == "none",
      "resume reports artifact recovery, not a new model or network session")

for relative in ("fixtures/corpus/security-review.md", "docs/prompts/workload.md", "schemas/workload-result.schema.json"):
    path = directory / relative
    original = path.read_text()
    path.write_text(original + "\n ")
    refused = invoke(directory, resume_env, "--resume", "continuity-proof")
    check(refused.returncode != 0, "resume refuses changed current bytes: " + relative)
    path.write_text(original)

# A syntactically valid checkpoint whose report was altered still goes through
# independent semantic validation, rather than trusting its saved status flag.
saved = state.read_text()
check("REL-17" in saved, "the artifact contains the accepted result")
state.write_text(saved.replace("REL-17", "NOT-A-FINDING"))
check(invoke(directory, resume_env, "--resume", "continuity-proof").returncode != 0,
      "resume rejects an independently invalid saved report")
state.write_text(saved)

for mode in ("outage", "invalid", "changed-input"):
    directory, env = sandbox(mode)
    env["CONTINUUM_FIXTURE_SESSION"] = mode
    failed = invoke(directory, env, "--loop", "failed-" + mode)
    f = report(failed)
    check(failed.returncode != 0 and not f["task_committed"] and f["restored"]
          and f["profile_after"] == "baseline-fifo",
          mode + " cannot commit and still restores its network intervention")

check(invoke(directory, env, "--resume", "../escape").returncode != 0,
      "run identity cannot escape the private store")
print("CONTINUITY_ALL_GREEN artifact=" + str(ARTIFACT / "transcript.json"))
