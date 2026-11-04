#!/usr/bin/env python3
"""Resident-service acceptance: real host, blocking waits, and authored incidents.

The optional incident executable replaces host and Meta boundaries, not the
scheduler or persistence. Its transcript is explicitly not live-provider proof.
"""
import json
import os
from pathlib import Path
import resource
import signal
import subprocess
import sys
import time

BIN = str(Path(sys.argv[1]).resolve())
ROOT = Path('.build/service-acceptance-' + str(os.getpid())).resolve()
ROOT.mkdir(parents=True, exist_ok=True)
ENV = {k: v for k, v in os.environ.items() if k not in ('MODEL_API_KEY', 'META_API_KEY')}
ENV['XDG_CONFIG_HOME'] = str(ROOT)
CONFIG = ROOT / 'continuum'
CONFIG.mkdir(mode=0o700)
STATUS = CONFIG / 'service/status.json'
transcript = {'host_boundary': 'live_os', 'provider_boundary': 'not_called', 'checks': []}


def check(ok, message):
    if not ok:
        raise AssertionError(message)
    transcript['checks'].append(message)
    print('ok', message)


def settings(**overrides):
    value = dict(sample_interval_ms=1000, incident_cooldown_ms=60000,
                 max_calls_per_hour=1, allow_meta=False)
    value.update(overrides)
    (CONFIG / 'service.json').write_text(json.dumps(value))
    (CONFIG / 'service.json').chmod(0o600)


def wait_samples(process, count, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if STATUS.exists():
            state = json.loads(STATUS.read_text())
            if state['samples'] >= count and state['pid'] == process.pid:
                return state
        if process.poll() is not None:
            raise AssertionError('service exited before live samples: ' + process.communicate()[0])
        time.sleep(0.05)
    raise AssertionError('service did not publish bounded live observations')


profile_interval = int(os.environ.get('CONTINUUM_PROFILE_INTERVAL_MS', '1000'))
settings(sample_interval_ms=profile_interval)
start = time.monotonic()
before = resource.getrusage(resource.RUSAGE_CHILDREN)
result = subprocess.run([BIN, '--serve', '3'], env=ENV, capture_output=True, text=True,
                        timeout=2 * profile_interval / 1000 + 8)
after = resource.getrusage(resource.RUSAGE_CHILDREN)
elapsed = time.monotonic() - start
check(result.returncode == 0, 'a real resident monitoring run exists, rather than the simulator: ' + result.stdout)
state = json.loads(STATUS.read_text())
check(state['phase'] == 'stopped' and state['samples'] == 3 and state['network_changed'] is False,
      'finite monitoring publishes its final state without changing the network')
check(state['observation']['provenance'] == 'live_host' and state['observation']['routes_known'],
      'monitoring records real OS routes and counters, not synthetic optimization measurements')
check(state['model_calls_this_hour'] == 0 and state['meta_permission'] is False,
      'no-key default performs no paid requests')
check(elapsed >= 1.8 * profile_interval / 1000,
      'sampling waits for real time instead of advancing a simulated clock')
cpu_seconds = after.ru_utime + after.ru_stime - before.ru_utime - before.ru_stime
check(cpu_seconds < 0.25, 'idle monitoring does not consume a busy CPU core')
check(STATUS.stat().st_size < 16384 and STATUS.stat().st_mode & 0o077 == 0,
      'retained status is bounded and private')
transcript['finite_run'] = {'state': state, 'child_cpu_seconds': cpu_seconds,
                            'elapsed_seconds': elapsed}

settings()
process = subprocess.Popen([BIN, '--serve'], env=ENV, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
try:
    wait_samples(process, 2)
    duplicate = subprocess.run([BIN, '--serve', '1'], env=ENV, capture_output=True, text=True, timeout=3)
    check(duplicate.returncode != 0, 'a second service cannot duplicate sampling or spend for this configuration')
    stopped_at = time.monotonic()
    process.send_signal(signal.SIGTERM)
    output, error = process.communicate(timeout=3)
    check(process.returncode == 0 and time.monotonic() - stopped_at < 1,
          'SIGTERM interrupts the blocking wait and shuts down cleanly')
    check(json.loads(STATUS.read_text())['phase'] == 'stopped', 'shutdown is observable without an attached TUI')
finally:
    if process.poll() is None:
        process.terminate()
        process.communicate(timeout=3)

settings(sample_interval_ms=0)
result = subprocess.run([BIN, '--serve', '1'], env=ENV, capture_output=True, text=True, timeout=3)
check(result.returncode != 0, 'invalid sampling budgets fail closed instead of creating a busy loop')
settings(unrecognized_permission=True)
result = subprocess.run([BIN, '--serve', '1'], env=ENV, capture_output=True, text=True, timeout=3)
check(result.returncode != 0, 'unknown permission fields cannot silently expand authority')

if len(sys.argv) > 2:
    fixture = str(Path(sys.argv[2]).resolve())
    ENV['MODEL_API_KEY'] = 'synthetic-private-service-key'
    settings(allow_meta=True)
    incident_root = ROOT / 'incidents'
    (incident_root / 'continuum').mkdir(parents=True, mode=0o700)
    fixture_env = dict(ENV, XDG_CONFIG_HOME=str(incident_root), CONTINUUM_SERVICE_FIXTURE='incidents')
    fixture_config = incident_root / 'continuum/service.json'
    fixture_config.write_text((CONFIG / 'service.json').read_text())
    fixture_config.chmod(0o600)
    for run in range(2):
        result = subprocess.run([fixture, '--serve', '8'], env=fixture_env,
                                capture_output=True, text=True, timeout=12)
        check(result.returncode == 0, 'authored incident path completes without interactive approval: ' + result.stdout + result.stderr)
        report = json.loads((incident_root / 'continuum/service/status.json').read_text())
        check(report['model_calls_this_hour'] == 1 and report['network_changed'] is False,
              'incident budget survives both repeated conditions and process restart')
        check(report['assessment_status'] in ('completed', 'budget_exhausted'),
              'actual model assessment or explicit budget refusal is retained')
        if run == 0:
            check(report['last_assessment'] == 'Observed route transition; no mutation authorized.',
                  'the read-only Meta result is delivered, not replaced by a canned service success')
        transcript.setdefault('authored_incident_runs', []).append(report)
    check('synthetic-private-service-key' not in json.dumps(transcript), 'credentials never enter retained service evidence')

Path('.build/service-acceptance.json').write_text(json.dumps(transcript, indent=2) + '\n')
print('SERVICE_ALL_GREEN')
