#!/usr/bin/env python3
"""Real executable + PTY acceptance; no provider requests or Keychain writes."""
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import struct
import subprocess
import sys
import termios
import time

BIN = str(Path(sys.argv[1]).resolve())
ENV = {k: v for k, v in os.environ.items() if k not in ("MODEL_API_KEY", "META_API_KEY")}
ENV["XDG_CONFIG_HOME"] = str(Path(".build/setup-config-" + str(os.getpid())).resolve())
Path(ENV["XDG_CONFIG_HOME"]).mkdir(parents=True, exist_ok=True)


def check(ok, message):
    if not ok:
        raise AssertionError(message)
    print("ok", message)


result = subprocess.run([BIN, "--discover"], env=ENV, capture_output=True, text=True, timeout=10)
check(result.returncode == 0, "read-only discovery works without a Meta key or router address")
observed = json.loads(result.stdout)
check(observed["provenance"] == "live_host" and isinstance(observed["interfaces"], list),
      "discovery returns host observations rather than a simulated topology")
check(all(i["name"] in dict(__import__("socket").if_nameindex()).values() for i in observed["interfaces"]),
      "discovered interfaces exist on this host")
check(all(c["source"] in ("default_route", "neighbor_cache") for c in observed["candidates"]),
      "router candidates come from observed routes or neighbors, not guessed IPs")
if sys.platform == "darwin":
    import ipaddress
    import re
    route = subprocess.run(["/sbin/route", "-n", "get", "default"], capture_output=True, text=True)
    gateway = re.search(r"gateway: (\S+)", route.stdout)
    interface = re.search(r"interface: (\S+)", route.stdout)
    if gateway and interface and ipaddress.ip_address(gateway[1]).is_private:
        on_link = any(i["name"] == interface[1] and
                      ipaddress.ip_address(gateway[1]) in ipaddress.ip_network(i["address"] + "/" + i["netmask"], strict=False)
                      for i in observed["interfaces"])
        if on_link:
            check(any(c["address"] == gateway[1] and c["interface"] == interface[1]
                      for c in observed["candidates"]), "default management gateway is discovered from the OS route")

plain = subprocess.run([BIN, "--tui"], env=ENV, input="", capture_output=True, text=True, timeout=5)
check(plain.returncode != 0 and "terminal" in plain.stdout.lower() and "\x1b" not in plain.stdout,
      "explicit TUI refuses a pipe without emitting terminal escapes")

master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
env = dict(ENV, TERM="xterm-256color", NO_COLOR="1", MODEL_API_KEY="synthetic-existing-key")
process = subprocess.Popen([BIN, "--tui"], stdin=slave, stdout=slave, stderr=slave, env=env)
output = bytearray()


def expect(text, timeout=8):
    start = len(output)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if text.encode() in output[start:]:
            return
        ready, _, _ = select.select([master], [], [], 0.1)
        if ready:
            try:
                chunk = os.read(master, 65536)
            except OSError:
                break
            if not chunk:
                break
            output.extend(chunk)
    raise AssertionError("TUI did not reach " + repr(text))


