#!/usr/bin/env python3
"""Factory-pending enrollment: the program creates the admin credential.

A factory-reset router has no admin password to type. The owner's explicit
enroll is the authentication boundary: the program generates the credential,
stages it in the OS vault before any write, submits the vendor first-run form,
proves a protected read under the staged credential, and never replays on a
retry. Test-only values live in this process; no real router or Keychain is used.
"""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

UA = "OpenAI File Downloader, XaiImageApiFetch/1.0"
FIXTURE_PASSWORD = "FactoryFixture99"
OWNER_PASSWORD = "OwnerOwned77"
STEM = "LabStem"
IDENTITY = {"productid": "RT-TEST", "mac": "02:00:00:00:00:01",
            "firmware": "3.0.0.4/test/1"}


def free_port():
    with socket.socket() as s:
        s.bind(("", 0))
        return s.getsockname()[1]


def status(port):
    req = urllib.request.Request(f"http://127.0.0.1:{port}/api/status",
                                 headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=3) as response:
        return json.load(response)


def login_token(port, user, password):
    """The firmware answers 200 with the login page and no token on refusal."""
    import base64
    body = urllib.parse.urlencode({
        "login_authorization": base64.b64encode(f"{user}:{password}".encode()).decode()}).encode()
    req = urllib.request.Request(f"http://127.0.0.1:{port}/login.cgi", data=body,
                                 headers={"User-Agent": UA,
                                          "Referer": f"http://127.0.0.1:{port}/Main_Login.asp"})
    with urllib.request.urlopen(req, timeout=3) as response:
        return "asus_token=" in (response.headers.get("Set-Cookie") or "")


def records(stdout):
    return [json.loads(line) for line in stdout.splitlines() if line.startswith("{")]


def vault_env(ref):
    """The modeled vault maps a ref to CONTINUUM_SECRET_<REF>, folded like the C seam."""
    return "CONTINUUM_SECRET_" + "".join(c.upper() if c.isalnum() else "_" for c in ref)


def run(binary, env, *args):
    result = subprocess.run([binary, *args], env=env, text=True, capture_output=True, timeout=120)
    return result


