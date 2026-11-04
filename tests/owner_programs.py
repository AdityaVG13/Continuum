#!/usr/bin/env python3
"""Real local program lifecycle: owner authority, isolated execution, bounded state.

No model, router, keychain, simulated shell, or network request is used. Programs
are authored input and execute in the production OS sandbox. The transcript is
repeatable evidence under .build; unavailable isolation is an explicit failure.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import uuid


def main():
    binary = str(Path(sys.argv[1]).resolve())
    root = Path(__file__).resolve().parents[1]
    directory = root / ".build" / ("owner-programs-" + uuid.uuid4().hex)
    directory.mkdir(mode=0o700)
    home = directory / "chosen-state"
    home.mkdir(mode=0o700)
    env = dict(os.environ, CONTINUUM_HOME=str(home),
               MODEL_API_KEY="must-not-reach-generated-code",
               CONTINUUM_TEST_PRIVATE="also-must-not-be-inherited")
    transcript = []

    def run(*args, succeeds=True, executable=binary, extra_env=None):
        result = subprocess.run([executable, *args], env=dict(env, **(extra_env or {})), capture_output=True,
                                text=True, timeout=20)
        transcript.append(dict(args=list(args), exit=result.returncode,
                               stdout=result.stdout, stderr=result.stderr))
        assert (result.returncode == 0) == succeeds, result.stdout + result.stderr
        assert env["MODEL_API_KEY"] not in result.stdout + result.stderr
        assert env["CONTINUUM_TEST_PRIVATE"] not in result.stdout + result.stderr
        return result

    def install(identity, source, succeeds=True):
        return run("--program-install", json.dumps(dict(id=identity,
            purpose="Owner-approved local computation.", interval_ms=0,
            steps=[], source=source)), succeeds=succeeds)

    try:
        policy = run("--owner-policy")
        defaults = json.loads(policy.stdout)
        assert defaults["execution_host"] == "local" and not defaults["allow_host_programs"]
        assert home.is_dir(), "the owner-selected state location must be used"
        source = '''n=$(printf '%s' "$CONTINUUM_INPUT" | /usr/bin/wc -c)
printf '{"actions":[],"summary":"observed-input-bytes:%s"}' "$n"'''
        denied = install("local-audit", source, succeeds=False)
        assert "host_program_permission_required" in denied.stdout
        policy = dict(defaults, allow_host_programs=True, max_programs=3,
                      program_timeout_ms=500, program_retention_days=1)
        run("--owner-policy-set", json.dumps(policy))
        # Exercise the model/tool/receipt boundary on a host-only installation,
        # not just the CLI. The provider transport is authored; code is real.
        fixture = str(Path(sys.argv[2]).resolve())
        settings = home / "settings.json"
        settings.write_text(json.dumps(dict(controller_model="fixture-controller", task_model="fixture-workload",
            max_output_tokens=512, max_tool_rounds=4, request_timeout_ms=3000)))
        run("--talk", "Read the reusable programs workflow.", executable=fixture,
            extra_env=dict(CONTINUUM_AGENT_FIXTURE="program", CONTINUUM_PROGRAM_TARGET="local",
                           CONTINUUM_PROGRAM_OPERATION="read_skill", CONTINUUM_PROGRAM_PAYLOAD="programs",
                           CONTINUUM_PROGRAM_EXPECT="Reusable programs and capability boundary"))
        spec = dict(id="local-audit", purpose="Owner-approved local computation.", interval_ms=0, steps=[], source=source)
        run("--talk", "Install the local audit program.", executable=fixture,
            extra_env=dict(CONTINUUM_AGENT_FIXTURE="program", CONTINUUM_PROGRAM_TARGET="local",
                           CONTINUUM_PROGRAM_OPERATION="install_program", CONTINUUM_PROGRAM_PAYLOAD=json.dumps(spec),
                           CONTINUUM_PROGRAM_EXPECT=r'\"installed\":true'))
        registry = home / "device/programs.json"
        assert registry.is_file() and registry.stat().st_mode & 0o077 == 0
        executed = run("--program-run", "local-audit")
        outcome = json.loads(executed.stdout)
        assert outcome["status"] == "completed" and not outcome["mutation_attempted"]
        assert "observed-input-bytes:" in json.dumps(outcome), "actual authored code, not a recipe or canned receipt, must run"
        assert json.loads(registry.read_text())["programs"][0]["runs"] == 1
        # Placement is an owner setting, never a model-selected remote endpoint.
        run("--owner-policy-set", json.dumps(dict(policy, execution_host="disabled")))
        refused = run("--program-run", "local-audit", succeeds=False)
        assert "owner_execution_disabled" in refused.stdout
        run("--owner-policy-set", json.dumps(policy))
        # Isolated code cannot write even inside the parent's chosen state root,
        # read its credentials, or inherit its process environment.
        marker = directory / "sandbox-must-not-write"
        install("confinement", f'''test -z "$MODEL_API_KEY" && test -z "$CONTINUUM_TEST_PRIVATE" &&
if printf forbidden > '{marker}'; then exit 21; fi
if /bin/cat '{home}/device/owner.json' >/dev/null 2>&1; then exit 22; fi
printf '{{"actions":[],"summary":"isolated"}}' ''')
        confined = run("--program-run", "confinement")
        assert not marker.exists() and "isolated" in confined.stdout
        install("deadline", "while :; do :; done")
        started = time.monotonic()
        timed = run("--program-run", "deadline", succeeds=False)
        assert time.monotonic() - started < 3, "wall time must bound an authored infinite loop"
        assert "program_execution_failed" in timed.stdout
        install("fourth", source, succeeds=False)
        # Retention removes only inactive, resolved entries; it must retain both
        # a due recurring program and ambiguous/failed work for reconciliation.
        saved = json.loads(registry.read_text())
        saved["programs"][0].update(enabled=False, last_attempt_wall_ms=1)
        saved["programs"][1].update(enabled=True, interval_ms=60000, last_attempt_wall_ms=1)
        saved["programs"][2].update(enabled=False, last_attempt_wall_ms=1)
        registry.write_text(json.dumps(saved))
        pruned = run("--program-prune")
        assert json.loads(pruned.stdout)["pruned"] == 1
        remaining = json.loads(registry.read_text())["programs"]
        assert {p["id"] for p in remaining} == {"confinement", "deadline"}
        assert remaining[1]["status"] == "failed", "pruning is not permission to erase an uncertain execution"
        # Neither invalid policy nor malformed source replaces the durable grant.
        bad = run("--owner-policy-set", json.dumps(dict(policy, unrestricted=True)), succeeds=False)
        assert "invalid_owner_policy" in bad.stdout
        assert json.loads(run("--owner-policy").stdout) == policy
        print("OWNER_PROGRAMS_ALL_GREEN artifact=" + str(directory / "transcript.json"))
    finally:
        (directory / "transcript.json").write_text(json.dumps(transcript, indent=2) + "\n")
        print("OWNER_PROGRAMS_TEST_SHA256", hashlib.sha256(Path(__file__).read_bytes()).hexdigest())


if __name__ == "__main__":
    main()