monitor = None
monitor_path = Path(ENV["XDG_CONFIG_HOME"]) / "continuum/service/status.json"
try:
    expect("STEP 1 OF 8")
    check(b"CONTINUUM / SETUP" in output, "first run opens the setup wizard, not a menu")
    os.write(master, b"a")
    expect("[m] Meta")
    check(not (termios.tcgetattr(slave)[3] & termios.ECHO), "interactive UI disables terminal echo")
    os.write(master, b"m")
    expect("MODEL_API_KEY")
    secret = b"synthetic-private-key-must-never-appear"
    os.write(master, secret + b"\r")
    expect("Save in Keychain?" if sys.platform == "darwin" else "Secure persistence unavailable")
    os.write(master, b"n")
    expect("session only")
    os.write(master, b"c")
    for label, value in (("Controller / discovery model", "fixture-controller"),
                         ("Workload model", "fixture-workload"),
                         ("Output token cap", "512"),
                         ("Maximum controller / discovery calls", "4"),
                         ("Request timeout", "3000")):
        expect(label)
        os.write(master, b"\x15" + value.encode() + b"\r")
    expect("Model settings saved")
    settings = Path(ENV["XDG_CONFIG_HOME"]) / "continuum/settings.json"
    saved = json.loads(settings.read_text())
    check(saved == {"controller_model": "fixture-controller", "task_model": "fixture-workload",
                    "max_output_tokens": 512, "max_tool_rounds": 4, "request_timeout_ms": 3000},
          "the interactive form persists model/budget settings without storing the API key")
    os.write(master, b"f")
    for label, value in (("Execution host", "local"),
                         ("Allow isolated local programs", "0"),
                         ("Allowed device operations", "runtime,verify"),
                         ("Protected users/devices", "workstation"),
                         ("Capabilities to preserve", "ftp"),
                         ("Program slots", "2"),
                         ("Resolved program retention", "3"),
                         ("Program wall time", "500")):
        expect(label)
        os.write(master, b"\x15" + value.encode() + b"\r")
    expect("Save these owner permissions?")
    os.write(master, b"\r")
    expect("Owner permissions saved")
    owner_file = Path(ENV["XDG_CONFIG_HOME"]) / "continuum/device/owner.json"
    check(json.loads(owner_file.read_text()) == dict(schema_version=1,
          allowed_operations=["runtime", "verify"], execution_host="local", allow_host_programs=False,
          protected_clients=["workstation"], protected_services=["ftp"], max_programs=2,
          program_retention_days=3, program_timeout_ms=500),
          "the owner can set authority, protected users and retention from setup without Meta")
    check(owner_file.stat().st_mode & 0o077 == 0, "owner permission state is private")
    os.write(master, b"o")
    # A PTY read may end after the heading, before the phase in the same frame.
    expect("unselected")
    check(b"DEVICE / LIFECYCLE" in output and b"unselected" in output,
          "setup exposes the authoritative device phase rather than implying router readiness")
    os.write(master, b"g")
    expect("No installed programs")
    check(b"PROGRAMS / LOCAL" in output, "the program panel identifies the local registry, not a model response")
    check(not (Path(ENV["XDG_CONFIG_HOME"]) / "continuum/device/state.json").exists(),
          "local program inspection needs no model, selected target or device-write grant")
    os.write(master, b"e")
    expect("Select a device first")
    check(not (Path(ENV["XDG_CONFIG_HOME"]) / "continuum/device/state.json").exists(),
          "setup cannot dispatch enrollment or commissioning without an owner-selected device")
    os.write(master, b"p")
    expect("SELECT DEVICE")
    os.write(master, b"\x1b")
    expect("Selection cancelled")
    check(not (Path(ENV["XDG_CONFIG_HOME"]) / "continuum/device/state.json").exists(),
          "cancelling owner selection leaves no device authority or stale target")
    os.write(master, b"s")
    for label, value in (("Monitor interval", "1000"), ("Incident cooldown", "60000"),
                         ("Meta calls per hour", "1"), ("Automatic Meta assessments", "0")):
        expect(label)
        os.write(master, b"\x15" + value.encode() + b"\r")
    expect("Start background monitor?")
    os.write(master, b"\r")
    expect("Monitor started")
    monitor_path = Path(ENV["XDG_CONFIG_HOME"]) / "continuum/service/status.json"
    monitor = json.loads(monitor_path.read_text())
    check(monitor["phase"] == "monitoring" and monitor["meta_permission"] is False,
          "one-time TUI setup starts a real monitor without authorizing paid model calls")
    os.write(master, b"d")
    expect("NETWORK")
    # Strip carries observation age once discovery completes.
    deadline = time.monotonic() + 8
    while b"just now" not in output and time.monotonic() < deadline:
        ready, _, _ = select.select([master], [], [], 0.1)
        if ready:
            output.extend(os.read(master, 65536))
    check(b"just now" in output, "strip shows observation age after discovery")
    os.write(master, b"\x03")
    # A PTY has finite output capacity: act like a real terminal and drain
    # pending redraws while waiting, rather than blocking its writer in exit.
    deadline = time.monotonic() + 5
    while process.poll() is None and time.monotonic() < deadline:
        ready, _, _ = select.select([master], [], [], 0.05)
        if ready:
            output.extend(os.read(master, 65536))
    check(process.wait(timeout=1) == 0, "Ctrl-C exits the UI cleanly")
    identity = subprocess.run(["ps", "-p", str(monitor["pid"]), "-o", "uid=,args="],
                              capture_output=True, text=True, check=True).stdout.split(None, 1)
    check(identity[0] == str(os.geteuid()) and BIN + " --serve" in identity[1],
          "setup starts the current executable as an owned resident service")
    deadline = time.monotonic() + 4
    while time.monotonic() < deadline:
        current = json.loads(monitor_path.read_text())
        if current["pid"] == monitor["pid"] and current["samples"] > monitor["samples"]:
            break
        time.sleep(0.05)
    else:
        raise AssertionError("closing setup stopped live monitoring")
    check(current["phase"] == "monitoring" and current["model_calls_this_hour"] == 0,
          "live observation advances after setup closes without paid model calls")
    Path(".build/service-tui-acceptance.json").write_text(json.dumps(current, indent=2) + "\n")
    check(bool(termios.tcgetattr(slave)[3] & termios.ECHO), "exit restores terminal echo")
    check(secret not in output and b"synthetic-existing-key" not in output,
          "neither entered nor existing API keys appear in terminal output")
    Path(".build/tui-acceptance.ansi").write_bytes(output)
