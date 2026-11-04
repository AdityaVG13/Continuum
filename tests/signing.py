#!/usr/bin/env python3
"""Build-policy regression: signing is stable, opt-in and macOS-specific.

Dry runs test the real Make recipes without a certificate, provider calls,
Keychain access or router operations. Actual signatures need a separate local
qualification with an owner-selected certificate; this is not an OS port test.
"""
import os
from pathlib import Path
import shlex
import subprocess

ROOT = Path(__file__).resolve().parents[1]
ENV = {k: v for k, v in os.environ.items()
       if k not in ("MAKEFLAGS", "MFLAGS", "MAKELEVEL", "MODEL_API_KEY")}
TARGETS = {".build/continuum": "org.continuum.controller",
           ".build/continuum-leap": "org.continuum.leap"}


def recipe(target, host, identity):
    result = subprocess.run(
        ["make", "--no-print-directory", "--dry-run", "--always-make", target,
         "HOST_OS=" + host, "MACOS_SIGN_IDENTITY=" + identity],
        cwd=ROOT, env=ENV, capture_output=True, text=True, timeout=15)
    return result


for target, identifier in TARGETS.items():
    result = recipe(target, "Darwin", "test-only-signing-identity")
    assert result.returncode == 0, result.stderr
    commands = [shlex.split(line) for line in result.stdout.splitlines() if line.strip()]
    signing = [cmd for cmd in commands if Path(cmd[0]).name == "codesign" and "--sign" in cmd]
    assert len(signing) == 1, target + ": configured macOS build must sign after linking"
    command = signing[0]
    assert command[command.index("--sign") + 1] == "test-only-signing-identity"
    assert command[command.index("--identifier") + 1] == identifier, "identity must not depend on binary contents"
    assert command[-1] == target and "--timestamp=none" in command, "local signing must not contact a timestamp server"
    assert any(Path(cmd[0]).name == "codesign" and "--verify" in cmd and
               "--strict" in cmd and cmd[-1] == target for cmd in commands), "signed build must verify its output"

    unsigned = recipe(target, "Darwin", "")
    assert unsigned.returncode == 0 and "--sign" not in unsigned.stdout, "development builds must not require a certificate"
    refused = recipe(target, "Darwin", "-")
    assert refused.returncode != 0, "ad-hoc signing must not masquerade as a persistent identity"

    for host in ("Linux", "Windows_NT"):
        portable = recipe(target, host, "test-only-signing-identity")
        assert portable.returncode == 0, portable.stderr
        assert "codesign" not in portable.stdout and "-framework" not in portable.stdout, (
            host + ": non-macOS builds must not require Apple tools or frameworks")

print("SIGNING_POLICY_GREEN stable identifiers, verification, unsigned development, non-Apple isolation")