def main():
    binary = str(Path(sys.argv[1]).resolve())
    double_binary = str(Path(sys.argv[2]).resolve())
    port = free_port()
    with tempfile.TemporaryDirectory(prefix="factory-enroll-") as scratch:
        scratch = Path(scratch)
        os.chmod(scratch, 0o700)
        home = scratch / "home"
        home.mkdir(mode=0o700)
        double = subprocess.Popen(
            [double_binary, str(port)],
            env=dict(os.environ, ROUTER_PASSWORD=FIXTURE_PASSWORD, ROUTER_WIZARD="1"),
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            for _ in range(60):
                try:
                    before = status(port)
                    break
                except Exception:
                    time.sleep(0.1)
            else:
                raise SystemExit("ENROLL_CHECK_FAILED the router double never answered")
            assert before["setup_done"] is False, "the fixture must start factory-pending"
            env = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(home / "config"),
                       CONTINUUM_DEVICE_FIXTURE="1")

            selected = run(binary, env, "--device-select", "lo0:127.0.0.1", STEM, str(port))
            assert selected.returncode == 0, selected.stdout + selected.stderr
            state = records(selected.stdout)[-1]
            assert state["phase"] == "selected" and state["identity"]["productid"] == "", \
                "selection is not enrollment: nothing may be claimed about the unit yet"
            admin_ref = state["connection"]["admin_ref"]
            assert admin_ref and state["connection"]["admin_user"] == "admin"

            # Enrollment creates an authentication boundary; a bare step is not consent.
            refused = run(binary, env, "--device-step", "enroll")
            assert refused.returncode == 1, refused.stdout + refused.stderr
            refusal = records(refused.stdout)[-1]
            assert refusal["reason"] == "explicit_execute_permission_required", refusal
            assert status(port)["revision"] == before["revision"], \
                "a refused enrollment must not write to the unit"

            enrolled = run(binary, env, "--device-step", "enroll", "--execute")
            assert enrolled.returncode == 0, enrolled.stdout + enrolled.stderr
            after = records(enrolled.stdout)[-1]
            assert after["phase"] == "enrolled", after
            assert after["identity"] == IDENTITY, after["identity"]
            assert after["setup_approved"] is True
            assert after["ready"] is False and after["runtime_verified"] is False, \
                "enrollment is not commissioning and not verified tuning"
            assert FIXTURE_PASSWORD not in enrolled.stdout + enrolled.stderr, \
                "no credential material may reach output"
            live = status(port)
            assert live["setup_done"] is True and live["ssid"].endswith("_2G"), live
            assert live["revision"] > before["revision"], "the first-run form must land"

            # The factory default is dead: the only working credential is the one
            # the program generated, staged, and proved with a protected read.
            assert login_token(port, "admin", "admin") is False, \
                "the factory default must not survive enrollment"
            assert login_token(port, "admin", FIXTURE_PASSWORD) is False, \
                "the pre-existing fixture password must not survive enrollment"
            durable = (home / "config/continuum/device/state.json").read_text()
            assert FIXTURE_PASSWORD not in durable, \
                "durable state must not carry credential material"
            assert json.loads(durable) == after, \
                "the durable record must be exactly the printed record, with no extra fields"

            retry = run(binary, env, "--device-step", "enroll", "--execute")
            assert retry.returncode == 0, retry.stdout + retry.stderr
            assert records(retry.stdout)[-1]["phase"] == "enrolled"
            assert status(port)["revision"] == live["revision"], \
                "a retried enrollment must never replay the first-run form"

            # A paperclip reset erases the credential the program minted. The
            # saved binding then fails its protected read, and enrollment must
            # rebuild the boundary on the now-factory unit instead of reporting
            # the old phase as success.
            reset_port = free_port()
            # The reset unit also refuses the first login after its first-run
            # apply, as the physical unit did: verify must wait it out instead of
            # reporting AdminAuthFailed (which sends the owner to the paperclip).
            reset = subprocess.Popen(
                [double_binary, str(reset_port)],
                env=dict(os.environ, ROUTER_PASSWORD=FIXTURE_PASSWORD, ROUTER_WIZARD="1",
                         ROUTER_WIZARD_REFUSE_AFTER_APPLY="1"),
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                for _ in range(60):
                    try:
                        if status(reset_port)["setup_done"] is False:
                            break
                    except Exception:
                        pass
                    time.sleep(0.1)
                else:
                    raise SystemExit("ENROLL_CHECK_FAILED the reset double never answered")
                state_path = home / "config/continuum/device/state.json"
                saved = json.loads(state_path.read_text())
                saved["connection"]["port"] = reset_port
                state_path.write_text(json.dumps(saved))
                # The owner's recovery action is an explicit re-selection of the
                # same candidate: it discards the stale binding, and only then
                # may the ceremony run again.
                reselected = run(binary, env, "--device-select", "lo0:127.0.0.1", STEM, str(reset_port))
                assert reselected.returncode == 0, reselected.stdout + reselected.stderr
                fresh = records(reselected.stdout)[-1]
                assert fresh["phase"] == "selected" and fresh["identity"]["productid"] == "", \
                    "re-selection must discard the stale binding, not inherit its claims"
                assert fresh["setup_approved"] is False, \
                    "a discarded binding must not carry the old standing permission"
                re_enrolled = run(binary, env, "--device-step", "enroll", "--execute")
                assert re_enrolled.returncode == 0, re_enrolled.stdout + re_enrolled.stderr
                assert records(re_enrolled.stdout)[-1]["phase"] == "enrolled"
                rebuilt = status(reset_port)
                assert rebuilt["setup_done"] is True, \
                    "a reset unit must be re-enrolled, not left factory-pending"
                assert login_token(reset_port, "admin", "admin") is False, \
                    "the rebuilt boundary must not leave the factory default alive"
            finally:
                reset.terminate()
                reset.wait(timeout=10)
            # A unit that is already online is not factory hardware: the ceremony
            # must refuse without writing, and the password it already uses is
            # what takes it over. Storing that password where the adapter looks
            # it up IS the takeover; a protected read then proves it.
            adopt_port = free_port()
            adopt_home = scratch / "adopt"
            adopt_home.mkdir(mode=0o700)
            configured = subprocess.Popen(
                [double_binary, str(adopt_port)],
                env=dict(os.environ, ROUTER_PASSWORD=OWNER_PASSWORD),
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                for _ in range(60):
                    try:
                        owned = status(adopt_port)
                        break
                    except Exception:
                        time.sleep(0.1)
                else:
                    raise SystemExit("ENROLL_CHECK_FAILED the configured double never answered")
                assert owned["setup_done"] is True, "this fixture must start configured"
                adopt_env = dict(os.environ, HOME=str(adopt_home),
                                 XDG_CONFIG_HOME=str(adopt_home / "config"),
                                 CONTINUUM_DEVICE_FIXTURE="1")
                chosen = run(binary, adopt_env, "--device-select", "lo0:127.0.0.1", STEM, str(adopt_port))
                assert chosen.returncode == 0, chosen.stdout + chosen.stderr
                adopt_ref = records(chosen.stdout)[-1]["connection"]["admin_ref"]

                refused = run(binary, adopt_env, "--device-step", "enroll", "--execute")
                assert refused.returncode == 1, refused.stdout + refused.stderr
                stopped = records(refused.stdout)[-1]
                assert "already set up" in stopped["reason"], stopped
                assert status(adopt_port)["revision"] == owned["revision"], \
                    "a refused factory ceremony must not write to a configured unit"

                adopt_env[vault_env(adopt_ref)] = OWNER_PASSWORD
                # The unfinished attempt left phase=enrolling; a stored credential
                # must let the step resume instead of refusing forever.
                resumed = run(binary, adopt_env, "--device-step", "enroll", "--execute")
                assert resumed.returncode == 0, resumed.stdout + resumed.stderr
                assert records(resumed.stdout)[-1]["phase"] == "enrolled"
                taken = run(binary, adopt_env, "--device-step", "inspect")
                assert taken.returncode == 0, taken.stdout + taken.stderr
                adopted = records(taken.stdout)[-1]
                assert adopted["phase"] == "enrolled" and adopted["identity"] == IDENTITY, adopted
                assert status(adopt_port)["revision"] == owned["revision"], \
                    "taking over a live unit must not change it"
                durable = (adopt_home / "config/continuum/device/state.json").read_text()
                assert OWNER_PASSWORD not in durable, "durable state must not carry the password"
            finally:
                configured.terminate()
                configured.wait(timeout=10)

            print("ENROLL_CHECK_GREEN", admin_ref)
        finally:
            double.terminate()
            double.wait(timeout=10)


if __name__ == "__main__":
    main()