finally:
    if process.poll() is None:
        process.terminate()
        # Drain the terminal on failures too, so the final redraw cannot block
        # shutdown and hide the original assertion behind a wait timeout.
        deadline = time.monotonic() + 5
        while process.poll() is None and time.monotonic() < deadline:
            ready, _, _ = select.select([master], [], [], 0.05)
            if ready:
                try:
                    output.extend(os.read(master, 65536))
                except OSError:
                    break
        process.wait(timeout=1)
    if monitor is not None:
        identity = subprocess.run(["ps", "-p", str(monitor["pid"]), "-o", "uid=,args="],
                                  capture_output=True, text=True).stdout.split(None, 1)
        if len(identity) == 2 and identity[0] == str(os.geteuid()) and BIN + " --serve" in identity[1]:
            os.kill(monitor["pid"], __import__('signal').SIGTERM)
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline and json.loads(monitor_path.read_text())["phase"] != "stopped":
                time.sleep(0.05)
            check(json.loads(monitor_path.read_text())["phase"] == "stopped", "the test-owned detached monitor stops cleanly")
    os.close(master)
    os.close(slave)

# Numbered sections + resident readout + in-TUI program read (same isolated
# state: the stopped monitor's status.json must be visible, not hidden).
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
env = dict(ENV, TERM="xterm-256color", NO_COLOR="1")
process = subprocess.Popen([BIN, "--tui"], stdin=slave, stdout=slave, stderr=slave, env=env)
output = bytearray()
try:
    expect("STEP 1 OF 8")
    os.write(master, b"a")
    expect("[3] Device")
    check(b"DEVICE / LIFECYCLE" in output and b"unselected" in output,
          "first run lands on the device lifecycle, not a menu, and binds nothing")
    os.write(master, b"2")
    expect("NETWORK / LIVE HOST EVIDENCE")
    os.write(master, b"3")
    expect("DEVICE / LIFECYCLE")
    deadline = time.monotonic() + 8
    while b"unselected" not in output and time.monotonic() < deadline:
        ready, _, _ = select.select([master], [], [], 0.1)
        if ready:
            output.extend(os.read(master, 65536))
    check(b"unselected" in output, "section 3 (Device) shows lifecycle without a binding side effect")
    os.write(master, b"4")
    expect("PROGRAMS / LOCAL")
    os.write(master, b"J")
    expect("SCROLL +10")
    # Regression: PgUp (ESC [ 5 ~) must page, never act as the section-5 key.
    os.write(master, b"\x1b[5~")
    expect("CONTINUUM - PROGRAMS")
    check(b"CONTINUUM - RESIDENT" not in output[output.rfind(b"CONTINUUM - PROGRAMS"):],
          "PgUp pages to the top without switching sections")
    os.write(master, b"\r")
    expect("Program id")
    os.write(master, b"nosuch\r")
    deadline = time.monotonic() + 8
    while b"unknown_program" not in output and time.monotonic() < deadline:
        ready, _, _ = select.select([master], [], [], 0.1)
        if ready:
            output.extend(os.read(master, 65536))
    check(b"PROGRAM / read_program" in output and b"unknown_program" in output,
          "in-TUI program read refuses an unknown id through the guarded tool, not the CLI")
    os.write(master, b"5")
    expect("stopped")
    check(b"RESIDENT" in output, "section 5 (Resident) reads back service/status.json")
    os.write(master, b"?")
    expect("Enter/x/E/R")
    os.write(master, b"1")
    expect("NEEDS ATTENTION")
    try:
        expect("FIRST RUN")
    except AssertionError:
        # A keystroke can race a full-screen redraw; re-select Overview once.
        os.write(master, b"1")
        expect("FIRST RUN")
    check(b"first run" in output.lower() or b"FIRST RUN" in output,
          "overview states first-run step when no device is selected")
    os.write(master, b"q")
    deadline = time.monotonic() + 5
    while process.poll() is None and time.monotonic() < deadline:
        ready, _, _ = select.select([master], [], [], 0.05)
        if ready:
            output.extend(os.read(master, 65536))
    check(process.wait(timeout=1) == 0, "numbered-section navigation quits cleanly")
    Path(".build/tui-sections.ansi").write_bytes(output)
