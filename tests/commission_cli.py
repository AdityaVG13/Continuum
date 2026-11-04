#!/usr/bin/env python3
"""Commissioning starts from an already enrolled router, not a second QIS run.

The oracle is a separate protected read from the C++ device double. Test-only
credentials stay in this process/environment; no real router or Keychain is used.
The transcript is retained under .build for repeatable acceptance evidence.
"""
import base64
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time
import urllib.parse
import urllib.request
import uuid

UA = "OpenAI File Downloader, XaiImageApiFetch/1.0"
ROOT = Path(__file__).resolve().parents[1]
PASSWORD = "CommissionTest12"
KEYS = ["productid", "x_Setting", "http_username", "wl0_ssid", "wan_proto",
        "enable_samba", "enable_ftp", "dms_enable", "daapd_enable", "enable_webdav",
        "sshd_enable", "sshd_port", "sshd_pass"]


def device_command():
    """Model only the router's nvram/service/id OS boundary, not the policy.

    The production-generated shell program really runs. /proc and /tmp paths
    are remapped by the fake host backend into this private fixture. These
    numbers are synthetic; this is not evidence of router memory/performance.
    """
    root = Path(os.environ["CT_COMMISSION_DEVICE_ROOT"])
    name = Path(sys.argv[0]).name
    args = sys.argv[1:]

    def nvram(fields=None, key=None):
        headers = {"User-Agent": UA, "Cookie": os.environ["CT_COMMISSION_DEVICE_COOKIE"]}
        port = os.environ["CT_COMMISSION_DEVICE_PORT"]
        if fields is None:
            query = urllib.parse.urlencode({"hook": f"nvram_get({key})"})
            req = urllib.request.Request(f"http://127.0.0.1:{port}/appGet.cgi?{query}", headers=headers)
        else:
            fields = dict(fields, action_mode="apply")
            req = urllib.request.Request(f"http://127.0.0.1:{port}/applyapp.cgi",
                data=urllib.parse.urlencode(fields).encode(), headers=headers)
        with urllib.request.urlopen(req, timeout=3) as response:
            data = json.load(response)
        return data.get(key, "") if key is not None else data

    if name == "reboot" and not args:
        assert (root / "committed").is_file(), "reboot must follow durable settings"
        (root / "proc/sys/kernel/random/boot_id").write_text("commission-test-" + uuid.uuid4().hex + "\n")
    elif name == "nohup":
        # The stock image need not provide this optional userspace applet.
        raise SystemExit(127)
    elif name == "id" and args == ["-u"]:
        raise SystemExit(127)  # Root evidence comes from the kernel, not an optional applet.
    elif name == "nvram" and len(args) == 2 and args[0] == "get":
        print(nvram(key=args[1]))
    elif name == "nvram" and len(args) == 2 and args[0] == "set":
        key, value = args[1].split("=", 1)
        nvram({key: value})
    elif name == "nvram" and args == ["commit"]:
        (root / "committed").write_text("committed\n")
    elif name == "service" and len(args) == 1:
        services = {
            "samba": ("enable_samba", ["smbd", "nmbd"]),
            "ftpd": ("enable_ftp", ["vsftpd"]),
            "dms": ("dms_enable", ["minidlna"]),
            "mt_daapd": ("daapd_enable", ["mt-daapd"]),
            "webdav": ("enable_webdav", ["lighttpd"]),
        }
        action, service = args[0].split("_", 1)
        if service == "sshd":
            return
        if service not in services and os.environ.get("CT_FOREIGN_DEVICE") == "1":
            return  # a declared device names its own services; nothing to model
        assert service in services and action in ("stop", "restart"), "unknown vendor service"
        key, names = services[service]
        enabled = action == "restart" and nvram(key=key) != "0"
        for process in (root / "proc").glob("[0-9]*"):
            intended = (process / "intended").read_text().strip()
            if intended in names:
                (process / "comm").write_text((intended if enabled else "stopped") + "\n")
    elif name == "tc":
        # Modeled kernel qdisc state, not synthetic timing numbers. The real
        # generated program runs; only the applet is substituted. Absence is
        # explicit data so the capability probe cannot masquerade as success.
        if os.environ.get("CT_COMMISSION_DEVICE_TC") == "absent":
            raise SystemExit(127)
        state = root / "qdisc-eth0"
        default = ("qdisc pfifo_fast 0: root refcnt 2 bands 3 "
                   "priomap 1 2 2 2 1 2 0 0 1 1 1 1 1 1 1 1\n")
        if args == ["-V"]:
            print("tc utility, iproute2-6.1.0")
        elif args[:3] == ["qdisc", "show", "dev"] and len(args) == 4:
            print(state.read_text() if state.is_file() else default, end="")
        elif args[:3] == ["qdisc", "replace", "dev"] and len(args) >= 5:
            assert args[3] == "eth0" and args[4] == "root", "unsupported modeled qdisc"
            spec = args[5:]
            if spec[:1] == ["cake"]:
                assert spec[1] == "bandwidth" and spec[3] == "overhead", spec
                assert spec[2].endswith("kbit"), spec
                rate = int(spec[2].removesuffix("kbit"))
                clamp = os.environ.get("CT_COMMISSION_DEVICE_QDISC_CLAMP")
                if clamp:
                    rate = min(rate, int(clamp))
                # tc prints rates with %g in the largest unit, so a 90000kbit
                # request reads back as "90Mbit"; the adapter must normalize.
                shown = (f"{rate / 1000:g}Mbit" if rate >= 1000 else f"{rate:g}Kbit")
                state.write_text(
                    "qdisc cake 8001: root refcnt 2 bandwidth " + shown +
                    " overhead " + spec[4] + " diffserv3 triple-isolate nonat\n")
            elif spec[:1] == ["fq_codel"]:
                assert spec[1] == "limit", spec
                state.write_text("qdisc fq_codel 8002: root refcnt 2 limit " + spec[2] +
                                 "p flows 1024 quantum 1514 target 5ms interval 100ms\n")
            else:
                raise AssertionError("unsupported modeled qdisc mode")
        elif args[:3] == ["qdisc", "del", "dev"] and len(args) == 5:
            assert args[3] == "eth0" and args[4] == "root"
            state.write_text(default)
        else:
            raise AssertionError("unsupported modeled tc command: " + repr(args))
    else:
        raise AssertionError("unsupported modeled device command")