finally:
    if process.poll() is None:
        process.terminate()
        deadline = time.monotonic() + 5
        while process.poll() is None and time.monotonic() < deadline:
            ready, _, _ = select.select([master], [], [], 0.05)
            if ready:
                try:
                    output.extend(os.read(master, 65536))
                except OSError:
                    break
        try:
            process.wait(timeout=2)
        except Exception:
            process.kill()
    os.close(master)
    os.close(slave)

fixture = Path(BIN).with_name("continuum-setup-test")
if fixture.exists():
    fixture_env = dict(ENV, MODEL_API_KEY="synthetic-private-fixture-key")
    result = subprocess.run([str(fixture.resolve()), "--discover-model"], env=fixture_env,
                            capture_output=True, text=True, timeout=10)
    check(result.returncode == 0, "Meta discovery executes and replays real receipts while rejecting malformed/mutating calls: " + result.stderr)
    report = json.loads(result.stdout)
    check(report["status"] == "completed" and report["model_calls"] == 4 and not report["network_changed"],
          "discovery finishes within its call budget without changing the network")
    check(report["tools"][0]["result"]["status"] == "rejected" and
          report["tools"][1]["result"]["provenance"] == "live_host" and
          report["tools"][2]["result"]["status"] == "rejected",
          "authored transport sees real discovery data and scope rejection, not canned success")
    Path(".build/discovery-acceptance.json").write_text(json.dumps({"transport": "authored_not_live_meta", "report": report}, indent=2) + "\n")

    # Exercise the UI -> child -> provider path too. An unrelated CLI model
    # override must not secretly replace the model shown/configured in the UI.
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
    fixture_env.update(TERM="xterm-256color", NO_COLOR="1", META_CONTROLLER_MODEL="wrong-cli-override",
                       CONTINUUM_FIXTURE_MODEL="fixture-controller", CONTINUUM_AGENT_FIXTURE="ui")
    fixture_env.pop("MODEL_API_KEY")
    process = subprocess.Popen([str(fixture.resolve()), "--tui"], stdin=slave, stdout=slave, stderr=slave, env=fixture_env)
    output = bytearray()
    try:
        expect("STEP 1 OF 8")
        os.write(master, b"a")
        expect("[m] Meta")
        check(b"not configured" in output.lower(), "new sessions show missing credentials, not a false connected state")
        os.write(master, b"a")
        expect("Set MODEL_API_KEY")
        os.write(master, b"m")
        expect("MODEL_API_KEY")
        long_key = b"synthetic-private-fixture-" + b"x" * 280
        os.write(master, long_key + b"\r")
        if sys.platform == "darwin":
            expect("Save in Keychain?")
            os.write(master, b"y")
            expect("Key saved in Keychain")
            check(long_key not in output, "long credentials round-trip through the fake secure-store seam without being printed")
        else:
            expect("Secure persistence unavailable")
            os.write(master, b"n")
            expect("session only")
            check(long_key not in output, "long session-only credentials remain private without claiming an OS secure store")
        os.write(master, b"m")
        expect("MODEL_API_KEY")
        os.write(master, b"\x1b")
        expect("Key entry cancelled")
        os.write(master, b"a")
        expect("Confirm Meta job")
        os.write(master, b"\r")
        expect("management identity remains unverified")
        check(b"Requested job completed." in output, "the completed Meta assessment is visible in the UI")
        os.write(master, b"t")
        expect("Message to Meta (no passwords)")
        os.write(master, b"Investigate without reboots\r")
        expect("Owner dialogue connected; no authority added.")
        check(not (Path(ENV["XDG_CONFIG_HOME"]) / "continuum/device/state.json").exists(),
              "owner conversation works without silently selecting a device or granting mutation authority")
        os.write(master, b"q")
        deadline = time.monotonic() + 5
        while process.poll() is None and time.monotonic() < deadline:
            ready, _, _ = select.select([master], [], [], 0.05)
            if ready:
                output.extend(os.read(master, 65536))
        check(process.wait(timeout=1) == 0, "confirmed Meta job uses the settings displayed by the TUI")
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=5)
        os.close(master)
        os.close(slave)

print("SETUP_TUI_ALL_GREEN")