def main():
    binary, double = (str(Path(p).resolve()) for p in sys.argv[1:3])
    directory = ROOT / ".build" / ("commission-e2e-" + uuid.uuid4().hex)
    directory.mkdir(mode=0o700)
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    server_env = dict(os.environ, ROUTER_PASSWORD="test-only-pw", ROUTER_WIZARD="1")
    log = (directory / "router.log").open("w")
    server = subprocess.Popen([double, str(port)], env=server_env, stdout=log, stderr=log)
    token = ""
    transcript = []

    def request(path, fields=None):
        data = None if fields is None else urllib.parse.urlencode(fields).encode()
        headers = {"User-Agent": UA}
        if token:
            headers["Cookie"] = token
        req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=data,
                                     headers=headers)
        with urllib.request.urlopen(req, timeout=4) as response:
            return response.read().decode(), response.headers.get("Set-Cookie", "")

    def read_device():
        hook = ";".join(f"nvram_get({key})" for key in KEYS)
        body, _ = request("/appGet.cgi?" + urllib.parse.urlencode({"hook": hook}))
        return json.loads(body)

    try:
        for _ in range(50):
            try:
                request("/api/status")
                break
            except OSError:
                if server.poll() is not None:
                    raise AssertionError("device double exited before readiness")
                time.sleep(0.02)
        else:
            raise AssertionError("device double did not become ready")
        request("/chpass.cgi", {
            "restart_httpd": "0", "defpass_enable": "0",
            "new_username": base64.b64encode(b"admin").decode(),
            "new_passwd": base64.b64encode(PASSWORD.encode()).decode(),
        })
        _, cookie = request("/login.cgi", {
            "login_authorization": base64.b64encode(("admin:" + PASSWORD).encode()).decode(),
        })
        token = cookie.split(";", 1)[0]
        assert token.startswith("asus_token="), "fixture must prove protected access"
        request("/applyapp.cgi", {
            "action_mode": "apply", "x_Setting": "1",
            "enable_samba": "1", "enable_ftp": "1", "dms_enable": "1",
            "daapd_enable": "0", "enable_webdav": "2",
            "firmver": "3.0.0.4", "buildno": "test", "extendno": "1",
            "lan_hwaddr": "02:00:00:00:00:01", "lan_ipaddr": "192.168.50.1",
            "lan_netmask": "255.255.255.0", "dhcp_enable_x": "1", "fw_enable_x": "1",
            "sshd_enable": "0", "sshd_port": "", "sshd_pass": "0",
        })
        before = read_device()
        env = dict(os.environ, ROUTER_HOST="127.0.0.1", ROUTER_PORT=str(port),
                   SSID_STEM="ExistingNetwork", ADMIN_REF="COMMISSION_ADMIN",
                   CONTINUUM_SECRET_COMMISSION_ADMIN=PASSWORD, CONTROL_RIDES_WIFI="0",
                   COMMISSION_ACTION="inspect", COMMISSION_DIR=str(directory / "state"))
        result = subprocess.run([binary], env=env, text=True, capture_output=True, timeout=15)
        transcript.append({"action": "inspect", "exit": result.returncode,
                           "stdout": result.stdout, "stderr": result.stderr})
        records = [json.loads(line) for line in result.stdout.splitlines()
                   if line.startswith("{")]
        assert result.returncode == 0 and records, (
            "an enrolled router must expose a protected commissioning inventory, "
            "not attempt QIS onboarding again: " + result.stdout + result.stderr)
        inventory = records[-1]
        assert inventory["phase"] == "inventory" and inventory["authenticated"] is True
        assert inventory["settings"]["enable_samba"] == "1"
        assert inventory["settings"]["enable_webdav"] == "2"
        # The device reports a classed capability graph as its own read-only
        # surface; the product's vocabulary is these classes, not its keys.
        graph_run = subprocess.run([binary], env=dict(env, COMMISSION_ACTION="capabilities"),
                                   text=True, capture_output=True, timeout=30)
        assert graph_run.returncode == 0, graph_run.stdout + graph_run.stderr
        graph = [json.loads(line) for line in graph_run.stdout.splitlines() if line.startswith("{")][-1]
        caps = {c["id"]: c for c in graph["capabilities"]}
        assert graph["phase"] == "capabilities" and graph["identity"]["productid"] == inventory["settings"]["productid"]
        assert caps["samba"]["class"] == "file_sharing" and caps["samba"]["settable"] is True
        assert caps["ftp"]["state"] == "enabled" and caps["samba"]["state"] == "enabled"
        assert caps["vendor_qos"]["class"] == "traffic_control" and caps["vendor_qos"]["settable"] is False
        assert caps["vendor_firmware"]["class"] == "update_channel" and caps["vendor_firmware"]["state"] == "present"
        assert caps["ssh"]["class"] == "remote_access" and caps["ssh"]["settable"] is False
        assert all(c["class"] in ("file_sharing", "media_server", "traffic_control", "remote_access", "update_channel")
                   for c in graph["capabilities"]), "capability classes are the closed product vocabulary"
        assert inventory["commissioned"] is False, "inventory is not commissioning"
        assert read_device() == before, "inspection must not change settings"
        assert PASSWORD not in result.stdout + result.stderr
        transcript.append({"assertions": "protected inventory; no mutation; no false readiness"})
        # A device that declares its own vocabulary gets the same lifecycle: the
        # manifest replaces the built-in table, so the graph must rename ids.
        manifest = directory / "declared.manifest"
        manifest.write_text(
            "smb file_sharing enable_samba 1 stop_samba restart_samba smbd nmbd\n"
            "ftpd file_sharing enable_ftp 1 stop_ftpd restart_ftpd vsftpd\n")
        declared = subprocess.run([binary], env=dict(env, COMMISSION_ACTION="capabilities",
                                                     CONTINUUM_CAPABILITY_MANIFEST=str(manifest)),
                                  text=True, capture_output=True, timeout=15)
        assert declared.returncode == 0 and '"smb"' in declared.stdout and '"samba"' not in declared.stdout, \
            "a declared manifest must replace the built-in capability vocabulary: " + declared.stdout
        without = subprocess.run([binary], env=dict(env, COMMISSION_ACTION="capabilities"),
                                 text=True, capture_output=True, timeout=15)
        assert '"samba"' in without.stdout and '"smb"' not in without.stdout, \
            "the built-in table must remain the default when no manifest is declared"
        print("COMMISSION_INSPECT_GREEN", directory)

        # One product executable must carry an owner-selected, observed target
        # into protected enrollment state; never adopt the host's other gateway.
        unified = str(Path(sys.argv[3]).resolve()) if len(sys.argv) > 3 else None
        integrated_env = dict(env, XDG_CONFIG_HOME=str(directory / "config"),
                              CONTINUUM_DEVICE_FIXTURE="1")
        state_path = directory / "config/continuum/device/state.json"
        connection = {}
        if unified:
            refused = subprocess.run([unified, "--device-select", "unobserved:10.0.0.1", "ExistingNetwork", str(port)],
                                     env=integrated_env, capture_output=True, text=True, timeout=10)
            assert refused.returncode != 0 and read_device() == before, "selection requires a current observed candidate"
            selected = subprocess.run([unified, "--device-select", "lo0:127.0.0.1", "ExistingNetwork", str(port), "--existing-credentials"],
                                      env=integrated_env, capture_output=True, text=True, timeout=10)
            assert selected.returncode == 0, "the main program must persist the owner's observed target: " + selected.stdout + selected.stderr
            state_path = directory / "config/continuum/device/state.json"
            selected_state = json.loads(state_path.read_text())
            assert selected_state["phase"] == "selected" and not selected_state["setup_approved"]
            assert selected_state["connection"]["host"] == "127.0.0.1" and selected_state["connection"]["port"] == port
            assert state_path.stat().st_mode & 0o077 == 0, "device handoff state must be private"
            connection = selected_state["connection"]
            for ref, secret in ((connection["admin_ref"], PASSWORD), (connection["psk_ref"], "FixtureWifi12345")):
                key = "CONTINUUM_SECRET_" + "".join(c.upper() if c.isalnum() else "_" for c in ref)
                integrated_env[key] = secret
            inspected = subprocess.run([unified, "--device-step", "inspect"], env=integrated_env,
                                       capture_output=True, text=True, timeout=15)
            assert inspected.returncode == 0, "an enrolled router must be adopted by protected inspection, not QIS replay: " + inspected.stdout
            adopted = json.loads(state_path.read_text())
            assert adopted["phase"] == "enrolled" and adopted["identity"]["productid"] == "RT-TEST"
            # The owner selects how far Continuum reaches, and a mode that is
            # not yet backed by a resident loop and a tested revocation cannot
            # be selected at all.
            takeover = subprocess.run([unified, "--device-mode", "takeover"], env=integrated_env,
                                      capture_output=True, text=True, timeout=10)
            assert takeover.returncode != 0 and "takeover_unavailable" in takeover.stdout, takeover.stdout
            assert json.loads(state_path.read_text()).get("ownership", "observer") == "observer", (
                "a refused mode change must not alter recorded ownership")
            selected_mode = subprocess.run([unified, "--device-mode", "operator"], env=integrated_env,
                                           capture_output=True, text=True, timeout=10)
            assert selected_mode.returncode == 0, selected_mode.stdout + selected_mode.stderr
            assert json.loads(state_path.read_text())["ownership"] == "operator"
            # A v1 state file predates ownership and must load as observer
            # rather than fail: migration may never erase a device binding.
            legacy = json.loads(state_path.read_text())
            legacy["schema_version"] = 1
            legacy.pop("ownership", None)
            state_path.write_text(json.dumps(legacy))
            status = subprocess.run([unified, "--device-status"], env=integrated_env,
                                    capture_output=True, text=True, timeout=10)
            assert status.returncode == 0 and '"ownership":"observer"' in status.stdout, (
                "a v1 state file must migrate to observer, not reject the binding: " + status.stdout)
            assert subprocess.run([unified, "--device-mode", "operator"], env=integrated_env,
                                  capture_output=True, text=True, timeout=10).returncode == 0
            denied = subprocess.run([unified, "--device-step", "setup"], env=integrated_env,
                                    capture_output=True, text=True, timeout=10)
            assert denied.returncode != 0 and read_device() == before, "setup needs explicit standing permission before any write"

        device = directory / "device"
        (device / "bin").mkdir(parents=True)
        (device / "tmp").mkdir()
        proc = device / "proc"
        (proc / "sys/kernel/random").mkdir(parents=True)
        (proc / "self").mkdir()
        (proc / "self/status").write_text("Name:\tsh\nUid:\t0\t0\t0\t0\n")
        (proc / "sys/kernel/random/boot_id").write_text("commission-test-boot\n")
        (proc / "meminfo").write_text("MemTotal: 524288 kB\nMemFree: 200000 kB\nMemAvailable: 300000 kB\n")
        (proc / "stat").write_text("cpu 100 0 100 1000 0 0 0 0\n")
        for pid, name, rss in [(101, "dnsmasq", 1024), (102, "httpd", 2048),
                (103, "smbd", 4096), (104, "nmbd", 512), (105, "vsftpd", 768),
                (106, "minidlna", 2048), (107, "lighttpd", 1024),
                (108, "vendor-worker", 3072)]:
            process = proc / str(pid)
            process.mkdir()
            (process / "comm").write_text(name + "\n")
            (process / "intended").write_text(name + "\n")
            (process / "status").write_text(f"Name:\t{name}\nVmRSS:\t{rss} kB\n")
        for command in ("nvram", "service", "id", "nohup", "reboot", "tc"):
            (device / "bin" / command).symlink_to(Path(__file__).resolve())
        request("/applyapp.cgi", {
            "firmver": "3.0.0.4", "buildno": "test", "extendno": "1",
            "lan_hwaddr": "02:00:00:00:00:01", "lan_ipaddr": "192.168.50.1",
            "lan_netmask": "255.255.255.0", "dhcp_enable_x": "1", "fw_enable_x": "1",
            "sshd_enable": "0", "sshd_port": "", "sshd_pass": "0",
        })
        before = read_device()
        private_home = directory / "home"
        private_home.mkdir(mode=0o700)
        env.update(CT_COMMISSION_DEVICE_ROOT=str(device), CT_COMMISSION_DEVICE_PORT=str(port),
                   CT_COMMISSION_DEVICE_COOKIE=token, COMMISSION_ACTION="apply",
                   COMMISSION_DISABLE="samba,ftp,dlna,daap,webdav",
                   COMMISSION_DIR="", HOME=str(private_home))
        denied = subprocess.run([binary], env=env, text=True, capture_output=True, timeout=15)
        assert denied.returncode != 0 and read_device() == before, "apply requires standing execute permission"
        unknown = subprocess.run([binary], env=dict(env, COMMISSION_DISABLE="telnet", COMMISSION_EXECUTE="1"),
                                 text=True, capture_output=True, timeout=30)
        assert unknown.returncode != 0 and "capability_unknown" in unknown.stdout, \
            "the adapter must refuse a capability id it never advertised"
        assert read_device() == before, "a refused capability selection cannot touch the device"
        env["COMMISSION_EXECUTE"] = "1"
        applied = subprocess.run([binary], env=env, text=True, capture_output=True, timeout=90)
        transcript.append({"action": "apply", "exit": applied.returncode,
                           "stdout": applied.stdout, "stderr": applied.stderr})
        assert applied.returncode == 0, "approved commissioning must execute, not report a plan: " + applied.stdout + applied.stderr
        records = [json.loads(line) for line in applied.stdout.splitlines() if line.startswith("{")]
        receipt = records[-1]
        assert receipt["phase"] == "baseline_applied" and receipt["runtime_verified"] is True
        assert receipt["recovery_verified"] is True, "device-local expiry must actually restore a trial"
        assert receipt["persistent_settings_written"] is True
        assert receipt["persistence_verified"] is False and receipt["commissioned"] is False
        state_directory = Path(receipt["state_directory"])
        assert state_directory.parent == private_home, "setup must choose a private owner recovery directory automatically"
        env["COMMISSION_DIR"] = str(state_directory)
        after = read_device()
        for key in ("enable_samba", "enable_ftp", "dms_enable", "enable_webdav"):
            assert after[key] == "0", "approved optional service must stay disabled: " + key
        for key in ("productid", "x_Setting", "http_username", "wl0_ssid", "wan_proto"):
            assert after[key] == before[key], "cleanup must preserve core settings: " + key
        assert ",vendor-worker," in (state_directory / "runtime-before.txt").read_text(), (
            "runtime inventory must expose other resource owners, not only the cleanup allowlist")
        assert ",smbd," not in (Path(env["COMMISSION_DIR"]) / "runtime-after.txt").read_text()
        assert PASSWORD not in applied.stdout + applied.stderr
        assert (Path(env["COMMISSION_DIR"]) / "baseline.json").stat().st_mode & 0o077 == 0
        same_boot = subprocess.run([binary], env=dict(env, COMMISSION_ACTION="verify"),
                                   text=True, capture_output=True, timeout=60)
        assert same_boot.returncode != 0 and read_device() == after, "same-boot readback cannot certify persistence"
        denied_reboot = subprocess.run([binary], env=dict(env, COMMISSION_ACTION="reboot", COMMISSION_EXECUTE="0"),
                                       text=True, capture_output=True, timeout=15)
        assert denied_reboot.returncode != 0 and read_device() == after, "reboot needs standing disruption permission"
        boot_before_approval = (proc / "sys/kernel/random/boot_id").read_text()
        broad_permission = subprocess.run([binary], env=dict(env, COMMISSION_ACTION="reboot"),
                                          text=True, capture_output=True, timeout=15)
        assert broad_permission.returncode != 0 and "owner_reboot_approval_required" in broad_permission.stdout, (
            "standing setup permission must NOT authorize a router reboot: " + broad_permission.stdout)
        assert (proc / "sys/kernel/random/boot_id").read_text() == boot_before_approval
        reboot = subprocess.run([binary], env=dict(env, COMMISSION_ACTION="reboot", COMMISSION_APPROVE_REBOOT="1"),
                                text=True, capture_output=True, timeout=60)
        transcript.append({"action": "reboot", "exit": reboot.returncode,
                           "stdout": reboot.stdout, "stderr": reboot.stderr})
        assert reboot.returncode == 0, "an approved baseline reboot must execute: " + reboot.stdout + reboot.stderr
        assert json.loads(reboot.stdout.splitlines()[-1])["phase"] == "reboot_requested"
        boot_file = proc / "sys/kernel/random/boot_id"
        for _ in range(100):
            if boot_file.read_text().strip() != "commission-test-boot":
                break
            time.sleep(0.1)
        else:
            raise AssertionError("the generated program must actually request a device reboot")
        failed_rejoin = subprocess.run([binary],
            env=dict(env, COMMISSION_ACTION="verify", CONTROL_RIDES_WIFI="1"),
            text=True, capture_output=True, timeout=60)
        assert failed_rejoin.returncode != 0 and read_device() == after, (
            "verification after roaming must require a successful rejoin before accessing the device")
        verified = subprocess.run([binary], env=dict(env, COMMISSION_ACTION="verify",
                                  CONTROL_RIDES_WIFI="1", CT_TEST_REJOIN="1"),
                                  text=True, capture_output=True, timeout=60)
        transcript.append({"action": "verify", "exit": verified.returncode,
                           "stdout": verified.stdout, "stderr": verified.stderr})
        assert verified.returncode == 0, "persistence requires a changed boot and preserved lean settings: " + verified.stdout + verified.stderr
        proof = json.loads(verified.stdout.splitlines()[-1])
        assert proof["persistence_verified"] is True and proof["commissioned"] is False
        assert proof["network_load_verified"] is False and read_device() == after
        request("/applyapp.cgi", {"enable_samba": "1"})
        changed = subprocess.run([binary], env=dict(env, COMMISSION_ACTION="verify"),
                                 text=True, capture_output=True, timeout=60)
        assert changed.returncode != 0 and read_device()["enable_samba"] == "1", "a changed boot alone cannot certify a regressed baseline"
        request("/applyapp.cgi", {"enable_samba": "0"})
        restored = subprocess.run([binary], env=dict(env, COMMISSION_ACTION="restore"),
                                  text=True, capture_output=True, timeout=60)
        transcript.append({"action": "restore", "exit": restored.returncode,
                           "stdout": restored.stdout, "stderr": restored.stderr})
        assert restored.returncode == 0 and read_device() == before, "restore must recover the exact prior service flags"
        runtime = subprocess.run([binary], env=dict(env, COMMISSION_ACTION="runtime"),
                                 text=True, capture_output=True, timeout=60)
        assert runtime.returncode == 0, "a commissioned target needs a safe full-runtime inspection: " + runtime.stdout + runtime.stderr
        runtime_receipt = [json.loads(line) for line in runtime.stdout.splitlines() if line.startswith("{")][-1]
        assert runtime_receipt["phase"] == "runtime_inventory"
        assert ",vendor-worker," in Path(runtime_receipt["runtime_path"]).read_text()
        assert read_device() == before, "runtime inspection must restore management access and leave feature settings alone"
        retained_files = {p.name for p in state_directory.iterdir()}
        immutable_baseline = (state_directory / "baseline.json").read_bytes()
        repeated = subprocess.run([binary], env=dict(env, COMMISSION_ACTION="runtime"),
                                  text=True, capture_output=True, timeout=60)
        assert repeated.returncode == 0, repeated.stdout + repeated.stderr
        assert {p.name for p in state_directory.iterdir()} == retained_files, (
            "recurring inventories must replace bounded observations, not accumulate snapshot files")
        latest = json.loads((state_directory / "events.jsonl").read_text())
        assert latest["phase"] == "runtime_inventory" and latest["runtime_path"] == runtime_receipt["runtime_path"]
        assert (state_directory / "baseline.json").read_bytes() == immutable_baseline, (
            "retiring observation history must never replace an immutable recovery baseline")
        assert read_device() == before
        transcript.append({"action": "bounded_runtime_retention", "files": sorted(retained_files),
                           "latest_receipt": latest})

        # QoS: the device's own `tc qdisc show` readback is the proof. A missing
        # tc applet is a typed refusal (no mutation), and restore must return
        # the interface to its kernel-default root qdisc.
        qos = dict(env, COMMISSION_ACTION="qos", COMMISSION_QOS_OP="apply",
                   COMMISSION_QOS_IFACE="eth0", COMMISSION_QOS_MODE="cake",
                   COMMISSION_QOS_KBPS="90000", COMMISSION_QOS_OVERHEAD="18")
        absent = subprocess.run([binary], env=dict(qos, CT_COMMISSION_DEVICE_TC="absent"),
                                text=True, capture_output=True, timeout=60)
        assert absent.returncode != 0 and "qdisc_tool_unavailable" in absent.stdout, (
            "a device without tc must refuse the qdisc profile: " + absent.stdout + absent.stderr)
        assert not (device / "qdisc-eth0").exists(), "an unavailable tc must not write a qdisc"
        # A root managed by vendor QoS or another agent is refused, not stomped.
        (device / "qdisc-eth0").write_text("qdisc htb 1: root refcnt 2 r2q 10\n")
        foreign = subprocess.run([binary], env=qos, text=True, capture_output=True, timeout=60)
        assert foreign.returncode != 0 and "qdisc_root_already_managed" in foreign.stdout, (
            "a foreign managed root must be refused: " + foreign.stdout + foreign.stderr)
        assert (device / "qdisc-eth0").read_text().startswith("qdisc htb"), (
            "a refused profile must not touch the managed root")
        (device / "qdisc-eth0").write_text(
            "qdisc pfifo_fast 0: root refcnt 2 bands 3\n")
        applied_qos = subprocess.run([binary], env=qos, text=True, capture_output=True, timeout=60)
        assert applied_qos.returncode == 0, applied_qos.stdout + applied_qos.stderr
        qos_receipt = [json.loads(line) for line in applied_qos.stdout.splitlines()
                       if line.startswith("{")][-1]
        assert qos_receipt["phase"] == "qos_applied" and qos_receipt["qos_verified"] is True
        assert qos_receipt["qos_mode"] == "cake" and qos_receipt["bandwidth_kbps"] == 90000
        assert qos_receipt["rate_readback"] == "verified"
        qdisc_text = (device / "qdisc-eth0").read_text()
        assert "cake" in qdisc_text and "bandwidth 90Mbit" in qdisc_text and "overhead 18" in qdisc_text
        assert read_device() == before, "a qdisc profile must not rewrite service flags"
        for bad, reason in (({"COMMISSION_QOS_KBPS": "100001"}, "qos_bandwidth_out_of_range"),
                            ({"COMMISSION_QOS_IFACE": "lan0"}, "qos_interface_unsupported"),
                            ({"COMMISSION_QOS_MODE": "sfq"}, "qos_mode_unsupported"),
                            ({"COMMISSION_QOS_OVERHEAD": "201"}, "qos_overhead_out_of_range")):
            refused_qos = subprocess.run([binary], env=dict(qos, **bad),
                                         text=True, capture_output=True, timeout=30)
            assert refused_qos.returncode != 0 and reason in refused_qos.stdout, (
                reason + ": " + refused_qos.stdout + refused_qos.stderr)
            assert (device / "qdisc-eth0").read_text() == qdisc_text, (
                "an invalid profile must be refused before any device I/O")
        # The device may not honor the requested rate (line-rate clamp). An
        # adapter that echoes its own request instead of reading the device
        # would report success here.
        clamped = subprocess.run([binary], env=dict(qos, CT_COMMISSION_DEVICE_QDISC_CLAMP="50000"),
                                 text=True, capture_output=True, timeout=60)
        assert clamped.returncode != 0 and "qos_rate_readback_mismatch" in clamped.stdout, (
            "an unhonored rate must fail the readback: " + clamped.stdout + clamped.stderr)
        assert (device / "qdisc-eth0").read_text().startswith("qdisc pfifo_fast"), (
            "an unverified qdisc must be rolled back to the kernel default")
        fq = subprocess.run([binary], env=dict(qos, COMMISSION_QOS_MODE="fq_codel",
                                               COMMISSION_QOS_KBPS="80000"),
                            text=True, capture_output=True, timeout=60)
        assert fq.returncode == 0, fq.stdout + fq.stderr
        assert "fq_codel" in (device / "qdisc-eth0").read_text()
        restored_qos = subprocess.run([binary], env=dict(qos, COMMISSION_QOS_OP="restore"),
                                      text=True, capture_output=True, timeout=60)
        assert restored_qos.returncode == 0, restored_qos.stdout + restored_qos.stderr
        restore_receipt = [json.loads(line) for line in restored_qos.stdout.splitlines()
                           if line.startswith("{")][-1]
        assert restore_receipt["phase"] == "qos_restored" and restore_receipt["qos_verified"] is True
        assert (device / "qdisc-eth0").read_text().startswith("qdisc pfifo_fast"), (
            "restore must return the interface to its kernel-default root qdisc")
        idle = subprocess.run([binary], env=dict(qos, COMMISSION_QOS_OP="restore"),
                              text=True, capture_output=True, timeout=60)
        assert idle.returncode == 0, idle.stdout + idle.stderr
        idle_receipt = [json.loads(line) for line in idle.stdout.splitlines()
                        if line.startswith("{")][-1]
        assert idle_receipt["changed"] is False, "a repeated restore must be idempotent"
        assert read_device() == before
        transcript.append({"action": "qos_apply_restore", "apply": qos_receipt,
                           "restore": restore_receipt, "idle": idle_receipt})
        # A device that declares a different vocabulary is managed by the same
        # binary: the manifest replaces the adapter's table, and the whole
        # reversible transaction runs against that device's own settings.
        foreign_keys = ["enable_nfs", "plex_enable", "afp_enable"]
        request("/applyapp.cgi", {"action_mode": "apply", "enable_nfs": "1",
                                  "plex_enable": "1", "afp_enable": "1"})

        def read_keys(keys):
            hook = ";".join(f"nvram_get({key})" for key in keys)
            body, _ = request("/appGet.cgi?" + urllib.parse.urlencode({"hook": hook}))
            return json.loads(body)

        assert read_keys(foreign_keys) == dict.fromkeys(foreign_keys, "1")
        foreign_manifest = directory / "declared.manifest"
        foreign_manifest.write_text(
            "nfs file_sharing enable_nfs 1 stop_nfs restart_nfs nfsd\n"
            "plex media_server plex_enable 1 stop_plex restart_plex plexmediaserver\n"
            "afp file_sharing afp_enable 1 stop_afp restart_afp netatalk\n")
        foreign_env = dict(env, CONTINUUM_CAPABILITY_MANIFEST=str(foreign_manifest),
                           CT_FOREIGN_DEVICE="1", COMMISSION_ACTION="capabilities")
        graph = subprocess.run([binary], env=foreign_env, text=True, capture_output=True, timeout=15)
        assert graph.returncode == 0 and '"nfs"' in graph.stdout and '"samba"' not in graph.stdout, (
            "the declared device's graph must replace the built-in vocabulary: " + graph.stdout)
        foreign_home = directory / "foreign-home"
        foreign_home.mkdir(mode=0o700)
        foreign_run = dict(foreign_env, COMMISSION_ACTION="apply", COMMISSION_DISABLE="nfs,plex",
                           COMMISSION_EXECUTE="1", COMMISSION_DIR="", HOME=str(foreign_home))
        foreign_apply = subprocess.run([binary], env=foreign_run, text=True, capture_output=True, timeout=90)
        assert foreign_apply.returncode == 0, foreign_apply.stdout + foreign_apply.stderr
        foreign_receipt = [json.loads(line) for line in foreign_apply.stdout.splitlines()
                           if line.startswith("{")][-1]
        assert foreign_receipt["phase"] == "baseline_applied"
        foreign_after = read_keys(foreign_keys)
        assert foreign_after["enable_nfs"] == "0" and foreign_after["plex_enable"] == "0", foreign_after
        assert foreign_after["afp_enable"] == "1", "only the declared selection may change"
        foreign_restore = subprocess.run([binary], env=dict(foreign_run, COMMISSION_ACTION="restore",
                                                            COMMISSION_DIR=foreign_receipt["state_directory"]),
                                         text=True, capture_output=True, timeout=60)
        assert foreign_restore.returncode == 0, foreign_restore.stdout + foreign_restore.stderr
        foreign_restored = read_keys(foreign_keys)
        assert foreign_restored == dict.fromkeys(foreign_keys, "1"), (
            "a declared device must restore its own baseline through the same transaction: "
            + json.dumps(foreign_restored))
        transcript.append({"action": "declared_device", "graph": graph.stdout,
                           "apply": foreign_receipt, "restored": foreign_restored})
        print("COMMISSION_QOS_GREEN", directory)
        print("COMMISSION_APPLY_RESTORE_GREEN", directory)
        if unified:
            integrated_env.update(CT_COMMISSION_DEVICE_ROOT=str(device), CT_COMMISSION_DEVICE_PORT=str(port),
                                  CT_COMMISSION_DEVICE_COOKIE=token)
            config = directory / "config/continuum"
            (config / "settings.json").write_text(json.dumps(dict(controller_model="fixture-controller",
                task_model="fixture-workload", max_output_tokens=512, max_tool_rounds=8, request_timeout_ms=3000)))
            integrated_env.update(MODEL_API_KEY="synthetic-private-device-key", CONTINUUM_AGENT_FIXTURE="commission")
            boot_before_setup = (proc / "sys/kernel/random/boot_id").read_text()
            setup = subprocess.run([unified, "--device-step", "setup", "--execute"], env=integrated_env,
                                   capture_output=True, text=True, timeout=120)
            transcript.append({"action": "integrated_setup", "exit": setup.returncode, "stdout": setup.stdout, "stderr": setup.stderr})
            assert setup.returncode == 0, "setup must be directed by Meta, not a deterministic commissioning/reboot recipe: " + setup.stdout + setup.stderr
            report = json.loads(setup.stdout)
            assert report["status"] == "completed" and report["model_calls"] == 5
            pending = json.loads(state_path.read_text())
            assert pending["phase"] == "baseline_applied" and pending["setup_approved"]
            assert pending["ownership"] == "operator", "owner-selected reach must survive the whole lifecycle"
            assert pending["runtime_verified"] and pending["recovery_verified"] and not pending["persistence_verified"]
            assert read_device()["enable_samba"] == "0" and read_device()["enable_ftp"] == "1", "only the model-selected service may change"
            assert (proc / "sys/kernel/random/boot_id").read_text() == boot_before_setup, "neither standing setup nor a model reboot request grants reboot authority"
            assert not pending["network_load_verified"] and not pending["ready"], "a model conclusion cannot manufacture qualification"
            assert pending["knowledge"] == "Owner uses FTP; keep it enabled."

            chat = subprocess.run([unified, "--talk", "Keep FTP enabled. What changed?"],
                                  env=dict(integrated_env, CONTINUUM_AGENT_FIXTURE="chat"),
                                  capture_output=True, text=True, timeout=15)
            assert chat.returncode == 0 and json.loads(chat.stdout)["summary"] == "FTP retained; no router reboot.", "owner dialogue must reuse the selected device's persisted knowledge and previous exchange: " + chat.stdout + chat.stderr

            # The same guarded dispatcher applies a bounded qdisc profile and
            # restores it: model proposal -> Goose bounds -> owner grant ->
            # native tc command -> device readback -> restore. This runs after
            # the dialogue check because it becomes the newest exchange.
            after_setup = read_device()
            qos_talk = subprocess.run([unified, "--talk", "Apply a CAKE profile to the WAN and verify it."],
                env=dict(integrated_env, CONTINUUM_AGENT_FIXTURE="qos"),
                capture_output=True, text=True, timeout=180)
            assert qos_talk.returncode == 0, (
                "Meta must be able to apply and restore a verified qdisc profile: " +
                qos_talk.stdout + qos_talk.stderr)
            qos_report = json.loads(qos_talk.stdout)
            assert qos_report["status"] == "completed" and qos_report["model_calls"] == 3
            assert qos_report["mutation_attempted"] is True
            assert (device / "qdisc-eth0").read_text().startswith("qdisc pfifo_fast"), (
                "the model-driven restore must leave the kernel-default root qdisc")
            qos_record = json.loads(next((directory / "config").glob("**/qos-last.json")).read_text())
            assert qos_record["phase"] == "qos_restored" and qos_record["changed"] is True, (
                "the qdisc record must survive as durable evidence, not only in the model transcript")
            assert read_device() == after_setup, "qos must not rewrite service flags"
            transcript.append({"action": "integrated_qos", "report": qos_report})

            # Programs must run through the real dispatcher without a model call,
            # survive process boundaries, and never smuggle reboot/shell authority.
            def program_tool(operation, payload, expected):
                authored = dict(integrated_env, CONTINUUM_AGENT_FIXTURE="program",
                    CONTINUUM_PROGRAM_OPERATION=operation,
                    CONTINUUM_PROGRAM_PAYLOAD=json.dumps(payload) if not isinstance(payload, str) else payload,
                    CONTINUUM_PROGRAM_EXPECT=expected)
                result = subprocess.run([unified, "--talk", "Manage the bounded maintenance program."],
                    env=authored, capture_output=True, text=True, timeout=30)
                assert result.returncode == 0, "program tool must execute and replay a real receipt: " + result.stdout + result.stderr
                return json.loads(result.stdout)

            # Owner policy must constrain the same real dispatcher used by
            # Meta and programs, not merely add instructions to its prompt.
            owner = subprocess.run([unified, "--owner-policy"], env=integrated_env,
                capture_output=True, text=True, timeout=10)
            assert owner.returncode == 0, "the owner must be able to inspect and configure authority without Meta: " + owner.stdout
            defaults = json.loads(owner.stdout)

            def set_policy(policy):
                result = subprocess.run([unified, "--owner-policy-set", json.dumps(policy)],
                    env=integrated_env, capture_output=True, text=True, timeout=10)
                assert result.returncode == 0, "owner policy must be durable: " + result.stdout + result.stderr
                assert json.loads(result.stdout) == policy

            set_policy(dict(defaults, allowed_operations=[]))
            before_denial = read_device()
            program_tool("runtime", "", "owner_policy_denied")
            assert read_device() == before_denial, "a denied model request must not reach the device"
            protected = dict(defaults, protected_clients=["workstation-must-stay-connected"])
            set_policy(protected)
            refused_reboot = subprocess.run([unified, "--device-step", "reboot", "--execute"],
                env=integrated_env, capture_output=True, text=True, timeout=10)
            assert refused_reboot.returncode != 0 and "protected_connectivity_unverified" in refused_reboot.stdout, "even an approved operation must honor the owner's protected-user constraint"
            assert (proc / "sys/kernel/random/boot_id").read_text() == boot_before_setup
            set_policy(dict(defaults, protected_services=["ftp"]))
            program_tool("apply", json.dumps({"disable": ["ftp"]}), "protected_service_required")
            assert read_device() == before_denial
            set_policy(defaults)
            transcript.append({"action": "owner_policy", "denied_reboot": refused_reboot.stdout,
                               "protected_clients": protected["protected_clients"]})

            program_id = "architecture-audit"
            spec = dict(id=program_id, purpose="Observe host and selected router without inference.",
                interval_ms=60000, steps=[dict(operation="sample_host", payload=""),
                                         dict(operation="inspect", payload="")])
            program_tool("install_program", spec, "installed")
            registry_path = config / "device/programs.json"
            assert registry_path.is_file(), "an acknowledged install must create the durable program registry"
            registry = json.loads(registry_path.read_text())
            assert len(registry["programs"]) == 1 and registry_path.stat().st_mode & 0o077 == 0
            assert registry["programs"][0]["mac"] == pending["identity"]["mac"], "installation binds actual authenticated identity, not model assertions"
            no_model = dict(integrated_env)
            no_model.pop("MODEL_API_KEY", None)
            run = subprocess.run([unified, "--program-run", program_id], env=no_model,
                capture_output=True, text=True, timeout=30)
            assert run.returncode == 0, "an installed mini-program must execute without Meta: " + run.stdout + run.stderr
            result = json.loads(run.stdout)
            assert result["status"] == "completed" and result["steps_completed"] == 2
            assert "authored_host_fixture" in json.dumps(result) and "RT-TEST" in json.dumps(result)
            assert read_device()["enable_ftp"] == "1" and (proc / "sys/kernel/random/boot_id").read_text() == boot_before_setup
            for op in ("reboot", "reset", "firmware", "shell", "install_program"):
                bad = dict(spec, id="forbidden-" + op, steps=[dict(operation=op, payload="")])
                program_tool("install_program", bad, "unsupported_program_step")
            assert len(json.loads(registry_path.read_text())["programs"]) == 1, "refused installs must not alter existing programs"
            for invalid in (dict(spec, interval_ms=1), dict(spec, steps=spec["steps"] * 3),
                            dict(spec, purpose="p" * 257)):
                program_tool("install_program", invalid, "program_resource_bounds")
            program_tool("install_program", spec, "program_slot_exhausted_or_id_exists")
            # Force a due reservation using the real persisted scheduler state;
            # restart twice to distinguish durable timing from a process timer.
            registry = json.loads(registry_path.read_text())
            registry["programs"][0]["last_attempt_wall_ms"] = 0
            registry_path.write_text(json.dumps(registry))
            service_settings = dict(sample_interval_ms=1000, incident_cooldown_ms=60000,
                                    max_calls_per_hour=1, allow_meta=False)
            (config / "service.json").write_text(json.dumps(service_settings))
            (config / "service.json").chmod(0o600)
            scheduled = {}
            for repeat in range(2):
                served = subprocess.run([unified, "--serve", "1"], env=no_model, capture_output=True, text=True, timeout=30)
                assert served.returncode == 0, "the resident must run due installed programs without Meta permission: " + served.stdout + served.stderr
                scheduled = json.loads(registry_path.read_text())["programs"][0]
                assert scheduled["runs"] == 2 and scheduled["status"] == "completed", "durable due-time reservation prevents restart replay"
                assert json.loads((config / "service/status.json").read_text())["model_calls_this_hour"] == 0
            # An interrupted effect is never replayed just because the host restarted.
            registry = json.loads(registry_path.read_text())
            registry["programs"][0].update(status="running", last_attempt_wall_ms=0)
            registry_path.write_text(json.dumps(registry))
            interrupted = subprocess.run([unified, "--program-run", program_id], env=no_model, capture_output=True, text=True, timeout=10)
            assert interrupted.returncode != 0 and "program_reconciliation_required" in interrupted.stdout
            program_tool("reconcile_program", program_id, "reconciled")
            # Current firmware, not the old stored IP, controls execution.
            request("/applyapp.cgi", {"extendno": "changed"})
            wrong = subprocess.run([unified, "--program-run", program_id], env=no_model, capture_output=True, text=True, timeout=10)
            assert wrong.returncode != 0 and "device_identity_changed" in wrong.stdout
            request("/applyapp.cgi", {"extendno": "1"})
            # The resident loop is proven by revoking it while an effect is
            # live: the owner drops reach, the loop must restore what it owns,
            # and only that artifact makes takeover selectable.
            drill_state = directory / "config/continuum/device/takeover-drill.state"
            drill_path = directory / "config/continuum/device/takeover-drill.json"
            if drill_state.exists():
                drill_state.unlink()
            if drill_path.exists():
                drill_path.unlink()
            # The optimization effect gets a read-only preflight: the owner can
            # learn whether this unit can host a qdisc before committing to a
            # window, and the read changes nothing.
            qos_preflight = subprocess.run([unified, "--device-step", "qos-status"], env=no_model,
                capture_output=True, text=True, timeout=60)
            assert qos_preflight.returncode == 0, qos_preflight.stdout + qos_preflight.stderr
            assert '"qdisc_tool":"present"' in qos_preflight.stdout, qos_preflight.stdout
            assert '"changed":false' in qos_preflight.stdout and '"qdisc":' in qos_preflight.stdout, qos_preflight.stdout
            # The owner can apply and undo the qdisc without a provider call, so
            # a lab A/B is not a paid-model measurement.
            profile = json.dumps({"bandwidth_kbps": 100000, "interface": "eth0",
                                  "mode": "cake", "overhead_bytes": 0})
            qos_applied = subprocess.run([unified, "--device-qos", profile, "--execute"], env=no_model,
                capture_output=True, text=True, timeout=120)
            assert qos_applied.returncode == 0 and '"phase":"qos_applied"' in qos_applied.stdout, qos_applied.stdout
            assert '"rate_readback":"verified"' in qos_applied.stdout, qos_applied.stdout
            qos_undone = subprocess.run([unified, "--device-qos-restore", "--execute"], env=no_model,
                capture_output=True, text=True, timeout=120)
            assert qos_undone.returncode == 0 and '"phase":"qos_restored"' in qos_undone.stdout, qos_undone.stdout
            reconciled = subprocess.run([unified, "--device-step", "restore", "--execute"], env=no_model,
                capture_output=True, text=True, timeout=60)
            assert reconciled.returncode == 0, "the drill starts from a reconciled baseline: " + reconciled.stdout
            before_drill = read_device()
            drill = subprocess.Popen([unified, "--takeover-drill"], env=no_model,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            deadline = time.time() + 180
            while drill.poll() is None and time.time() < deadline:
                if drill_state.exists() and "applied=yes" in drill_state.read_text():
                    break
                time.sleep(0.2)
            if not drill_state.exists() or "applied=yes" not in drill_state.read_text():
                output, _ = drill.communicate(timeout=60)
                raise AssertionError("the loop must apply before revocation can be tested: "
                    + (drill_state.read_text() if drill_state.exists() else "no progress record") + output)
            lowered = subprocess.run([unified, "--device-mode", "observer"], env=no_model,
                capture_output=True, text=True, timeout=10)
            if lowered.returncode != 0:
                # The loop reads the binding between cycles; the owner's write
                # may land in one of those short windows. Retry like an owner.
                deadline = time.time() + 30
                while lowered.returncode != 0 and time.time() < deadline:
                    time.sleep(0.2)
                    lowered = subprocess.run([unified, "--device-mode", "observer"], env=no_model,
                        capture_output=True, text=True, timeout=10)
            assert lowered.returncode == 0, lowered.stdout
            output, _ = drill.communicate(timeout=300)
            assert drill.returncode == 0, output
            artifact = json.loads(drill_path.read_text())
            assert artifact["revoked"] and artifact["restored"], artifact
            assert artifact["calls_after_revoke"] == 0 and artifact["cycles"] >= 1 and artifact["effects"] >= 1, artifact
            assert read_device() == before_drill, "the revoked loop must leave the device at its owned baseline"
            assert json.loads(state_path.read_text())["ownership"] == "observer"
            reopened = subprocess.run([unified, "--device-mode", "takeover"], env=no_model,
                capture_output=True, text=True, timeout=10)
            assert reopened.returncode == 0 and "DEVICE_MODE takeover" in reopened.stdout, \
                "a passed drill for this device is what makes takeover selectable: " + reopened.stdout
            assert subprocess.run([unified, "--device-mode", "operator"], env=no_model,
                capture_output=True, text=True, timeout=10).returncode == 0
            revoked = subprocess.run([unified, "--device-step", "revoke", "--execute"], env=no_model, capture_output=True, text=True, timeout=10)
            assert revoked.returncode == 0 and not json.loads(state_path.read_text())["setup_approved"]
            denied_run = subprocess.run([unified, "--program-run", program_id], env=no_model, capture_output=True, text=True, timeout=10)
            assert denied_run.returncode != 0 and "standing_device_permission_required" in denied_run.stdout
            paused = subprocess.run([unified, "--program-disable", program_id], env=no_model,
                capture_output=True, text=True, timeout=10)
            assert paused.returncode == 0 and not json.loads(registry_path.read_text())["programs"][0]["enabled"], "the owner must be able to disable local programs after revoking device authority"
            detail = subprocess.run([unified, "--program-read", program_id], env=no_model,
                capture_output=True, text=True, timeout=10)
            assert detail.returncode == 0 and json.loads(detail.stdout)["id"] == program_id, "revoking effects must not hide the program's result from its owner"
            # Restore the owner's grant for the existing resident/restore cases;
            # the test, not a model tool, controls this private fixture's authority.
            fixture_state = json.loads(state_path.read_text())
            fixture_state["setup_approved"] = True
            state_path.write_text(json.dumps(fixture_state))
            # Exercise an actual effect, not only observational receipts. The
            # same guardian restores the old baseline, then disables only FTP.
            trial_id = "maintenance-trial"
            trial = dict(id=trial_id, purpose="Verify a reversible FTP-only change.", interval_ms=0,
                steps=[dict(operation="restore", payload=""), dict(operation="apply", payload=json.dumps(
                    {"disable": ["ftp"]}))])
            program_tool("install_program", trial, "installed")
            effected = subprocess.run([unified, "--program-run", trial_id], env=no_model,
                capture_output=True, text=True, timeout=90)
            assert effected.returncode == 0 and json.loads(effected.stdout)["mutation_attempted"], "a program must execute the real guarded transaction: " + effected.stdout + effected.stderr
            assert read_device()["enable_ftp"] == "0" and read_device()["enable_samba"] == "1", "the independent device read must reflect exactly the program-selected service change"
            registry = json.loads(registry_path.read_text())
            registry["programs"][1]["status"] = "running"
            registry_path.write_text(json.dumps(registry))
            blocked = subprocess.run([unified, "--program-reconcile", trial_id], env=no_model,
                capture_output=True, text=True, timeout=10)
            assert blocked.returncode != 0 and "restore_owned_baseline_before_reconciliation" in blocked.stdout, "a fresh inventory cannot reconcile an effectful program's owned baseline"
            restored_program = subprocess.run([unified, "--device-step", "restore", "--execute"], env=no_model,
                capture_output=True, text=True, timeout=60)
            assert restored_program.returncode == 0 and read_device()["enable_ftp"] == "1", "explicit restoration must read back the owned service baseline"
            reconciled = subprocess.run([unified, "--program-reconcile", trial_id], env=no_model,
                capture_output=True, text=True, timeout=10)
            assert reconciled.returncode == 0 and json.loads(registry_path.read_text())["programs"][1]["status"] == "reconciled"
            transcript.append({"action": "program_effect_reconciliation", "run": json.loads(effected.stdout),
                "blocked": blocked.stdout, "restored": restored_program.stdout, "reconciled": reconciled.stdout})
            features = json.dumps({"disable": ["samba"]}).ljust(240)
            for slot in range(1, 7):
                program_tool("install_program", dict(id=f"reserved-{slot}", purpose="p" * 256,
                    interval_ms=0, steps=[dict(operation="apply", payload=features)] * 4), "installed")
            listing = subprocess.run([unified, "--programs"], env=no_model,
                capture_output=True, text=True, timeout=10)
            assert listing.returncode == 0 and len(json.loads(listing.stdout)["programs"]) == 8, "all eight admitted slots must remain owner-visible even with maximum-size specifications"
            program_tool("install_program", dict(spec, id="ninth"), "program_slot_exhausted_or_id_exists")
            transcript.append({"action": "programs", "manual": result, "scheduled": scheduled,
                               "interrupted": interrupted.stdout, "revoked": denied_run.stdout})
            assert pending["connection"] == connection, "all phases must retain exactly the selected target and credential references"
            after_setup = read_device()
            config = directory / "config/continuum"
            (config / "service.json").write_text(json.dumps(dict(sample_interval_ms=1000, incident_cooldown_ms=60000,
                                                                max_calls_per_hour=4, allow_meta=True)))
            service_env = dict(integrated_env, MODEL_API_KEY="synthetic-private-service-key")
            service = subprocess.run([unified, "--serve", "3"], env=service_env,
                                     capture_output=True, text=True, timeout=20)
            assert service.returncode == 0, "the resident must consume the same saved device: " + service.stdout + service.stderr
            service_state = json.loads((config / "service/status.json").read_text())
            assert service_state["device"]["candidate_id"] == pending["candidate_id"]
            assert service_state["device"]["authenticated"] is True and service_state["device"]["ready"] is False
            assert service_state["model_calls_this_hour"] == 3 and service_state["assessment_status"] == "completed", "incident tools and rejected actuation must be continued through the real Meta adapter contract"
            assert service_state["last_assessment"] == "Selected device inspected; unsafe actuation refused."
            assert read_device() == after_setup, "an unqualified physical target cannot be mutated or replaced by a simulator"
            # The endpoint can now be another box. A matching address and valid
            # credential are not sufficient to reuse the previous device's proofs.
            request("/applyapp.cgi", {"lan_hwaddr": "02:00:00:00:00:02"})
            mismatch = subprocess.run([unified, "--serve", "1"], env=integrated_env,
                                      capture_output=True, text=True, timeout=15)
            assert mismatch.returncode == 0
            mismatched = json.loads((config / "service/status.json").read_text())
            assert mismatched["device"]["authenticated"] is False and mismatched["device"]["reason"] == "device_identity_changed"
            assert mismatched["device"]["ready"] is False
            request("/applyapp.cgi", {"lan_hwaddr": "02:00:00:00:00:01"})
            assert PASSWORD not in json.dumps(pending) + json.dumps(service_state) + setup.stdout
            transcript.append({"action": "integrated_handoff", "device": pending, "service": service_state,
                               "identity_mismatch": mismatched["device"], "boundary": "authored_device_os_and_model_transport"})
            print("DEVICE_LIFECYCLE_ALL_GREEN", directory)
    finally:
        (directory / "transcript.json").write_text(json.dumps(transcript, indent=2) + "\n")
        server.terminate()
        server.wait(timeout=5)
        log.close()
        print("COMMISSION_TEST_SHA256", hashlib.sha256(Path(__file__).read_bytes()).hexdigest())


if __name__ == "__main__":
    if Path(sys.argv[0]).name in ("nvram", "service", "id", "nohup", "reboot", "tc"):
        device_command()
    else:
        main()
